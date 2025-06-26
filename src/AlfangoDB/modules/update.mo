import InputTypes "../types/input";
import OutputTypes "../types/output";
import Database "../types/database";
import Commons "commons";
import Utils "../utils";
import Buffer "mo:base/Buffer";
import Debug "mo:base/Debug";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Array "mo:base/Array";
import Map "mo:map/Map";
import Set "mo:map/Set";
import { thash } "mo:map/Map";
import Vector "mo:vector";
import BTree "mo:stableheapbtreemap/BTree";

module {

    public func addAttribute({
        addAttributeInput : InputTypes.AddAttributeInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.AddAttributeOutputType {

        let databases = alfangoDB.databases;

        if (not Map.has(databases, thash, addAttributeInput.databaseName)) {
            return #err(["database does not exist"]);
        };

        switch (Map.get(databases, thash, addAttributeInput.databaseName)) {
            case (null) { return #err(["Database not found"]) };
            case (?database) {
                switch (Map.get(database.tables, thash, addAttributeInput.tableName)) {
                    case (null) {
                        return #err(["table " # debug_show (addAttributeInput.tableName) # " does not exist"]);
                    };
                    case (?table) {
                        let newAttribute = addAttributeInput.attribute;
                        if (Map.has(table.metadata.attributesMap, thash, newAttribute.name)) {
                            return #err(["attribute " # debug_show (newAttribute.name) # " already exists"]);
                        };

                        Map.set(table.metadata.attributesMap, thash, newAttribute.name, newAttribute);

                        Debug.print("Attribute '" # newAttribute.name # "' added to metadata for table '" # table.name # "'.");

                        return #ok({
                            databaseName = addAttributeInput.databaseName;
                            tableName = addAttributeInput.tableName;
                            attributeNames = newAttribute.name;
                        });
                    };
                };
            };
        };
    };

    public func dropAttribute({
        dropAttributeInput : InputTypes.DropAttributeInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.DropAttributeOutputType {

        let databases = alfangoDB.databases;
        let { databaseName; tableName; attributeName } = dropAttributeInput;

        if (not Map.has(databases, thash, databaseName)) {
            return #err(["database does not exist"]);
        };

        switch (Map.get(databases, thash, databaseName)) {
            case (null) { return #err(["Database not found (unreachable)"]) };
            case (?database) {
                switch (Map.get(database.tables, thash, tableName)) {
                    case (null) {
                        return #err(["table '" # tableName # "' does not exist"]);
                    };
                    case (?table) {
                        // 1. Validate that the attribute exists on the table.
                        if (not Map.has(table.metadata.attributesMap, thash, attributeName)) {
                            return #err(["attribute '" # attributeName # "' does not exist"]);
                        };

                        // 2. Find all indexes that contain the dropped attribute and remove them.
                        let remainingIndexes = Buffer.Buffer<Database.TableIndexMetadata>(0);
                        let indexesToDrop = Buffer.Buffer<Database.TableIndexMetadata>(0);

                        for (indexMetadata in Vector.vals(table.metadata.indexes)) {
                            // Check if the attributeName exists in the index's attribute list
                            let isAffected = Array.find<Text>(
                                indexMetadata.attributeNames,
                                func(name) { name == attributeName },
                            ) != null;

                            if (isAffected) {
                                indexesToDrop.add(indexMetadata);
                            } else {
                                remainingIndexes.add(indexMetadata);
                            };
                        };

                        // 3. Perform the deletion of the affected indexes.
                        for (indexMeta in indexesToDrop.vals()) {
                            Debug.print(
                                "Dropping index '" # indexMeta.name #
                                "' on table '" # tableName #
                                "' as it contains the dropped attribute '" # attributeName # "'."
                            );
                            // Delete the index B-Tree data
                            Map.delete(table.indexes, thash, indexMeta.name);
                        };

                        // Update the table's index metadata to only contain the unaffected indexes.
                        table.metadata.indexes := Vector.fromIter(remainingIndexes.vals());

                        // 4. Remove the attribute's metadata from the table definition.
                        Map.delete(table.metadata.attributesMap, thash, attributeName);

                        // 5. Schedule the background job to remove the attribute data from all existing items.
                        let newJob : Database.PendingJob = #DropAttribute({
                            attributeNames = attributeName; // Note: The job type still uses `attributeNames`
                            var lastProcessedId = null;
                            var isComplete = false;
                        });
                        Vector.add(table.pendingJobs, newJob);

                        Debug.print(
                            "Attribute '" # attributeName # "' metadata dropped. " #
                            "Cleanup job scheduled for table '" # table.name # "'."
                        );

                        return #ok({
                            databaseName = databaseName;
                            tableName = tableName;
                            attributeNames = attributeName;
                        });
                    };
                };
            };
        };
    };

    public func updateItem({
        updateItemInput : InputTypes.UpdateItemInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.UpdateItemOutputType {

        let databases = alfangoDB.databases;

        // --- PHASE 1: FIND & VALIDATE ---
        switch (Map.get(databases, thash, updateItemInput.databaseName)) {
            case (null) { return #err(["database does not exist"]) };
            case (?database) {
                switch (Map.get(database.tables, thash, updateItemInput.tableName)) {
                    case (null) { return #err(["table not found"]) };
                    case (?table) {
                        switch (Map.get(table.items, thash, updateItemInput.id)) {
                            case (null) { return #err(["item not found"]) };
                            case (?item) {
                                // --- All items found, now perform validation BEFORE any state change ---

                                // Create the potential new state of the item in a temporary map
                                let newItemDataMap = Map.clone(item.attributeDataValueMap);
                                for ((attrName, attrValue) in updateItemInput.attributeDataValues.vals()) {
                                    Map.set(newItemDataMap, thash, attrName, attrValue);
                                };

                                // Validate data types
                                let { isValidAttributesDataType } = Commons.validateAttributeDataTypes({
                                    attributeKeyDataValues = updateItemInput.attributeDataValues;
                                    attributeNameToMetadataMap = table.metadata.attributesMap;
                                });
                                if (not isValidAttributesDataType) {
                                    return #err(["At least one update attribute has wrong data-type"]);
                                };

                                // Validate unique constraints against the potential new state
                                let { areConstraintsMet; violatedAttributes } = Commons.validateUniqueConstraints({
                                    itemDataMap = newItemDataMap;
                                    table = table;
                                    itemIdToIgnore = ?updateItemInput.id;
                                });
                                if (not areConstraintsMet) {
                                    return #err(["Unique constraint violation on attributes: " # debug_show (violatedAttributes)]);
                                };

                                let oldItemSize = Utils.calculateItemSize(item.attributeDataValueMap);
                                let newItemSize = Utils.calculateItemSize(newItemDataMap);

                                if (newItemSize > oldItemSize) {
                                    // Item grew in size
                                    let sizeIncrease : Nat64 = newItemSize - oldItemSize;
                                    if (alfangoDB.totalStableBytes + sizeIncrease > alfangoDB.STABLE_MEMORY_LIMIT) {
                                        return #err(["Stable memory limit reached. Cannot update item."]);
                                    };
                                };

                                // --- PHASE 2: COMMIT STATE CHANGES (Synchronous & Atomic-like) ---
                                // All validations have passed. Now we perform all state changes.
                                // If any of these trap, the whole message is rolled back.

                                // 2a. Update memory usage (now using safe Nat64 math)
                                if (newItemSize > oldItemSize) {
                                    let sizeIncrease : Nat64 = newItemSize - oldItemSize;
                                    alfangoDB.totalStableBytes += sizeIncrease;
                                } else if (oldItemSize > newItemSize) {
                                    let sizeDecrease : Nat64 = oldItemSize - newItemSize;
                                    // Guard against underflow, although it shouldn't happen in a consistent state.
                                    if (alfangoDB.totalStableBytes >= sizeDecrease) {
                                        alfangoDB.totalStableBytes -= sizeDecrease;
                                    } else {
                                        alfangoDB.totalStableBytes := 0;
                                    };
                                };
                                // If sizes are equal, do nothing.

                                // 2b. Update indexes
                                for ((indexName, indexTable) in Map.entries(table.indexes)) {
                                    let oldCompoundKey = Utils.generateCompoundKey(item.attributeDataValueMap, indexTable.attributeNames);
                                    let newCompoundKey = Utils.generateCompoundKey(newItemDataMap, indexTable.attributeNames);

                                    if (oldCompoundKey != newCompoundKey) {
                                        // Delete the old index entry
                                        switch (oldCompoundKey) {
                                            case (?oldKey) {
                                                switch (BTree.get(indexTable.items, Text.compare, oldKey)) {
                                                    case (?idSet) {
                                                        Set.delete(idSet, thash, item.id);
                                                        if (Set.size(idSet) == 0) {
                                                            ignore BTree.delete(indexTable.items, Text.compare, oldKey);
                                                        };
                                                    };
                                                    case (null) {};
                                                };
                                            };
                                            case (null) {};
                                        };

                                        // Add the new index entry
                                        switch (newCompoundKey) {
                                            case (?newKey) {
                                                let idSet = switch (BTree.get(indexTable.items, Text.compare, newKey)) {
                                                    case (null) {
                                                        Set.new<Text>();
                                                    };
                                                    case (?existing) {
                                                        existing;
                                                    };
                                                };
                                                Set.add(idSet, thash, item.id);
                                                ignore BTree.insert(indexTable.items, Text.compare, newKey, idSet);
                                            };
                                            case (null) {};
                                        };
                                    };
                                };

                                // 2c. Update the item data itself
                                item.attributeDataValueMap := newItemDataMap;
                                item.updatedAt := Time.now();

                                Debug.print("item updated with id: " # debug_show (updateItemInput.id));
                                return #ok({
                                    id = item.id;
                                    item = Map.toArray(item.attributeDataValueMap);
                                });
                            };
                        };
                    };
                };
            };
        };
    };

    public func createIndex({
        createIndexInput : InputTypes.CreateIndexInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.CreateIndexOutputType {

        let databases = alfangoDB.databases;
        let { databaseName; tableName; index } = createIndexInput;

        if (not Map.has(databases, thash, databaseName)) {
            return #err(["database does not exist"]);
        };

        switch (Map.get(databases, thash, databaseName)) {
            case (null) { return #err(["Database not found"]) };
            case (?database) {
                switch (Map.get(database.tables, thash, tableName)) {
                    case (null) {
                        return #err(["table '" # tableName # "' not found"]);
                    };
                    case (?table) {
                        let errorBuffer = Buffer.Buffer<Text>(0);

                        if (Map.has(table.indexes, thash, index.name)) {
                            errorBuffer.add("Index with name '" # index.name # "' already exists.");
                        };

                        if (index.attributeNames.size() == 0) {
                            errorBuffer.add("Index must contain at least one attribute.");
                        };

                        for (attrName in index.attributeNames.vals()) {
                            if (not Map.has(table.metadata.attributesMap, thash, attrName)) {
                                errorBuffer.add("Attribute '" # attrName # "' in index definition does not exist on the table.");
                            };
                        };

                        if (errorBuffer.size() > 0) {
                            return #err(Buffer.toArray(errorBuffer));
                        };

                        Vector.add(table.metadata.indexes, index);

                        let newIndexTable : Database.IndexTable = {
                            attributeNames = index.attributeNames;
                            items = BTree.init<Text, Set.Set<Text>>(null);
                        };
                        Map.set(table.indexes, thash, index.name, newIndexTable);

                        if (Map.size(table.items) > 0) {
                            let newJob : Database.PendingJob = #BuildIndex({
                                indexName = index.name;
                                var lastProcessedId = null;
                                var isComplete = false;
                            });
                            Vector.add(table.pendingJobs, newJob);
                            Debug.print("Index '" # index.name # "' created. Build job scheduled.");
                        } else {
                            Debug.print("Index '" # index.name # "' created for empty table. No build job needed.");
                        };

                        return #ok({
                            databaseName = databaseName;
                            tableName = tableName;
                            indexName = index.name;
                        });
                    };
                };
            };
        };
    };
};
