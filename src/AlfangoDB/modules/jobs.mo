import Database "../types/database";
import Datatypes "../types/datatype";
import Map "mo:map/Map";
import { thash } "mo:map/Map";
import Text "mo:base/Text";
import Debug "mo:base/Debug";
import Nat "mo:base/Nat";
import Buffer "mo:base/Buffer";
import Nat64 "mo:base/Nat64";
import HashMap "mo:base/HashMap";
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

        Debug.print(
            "Processing DropAttribute job for '" # jobState.attributeNames #
            "' on table '" # table.name # "'..."
        );

        let startKey = switch (jobState.lastProcessedId) {
            case (null) { "" }; // If no cursor, start from the beginning.
            case (?id) { id }; // Otherwise, resume from the last processed ID.
        };

        let scanResult = BTree.scanLimit<Text, Database.Item>(
            table.items,
            Text.compare,
            startKey,
            UNBOUNDED_UPPER_KEY,
            #fwd,
            BATCH_SIZE,
        );

        var itemsProcessedInBatch : Nat = 0;
        var bytesFreedInBatch : Nat64 = 0;

        for ((itemId, item) in scanResult.results.vals()) {
            // Reprocessing the first item in subsequent batches is okay because the operation is idempotent.
            switch (Map.get(item.attributeDataValueMap, thash, jobState.attributeNames)) {
                case (?valueToDelete) {
                    let keySize = Nat64.fromNat(Text.size(jobState.attributeNames));
                    let valueSize = Utils.calculateAttributeDataValueSize(valueToDelete);
                    bytesFreedInBatch += (keySize + valueSize);
                    Map.delete(item.attributeDataValueMap, thash, jobState.attributeNames);
                };
                case (null) {
                    // Attribute not present, nothing to do.
                };
            };
            itemsProcessedInBatch += 1;
            jobState.lastProcessedId := ?itemId; // Update cursor to the last processed item
        };

        if (bytesFreedInBatch > 0) {
            Debug.print("Reclaiming " # Nat64.toText(bytesFreedInBatch) # " bytes from dropped attributes.");
            if (alfangoDB.totalStableBytes >= bytesFreedInBatch) {
                alfangoDB.totalStableBytes -= bytesFreedInBatch;
            } else {
                alfangoDB.totalStableBytes := 0; // Safeguard against underflow
            };
        };

        Debug.print("Processed " # Nat.toText(itemsProcessedInBatch) # " items.");

        // If the number of processed items is less than the batch size, we've reached the end of the table.
        if (itemsProcessedInBatch < BATCH_SIZE) {
            jobState.isComplete := true;
            Debug.print("DropAttribute job for '" # jobState.attributeNames # "' is now complete.");
        };
    };

    private func _processBuildIndexJob(table : Database.Table, jobState : Database.BuildIndexJob) {
        if (jobState.isComplete) { return };

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
            switch (Utils.generateCompoundKey(
                item.attributeDataValueMap,
                HashMap.HashMap<Database.AttributeName, Datatypes.AttributeDataValue>(
                    0,
                    Text.equal,
                    Text.hash
                ),
                indexTable.attributeNames
            )) {
                case (null) {};
                case (?compoundKey) {
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
            jobState.lastProcessedId := ?itemId;
        };

        Debug.print("Processed " # Nat.toText(itemsProcessedInBatch) # " items for index build.");

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
