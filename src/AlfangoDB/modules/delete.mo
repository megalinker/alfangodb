import Database "../types/database";
import Datatype "../types/datatype";
import InputTypes "../types/input";
import OutputTypes "../types/output";
import Utils "../utils";
import Map "mo:map/Map";
import Set "mo:map/Set";
import { thash } "mo:map/Map";
import Debug "mo:base/Debug";
import Text "mo:base/Text";
import Nat64 "mo:base/Nat64";
import Iter "mo:base/Iter";
import BTree "mo:stableheapbtreemap/BTree";

module {

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public func deleteDatabase({
        deleteDatabaseInput : InputTypes.DeleteDatabaseInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.DeleteDatabaseOutputType {

        let databases = alfangoDB.databases;

        if (not Map.has(databases, thash, deleteDatabaseInput.name)) {
            let remark = "database does not exist: " # debug_show (deleteDatabaseInput.name);
            Debug.print(remark);
            return #err([remark]);
        };

        Map.delete(databases, thash, deleteDatabaseInput.name);
        Debug.print("database deleted with name: " # debug_show (deleteDatabaseInput.name));
        return #ok({});
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public func deleteTable({
        deleteTableInput : InputTypes.DeleteTableInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.DeleteTableOutputType {

        let databases = alfangoDB.databases;

        switch (Map.get(databases, thash, deleteTableInput.databaseName)) {
            case (null) {
                // Case 1: The database does not exist.
                let remark = "database does not exist: " # debug_show (deleteTableInput.databaseName);
                Debug.print(remark);
                return #err([remark]);
            };
            case (?database) {
                // Case 2: The database was found. Now, check for the table.
                if (Map.has(database.tables, thash, deleteTableInput.tableName)) {

                    // The table exists, so we can delete it.
                    Map.delete(database.tables, thash, deleteTableInput.tableName);

                    Debug.print("table deleted with name: " # debug_show (deleteTableInput.tableName));
                    return #ok({});

                } else {
                    // The table does not exist in this database.
                    let remark = "table does not exist: " # debug_show (deleteTableInput.tableName);
                    Debug.print(remark);
                    return #err([remark]);
                };
            };
        };
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public func deleteItem({
        deleteItemInput : InputTypes.DeleteItemInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.DeleteItemOutputType {

        let databases = alfangoDB.databases;

        // Using let-else for cleaner early returns
        let ?database = Map.get(databases, thash, deleteItemInput.databaseName) else {
            let remark = "database does not exist: " # debug_show (deleteItemInput.databaseName);
            Debug.print(remark);
            return #err([remark]);
        };

        let ?table = Map.get(database.tables, thash, deleteItemInput.tableName) else {
            let remark = "table does not exist: " # debug_show (deleteItemInput.tableName);
            Debug.print(remark);
            return #err([remark]);
        };

        switch (BTree.get(table.items, Text.compare, deleteItemInput.id)) {
            case (null) {
                let remark = "item does not exist: " # debug_show (deleteItemInput.id);
                Debug.print(remark);
                return #err([remark]);
            };
            case (?item) {

                // --- PRE-COMMIT PHASE ---

                let deletedItemSize = item.sizeInBytes;

                // Sanity check: The total size must be greater than the item being deleted.
                if (alfangoDB.totalStableBytes < deletedItemSize) {
                    Debug.trap(
                        "CRITICAL: Memory accounting inconsistency detected during delete. " #
                        "totalStableBytes (" # Nat64.toText(alfangoDB.totalStableBytes) #
                        ") < deletedItemSize (" # Nat64.toText(deletedItemSize) # ")."
                    );
                };

                // Create a temporary map of the item's raw values for key generation.
                let valuesMap = Map.fromIter<Database.AttributeName, Datatype.AttributeDataValue>(
                    Iter.map<(Text, Database.StoredAttribute), (Database.AttributeName, Datatype.AttributeDataValue)>(
                        Map.entries(item.attributeDataValueMap),
                        func(entry : (Text, Database.StoredAttribute)) {
                            let (attrName, storedAttr) = entry;
                            return (attrName, storedAttr.value);
                        }
                    ),
                    thash,
                );

                // --- COMMIT PHASE ---

                // 1. Update total memory usage.
                alfangoDB.totalStableBytes -= deletedItemSize;

                // 2. Iterate through all defined indexes for the table to remove entries.
                for ((indexName, indexTable) in Map.entries(table.indexes)) {
                    // For each index, generate its specific compound key.
                    switch (Utils.generateCompoundKey(valuesMap, indexTable.attributeNames)) {
                        case (null) {
                            // This item didn't have all the attributes for this index, so nothing to delete.
                        };
                        case (?compoundKey) {
                            // The item should have an entry in this index. Find it and remove the item's ID.
                            let indexBTree = indexTable.items;

                            switch (BTree.get(indexBTree, Text.compare, compoundKey)) {
                                case (null) {
                                    // This is a sign of inconsistency, but we can proceed.
                                    // The goal is deletion, and the index entry is already gone.
                                    Debug.print("Warning: Item " # item.id # " not found in index '" # indexName # "' for key '" # compoundKey # "'. State might be inconsistent.");
                                };
                                case (?idSet) {
                                    // Remove the item's ID from the set of IDs associated with this key.
                                    Set.delete(idSet, thash, item.id);

                                    // If the set is now empty, remove the entire key from the B-Tree to save space.
                                    if (Set.size(idSet) == 0) {
                                        ignore BTree.delete(indexBTree, Text.compare, compoundKey);
                                    };
                                };
                            };
                        };
                    };
                };

                // 3. Finally, remove the item from the main table data.
                ignore BTree.delete(table.items, Text.compare, deleteItemInput.id);
                table.itemCount -= 1;
                Debug.print("item deleted with id: " # debug_show (deleteItemInput.id));
                return #ok({});
            };
        };
    };
};
