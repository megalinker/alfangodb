import Database "../types/database";
import Map "mo:map/Map";
import { thash } "mo:map/Map";
import Text "mo:base/Text";
import Debug "mo:base/Debug";
import Nat "mo:base/Nat";
import Buffer "mo:base/Buffer";
import Nat64 "mo:base/Nat64";
import Vector "mo:vector";
import BTree "mo:stableheapbtreemap/BTree";
import Utils "../utils";
import Set "mo:map/Set";

module {

    let BATCH_SIZE : Nat = 100;

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

        let keyIterator = Map.keys(table.items);
        var readyToProcess = false;

        switch (jobState.lastProcessedId) {
            case (null) {
                readyToProcess := true;
            };
            case (?cursorId) {
                var foundCursor = false;
                var continueLoop = true;

                while (continueLoop and not foundCursor) {
                    switch (keyIterator.next()) {
                        case (null) {
                            continueLoop := false;
                        };
                        case (?key) {
                            if (key == cursorId) {
                                foundCursor := true;
                            };
                        };
                    };
                };

                if (foundCursor) {
                    readyToProcess := true;
                } else {
                    Debug.print("Warning: Job cursor '" # cursorId # "' not found. Restarting scan.");
                    jobState.lastProcessedId := null;
                    return;
                };
            };
        };

        if (readyToProcess) {
            var itemsProcessedInBatch : Nat = 0;
            var continueProcessing = true;
            var isJobNowComplete = false;
            var bytesFreedInBatch : Nat64 = 0;

            while (continueProcessing and itemsProcessedInBatch < BATCH_SIZE) {
                switch (keyIterator.next()) {
                    case (null) {
                        continueProcessing := false;
                        isJobNowComplete := true;
                    };
                    case (?itemId) {
                        switch (Map.get(table.items, thash, itemId)) {
                            case (null) { /* Item was deleted, simply skip. */ };
                            case (?item) {
                                switch (Map.get(item.attributeDataValueMap, thash, jobState.attributeNames)) {
                                    case (?valueToDelete) {
                                        // 1. Calculate the size of the attribute name (Text) and the value
                                        let keySize = Nat64.fromNat(Text.size(jobState.attributeNames));
                                        let valueSize = Utils.calculateAttributeDataValueSize(valueToDelete);
                                        bytesFreedInBatch += (keySize + valueSize);

                                        // 2. Now delete the attribute from the item
                                        Map.delete(item.attributeDataValueMap, thash, jobState.attributeNames);
                                    };
                                    case (null) {
                                        // Attribute not present, nothing to delete or account for.
                                    };
                                };
                            };
                        };

                        jobState.lastProcessedId := ?itemId;
                        itemsProcessedInBatch += 1;
                    };
                };
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

            if (isJobNowComplete) {
                jobState.isComplete := true;
                Debug.print("DropAttribute job for '" # jobState.attributeNames # "' is now complete.");
            };
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

        let keyIterator = Map.keys(table.items);
        var readyToProcess = false;

        switch (jobState.lastProcessedId) {
            case (null) {
                readyToProcess := true;
            };
            case (?cursorId) {
                var foundCursor = false;
                var continueLoop = true;
                while (continueLoop and not foundCursor) {
                    switch (keyIterator.next()) {
                        case (null) { continueLoop := false };
                        case (?key) {
                            if (key == cursorId) { foundCursor := true };
                        };
                    };
                };
                if (foundCursor) {
                    readyToProcess := true;
                } else {
                    Debug.print("Warning: BuildIndex job cursor '" # cursorId # "' not found. Restarting scan.");
                    jobState.lastProcessedId := null;
                    return;
                };
            };
        };

        if (readyToProcess) {
            var itemsProcessedInBatch : Nat = 0;
            var continueProcessing = true;
            var isJobNowComplete = false;

            while (continueProcessing and itemsProcessedInBatch < BATCH_SIZE) {
                switch (keyIterator.next()) {
                    case (null) {
                        continueProcessing := false;
                        isJobNowComplete := true;
                    };
                    case (?itemId) {
                        switch (Map.get(table.items, thash, itemId)) {
                            case (null) { /* Skip deleted item */ };
                            case (?item) {
                                switch (Utils.generateCompoundKey(item.attributeDataValueMap, indexTable.attributeNames)) {
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
                            };
                        };
                        jobState.lastProcessedId := ?itemId;
                        itemsProcessedInBatch += 1;
                    };
                };
            };

            Debug.print("Processed " # Nat.toText(itemsProcessedInBatch) # " items for index build.");

            if (isJobNowComplete) {
                jobState.isComplete := true;
                Debug.print("BuildIndex job for '" # indexName # "' is now complete.");
            };
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
