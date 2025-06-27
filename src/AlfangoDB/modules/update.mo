import InputTypes "../types/input";
import OutputTypes "../types/output";
import Database "../types/database";
import Datatype "../types/datatype";
import Commons "commons";
import Utils "../utils";
import Buffer "mo:base/Buffer";
import Debug "mo:base/Debug";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Array "mo:base/Array";
import Nat64 "mo:base/Nat64";
import Int "mo:base/Int";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
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
        switch (Map.get(alfangoDB.databases, thash, addAttributeInput.databaseName)) {
            case (null) {
                return #err(["database does not exist"]);
            };
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

                        table.metadata.schemaVersion += 1;
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

        let { databaseName; tableName; attributeName } = dropAttributeInput;

        switch (Map.get(alfangoDB.databases, thash, databaseName)) {
            case (null) {
                return #err(["database does not exist"]);
            };
            case (?database) {
                switch (Map.get(database.tables, thash, tableName)) {
                    case (null) {
                        return #err(["table '" # tableName # "' does not exist"]);
                    };
                    case (?table) {
                        if (not Map.has(table.metadata.attributesMap, thash, attributeName)) {
                            return #err(["attribute '" # attributeName # "' does not exist"]);
                        };

                        let remainingIndexes = Buffer.Buffer<Database.TableIndexMetadata>(0);
                        let indexesToDrop = Buffer.Buffer<Database.TableIndexMetadata>(0);

                        for (indexMetadata in Vector.vals(table.metadata.indexes)) {
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

                        table.metadata.schemaVersion += 1;

                        for (indexMeta in indexesToDrop.vals()) {
                            Debug.print(
                                "Dropping index '" # indexMeta.name #
                                "' on table '" # tableName #
                                "' as it contains the dropped attribute '" # attributeName # "'."
                            );
                            Map.delete(table.indexes, thash, indexMeta.name);
                        };

                        table.metadata.indexes := Vector.fromIter(remainingIndexes.vals());

                        Map.delete(table.metadata.attributesMap, thash, attributeName);

                        let newJob : Database.PendingJob = #DropAttribute({
                            attributeNames = attributeName;
                            var lastProcessedId = null;
                            var isComplete = false;
                            var schemaVersionAtCreation = table.metadata.schemaVersion;
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
                        switch (BTree.get(table.items, Text.compare, updateItemInput.id)) {
                            case (null) { return #err(["item not found"]) };
                            case (?item) {

                                // 1a. Calculate the memory delta efficiently.
                                var sizeDelta : Int = 0;
                                for ((attrName, newAttrValue) in updateItemInput.attributeDataValues.vals()) {
                                    let newSize = Utils.calculateAttributeDataValueSize(newAttrValue);

                                    switch (Map.get(item.attributeDataValueMap, thash, attrName)) {
                                        case (null) {
                                            sizeDelta += Text.size(attrName);
                                            sizeDelta += Nat64.toNat(newSize);
                                        };
                                        case (?oldStoredAttr) {
                                            let oldSize = oldStoredAttr.sizeInBytes;
                                            sizeDelta += (Nat64.toNat(newSize) - Nat64.toNat(oldSize));
                                        };
                                    };
                                };

                                // 1b. Perform the memory limit check using the efficient delta.
                                if (sizeDelta > 0) {
                                    let sizeIncrease = Int.abs(sizeDelta);
                                    if (alfangoDB.totalStableBytes + Nat64.fromNat(sizeIncrease) > alfangoDB.STABLE_MEMORY_LIMIT) {
                                        return #err(["Stable memory limit reached. Cannot update item."]);
                                    };
                                };

                                // 1c. Validate data types for the attributes in the patch.
                                for ((attrName, attrValue) in updateItemInput.attributeDataValues.vals()) {
                                    switch (Map.get(table.metadata.attributesMap, thash, attrName)) {
                                        case (?attrMeta) {
                                            let { isValidAttributeDataType } = Commons.validateAttributeDataType({
                                                attributeDataValue = attrValue;
                                                expectedAttributeDataType = attrMeta.dataType;
                                            });
                                            if (not isValidAttributeDataType) {
                                                return #err(["Attribute '" # attrName # "' has wrong data-type"]);
                                            };
                                        };
                                        case (null) {
                                            return #err(["Attribute '" # attrName # "' does not exist in table"]);
                                        };
                                    };
                                };

                                // Create a HashMap of the patch data for validation.
                                let patchData = HashMap.fromIter<Text, Datatype.AttributeDataValue>(
                                    updateItemInput.attributeDataValues.vals(),
                                    updateItemInput.attributeDataValues.size(),
                                    Text.equal,
                                    Text.hash,
                                );

                                // 1d. Create a map of the original raw values for constraint validation.
                                let originalItemData = Map.fromIter<Database.AttributeName, Datatype.AttributeDataValue>(
                                    Iter.map<(Database.AttributeName, Database.StoredAttribute), (Database.AttributeName, Datatype.AttributeDataValue)>(
                                        Map.entries(item.attributeDataValueMap),
                                        func(entry : (Database.AttributeName, Database.StoredAttribute)) : (Database.AttributeName, Datatype.AttributeDataValue) {
                                            let (attrName, storedAttr) = entry;
                                            (attrName, storedAttr.value);
                                        },
                                    ),
                                    thash,
                                );

                                // 1e. Validate unique constraints against the potential new state.
                                let { areConstraintsMet; violatedAttributes } = Commons.validateUniqueConstraints({
                                    originalItemData = originalItemData;
                                    patchData = patchData;
                                    table = table;
                                    itemIdToIgnore = ?updateItemInput.id;
                                });
                                if (not areConstraintsMet) {
                                    return #err(["Unique constraint violation on attributes: " # debug_show (violatedAttributes)]);
                                };

                                // --- PHASE 2: COMMIT STATE CHANGES (Atomic-like) ---

                                // 2a. Update memory usage using the pre-calculated delta.
                                if (sizeDelta > 0) {
                                    alfangoDB.totalStableBytes += Nat64.fromNat(Int.abs(sizeDelta));
                                } else if (sizeDelta < 0) {
                                    let sizeDecrease = Nat64.fromNat(Int.abs(-sizeDelta));
                                    if (alfangoDB.totalStableBytes < sizeDecrease) {
                                        Debug.trap(
                                            "CRITICAL: Memory accounting inconsistency detected during update. " #
                                            "totalStableBytes (" # Nat64.toText(alfangoDB.totalStableBytes) #
                                            ") < sizeDecrease (" # Nat64.toText(sizeDecrease) # ")."
                                        );
                                    };
                                    alfangoDB.totalStableBytes -= sizeDecrease;
                                };

                                // 2b. Update indexes.
                                // We need to generate the "before" and "after" view of the item's values.
                                let newValuesMap = Map.fromIter<Database.AttributeName, Datatype.AttributeDataValue>(
                                    Iter.map<(Database.AttributeName, Database.StoredAttribute), (Database.AttributeName, Datatype.AttributeDataValue)>(
                                        Map.entries(item.attributeDataValueMap),
                                        func(entry : (Database.AttributeName, Database.StoredAttribute)) : (Database.AttributeName, Datatype.AttributeDataValue) {
                                            let (attrName, storedAttr) = entry;
                                            // if the patch has a newer value for this field, use it; otherwise keep the old
                                            switch (patchData.get(attrName)) {
                                                case null (attrName, storedAttr.value);
                                                case (?newVal) (attrName, newVal);
                                            };
                                        },
                                    ),
                                    thash,
                                );

                                for ((indexName, indexTable) in Map.entries(table.indexes)) {
                                    let oldCompoundKey = Utils.generateCompoundKey(originalItemData, indexTable.attributeNames);
                                    let newCompoundKey = Utils.generateCompoundKey(newValuesMap, indexTable.attributeNames);

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

                                // 2c. Update the item data and its cached size.
                                if (sizeDelta > 0) {
                                    item.sizeInBytes += Nat64.fromNat(Int.abs(sizeDelta));
                                } else if (sizeDelta < 0) {
                                    let sizeDecrease = Nat64.fromNat(Int.abs(-sizeDelta));
                                    if (item.sizeInBytes >= sizeDecrease) {
                                        item.sizeInBytes -= sizeDecrease;
                                    } else {
                                        item.sizeInBytes := 0;
                                    };
                                };
                                item.updatedAt := Time.now();

                                // Apply the patch to the item's stable map.
                                for ((attrName, attrValue) in patchData.entries()) {
                                    Map.set(
                                        item.attributeDataValueMap,
                                        thash,
                                        attrName,
                                        {
                                            value = attrValue;
                                            // Calculate and cache the size for the new/updated value.
                                            sizeInBytes = Utils.calculateAttributeDataValueSize(attrValue);
                                        },
                                    );
                                };

                                Debug.print("item updated with id: " # debug_show (updateItemInput.id));
                                return #ok({
                                    id = item.id;
                                    item = Map.toArray(newValuesMap);
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

        let { databaseName; tableName; index } = createIndexInput;

        switch (Map.get(alfangoDB.databases, thash, databaseName)) {
            case (null) {
                return #err(["database does not exist"]);
            };
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

                        table.metadata.schemaVersion += 1;

                        Vector.add(table.metadata.indexes, index);

                        let newIndexTable : Database.IndexTable = {
                            attributeNames = index.attributeNames;
                            var items = BTree.init<Text, Set.Set<Text>>(null);
                        };
                        Map.set(table.indexes, thash, index.name, newIndexTable);

                        if (BTree.size(table.items) > 0) {
                            let newJob : Database.PendingJob = #BuildIndex({
                                indexName = index.name;
                                var lastProcessedId = null;
                                var isComplete = false;
                                var schemaVersionAtCreation = table.metadata.schemaVersion;
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
