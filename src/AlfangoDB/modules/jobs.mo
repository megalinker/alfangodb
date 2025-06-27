import Database "../types/database";
import Datatypes "../types/datatype";
import Map "mo:map/Map";
import { thash } "mo:map/Map";
import Text "mo:base/Text";
import Debug "mo:base/Debug";
import Nat "mo:base/Nat";
import Buffer "mo:base/Buffer";
import Nat64 "mo:base/Nat64";
import Iter "mo:base/Iter";
import Vector "mo:vector";
import BTree "mo:stableheapbtreemap/BTree";
import Utils "../utils";
import Set "mo:map/Set";

module {

    let BATCH_SIZE : Nat = 100;
    let UNBOUNDED_UPPER_KEY = "\u{10FFFF}";

    private func _processTableJobs(alfangoDB : Database.AlfangoDB, table : Database.Table) {
        let jobQueueSize = Vector.size(table.pendingJobs);
        if (jobQueueSize == 0) {
            return;
        };

        // --- PHASE 1: PROCESS JOBS WITH PRIORITIZATION ---

        // Get the first job in the queue to check its type.
        let firstJob = Vector.get(table.pendingJobs, 0);

        // If the first job is a schema-altering job, process ONLY that job.
        // This prevents race conditions with data-level jobs.
        if (isSchemaAlteringJob(firstJob)) {
            Debug.print("Prioritizing schema-altering job for table '" # table.name # "'.");
            switch (firstJob) {
                case (#DropAttribute(jobState)) {
                    _processDropAttributeJob(alfangoDB, table, jobState);
                };
                case (#BuildIndex(jobState)) {
                    _processBuildIndexJob(table, jobState);
                };
            };
        } else {
            // If there are no pending schema jobs, process a batch of all data-level jobs (round-robin).
            for (job in Vector.vals(table.pendingJobs)) {
                switch (job) {
                    case (#DropAttribute(_)) {
                        Debug.print("Warning: Schema-altering job found mid-queue. It will be processed on a future run once it is at the front.");
                    };
                    case (#BuildIndex(_)) {
                        Debug.print("Warning: Schema-altering job found mid-queue. It will be processed on a future run once it is at the front.");
                    };
                };
            };
        };

        // --- PHASE 2: CLEAN UP COMPLETED JOBS ---
        // This part remains the same. It's safe to run after the processing phase.
        let activeJobs = Buffer.Buffer<Database.PendingJob>(0);
        var hasCompletedJobs = false;

        for (job in Vector.vals(table.pendingJobs)) {
            if (not isJobComplete(job)) {
                activeJobs.add(job);
            } else {
                hasCompletedJobs := true;
                Debug.print("A job has completed for table '" # table.name # "' and is being removed from the queue.");
            };
        };

        if (hasCompletedJobs) {
            table.pendingJobs := Vector.fromIter(activeJobs.vals());
        };
    };

    private func _processDropAttributeJob(alfangoDB : Database.AlfangoDB, table : Database.Table, jobState : Database.DropAttributeJob) {
        if (jobState.isComplete) { return };

        if (jobState.schemaVersionAtCreation < table.metadata.schemaVersion) {
            Debug.print(
                "Warning: Schema change detected for DropAttribute job on table '" # table.name #
                "'. Resetting cursor to ensure data consistency. This may re-process some items."
            );
            jobState.lastProcessedId := null;
            jobState.schemaVersionAtCreation := table.metadata.schemaVersion;
        };

        Debug.print(
            "Processing DropAttribute job for '" # jobState.attributeNames #
            "' on table '" # table.name # "'..."
        );

        let startKey = switch (jobState.lastProcessedId) {
            case (null) { "" }; // If no cursor, start from the beginning.
            case (?id) { id }; // Otherwise, resume from the last processed ID.
        };

        // Scan a batch of items from the table's B-Tree.
        let scanResult = BTree.scanLimit<Text, Database.Item>(
            table.items,
            Text.compare,
            startKey,
            UNBOUNDED_UPPER_KEY,
            #fwd,
            BATCH_SIZE,
        );

        var itemsProcessedInBatch : Nat = 0;
        var totalBytesFreedInBatch : Nat64 = 0;

        for ((itemId, item) in scanResult.results.vals()) {
            switch (Map.get(item.attributeDataValueMap, thash, jobState.attributeNames)) {
                case (?storedAttrToDelete) {
                    // This attribute exists in the item, so we need to remove it and update sizes.

                    // 1. Calculate the size being freed for this specific attribute.
                    // This includes the size of the key (Text) and the value (from its cache).
                    let keySize = Nat64.fromNat(Text.size(jobState.attributeNames));
                    let valueSize = storedAttrToDelete.sizeInBytes;
                    let recordOverhead : Nat64 = 16;
                    let bytesFreedForItem = keySize + valueSize + recordOverhead;

                    // 2. Add to the batch total.
                    totalBytesFreedInBatch += bytesFreedForItem;

                    // 3. Update the item's own cached total size.
                    if (item.sizeInBytes >= bytesFreedForItem) {
                        item.sizeInBytes -= bytesFreedForItem;
                    } else {
                        // This indicates a memory accounting bug.
                        item.sizeInBytes := 0;
                    };

                    // 4. Finally, delete the attribute from the item's map.
                    Map.delete(item.attributeDataValueMap, thash, jobState.attributeNames);
                };
                case (null) {
                    // Attribute not present in this item, nothing to do.
                };
            };
            itemsProcessedInBatch += 1;
            jobState.lastProcessedId := ?itemId; // Update cursor to the last processed item
        };

        // After processing the batch, update the global memory counter.
        if (totalBytesFreedInBatch > 0) {
            Debug.print("Reclaiming " # Nat64.toText(totalBytesFreedInBatch) # " bytes from dropped attributes.");
            if (alfangoDB.totalStableBytes >= totalBytesFreedInBatch) {
                alfangoDB.totalStableBytes -= totalBytesFreedInBatch;
            } else {
                Debug.print("Warning: Global memory counter underflow during DropAttribute job. Resetting to zero.");
                alfangoDB.totalStableBytes := 0;
            };
        };

        Debug.print("Processed " # Nat.toText(itemsProcessedInBatch) # " items for DropAttribute job.");

        if (itemsProcessedInBatch < BATCH_SIZE) {
            jobState.isComplete := true;
            Debug.print("DropAttribute job for '" # jobState.attributeNames # "' is now complete.");
        };
    };

    private func _processBuildIndexJob(table : Database.Table, jobState : Database.BuildIndexJob) {
        if (jobState.isComplete) { return };

        if (jobState.schemaVersionAtCreation < table.metadata.schemaVersion) {
            Debug.print(
                "Warning: Schema change detected for BuildIndex job on table '" # table.name #
                "'. Resetting cursor to ensure data consistency. This may re-process some items."
            );
            // Resetting the cursor forces a full rescan.
            jobState.lastProcessedId := null;
            // The index BTree should be cleared to avoid duplicate entries from the rescan.
            switch (Map.get(table.indexes, thash, jobState.indexName)) {
                case (?indexTable) {
                    indexTable.items := BTree.init(null);
                    Debug.print("Cleared index BTree for '" # jobState.indexName # "' before rescan.");
                };
                case (null) {};
            };
            // Update the job's version stamp to the current version.
            jobState.schemaVersionAtCreation := table.metadata.schemaVersion;
        };

        let indexName = jobState.indexName;
        Debug.print(
            "Processing BuildIndex job for index '" # indexName #
            "' on table '" # table.name # "'..."
        );

        let indexTable = switch (Map.get(table.indexes, thash, indexName)) {
            case (null) {
                Debug.print("CRITICAL: BuildIndex job running for a non-existent index '" # indexName # "'. Aborting job.");
                jobState.isComplete := true;
                return;
            };
            case (?idx) { idx };
        };

        let startKey = switch (jobState.lastProcessedId) {
            case (null) { "" }; // If no cursor, start from the beginning.
            case (?id) { id }; // Otherwise, resume from the last processed ID.
        };

        // Scan a batch of items from the table's B-Tree.
        let scanResult = BTree.scanLimit<Text, Database.Item>(
            table.items,
            Text.compare,
            startKey,
            UNBOUNDED_UPPER_KEY,
            #fwd,
            BATCH_SIZE,
        );

        var itemsProcessedInBatch : Nat = 0;

        for ((itemId, item) in scanResult.results.vals()) {
            // 1. Create a temporary map of raw values from the item's StoredAttributes.
            let valuesMap = Map.fromIter<Database.AttributeName, Datatypes.AttributeDataValue>(
                Iter.map<(Database.AttributeName, Database.StoredAttribute), (Database.AttributeName, Datatypes.AttributeDataValue)>(
                    Map.entries<Database.AttributeName, Database.StoredAttribute>(item.attributeDataValueMap),
                    func(entry) {
                        let (attrName, storedAttr) = entry;
                        return (attrName, storedAttr.value);
                    },
                ),
                thash, // still pass your hash‐utils to fromIter
            );

            // 2. Call the simplified generateCompoundKey function.
            switch (Utils.generateCompoundKey(valuesMap, indexTable.attributeNames)) {
                case (null) {
                    // This item doesn't have all attributes for the index, so it's not indexed.
                };
                case (?compoundKey) {
                    // This item is indexable. Add its ID to the index B-Tree.
                    let indexBTree = indexTable.items;
                    let idSet = switch (BTree.get(indexBTree, Text.compare, compoundKey)) {
                        case (null) { Set.new<Text>() };
                        case (?existingSet) { existingSet };
                    };
                    Set.add(idSet, thash, itemId);
                    ignore BTree.insert(indexBTree, Text.compare, compoundKey, idSet);
                };
            };
            itemsProcessedInBatch += 1;
            jobState.lastProcessedId := ?itemId; // Update cursor to the last processed item
        };

        Debug.print("Processed " # Nat.toText(itemsProcessedInBatch) # " items for index build.");

        // If the number of processed items is less than the batch size, we've reached the end of the table.
        if (itemsProcessedInBatch < BATCH_SIZE) {
            jobState.isComplete := true;
            Debug.print("BuildIndex job for '" # indexName # "' is now complete.");
        };
    };

    private func isJobComplete(job : Database.PendingJob) : Bool {
        switch (job) {
            case (#DropAttribute(s)) { s.isComplete };
            case (#BuildIndex(s)) { s.isComplete };
        };
    };

    public func processAllPendingJobs(alfangoDB : Database.AlfangoDB) {
        Debug.print("--- Running background job processor ---");
        for (database in Map.vals(alfangoDB.databases)) {
            for (table in Map.vals(database.tables)) {
                if (Vector.size(table.pendingJobs) > 0) {
                    _processTableJobs(alfangoDB, table);
                };
            };
        };
        Debug.print("--- Background job processor finished ---");
    };

    private func isSchemaAlteringJob(job : Database.PendingJob) : Bool {
        switch (job) {
            case (#DropAttribute(_)) { return true };
            case (#BuildIndex(_)) { return true };
        };
    };
};
