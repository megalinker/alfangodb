import Database "../types/database";
import InputTypes "../types/input";
import OutputTypes "../types/output";
import Utils "../utils";
import Map "mo:map/Map";
import Set "mo:map/Set";
import { thash } "mo:map/Map";
import Debug "mo:base/Debug";
import Text "mo:base/Text";
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

        if (not Map.has(databases, thash, deleteItemInput.databaseName)) {
            let remark = "database does not exist: " # debug_show (deleteItemInput.databaseName);
            Debug.print(remark);
            return #err([remark]);
        };

        switch (Map.get(databases, thash, deleteItemInput.databaseName)) {
            case (null) {
                return #err(["Database not found"]);
            };
            case (?database) {
                switch (Map.get(database.tables, thash, deleteItemInput.tableName)) {
                    case (null) {
                        let remark = "table does not exist: " # debug_show (deleteItemInput.tableName);
                        Debug.print(remark);
                        return #err([remark]);
                    };
                    case (?table) {
                        switch (Map.get(table.items, thash, deleteItemInput.id)) {
                            case (null) {
                                let remark = "item does not exist: " # debug_show (deleteItemInput.id);
                                Debug.print(remark);
                                return #err([remark]);
                            };
                            case (?item) {

                                let deletedItemSize = Utils.calculateItemSize(item.attributeDataValueMap);

                                if (alfangoDB.totalStableBytes >= deletedItemSize) {
                                    alfangoDB.totalStableBytes -= deletedItemSize;
                                } else {
                                    alfangoDB.totalStableBytes := 0;
                                };
                                // Iterate through all defined indexes for the table.
                                for ((indexName, indexTable) in Map.entries(table.indexes)) {
                                    // For each index, generate its specific compound key from the item being deleted.
                                    switch (Utils.generateCompoundKey(item.attributeDataValueMap, indexTable.attributeNames)) {
                                        case (null) {};
                                        case (?compoundKey) {
                                            // The item should have an entry in this index. Find it and remove the item's ID.
                                            let indexBTree = indexTable.items;

                                            switch (BTree.get(indexBTree, Text.compare, compoundKey)) {
                                                case (null) {
                                                    Debug.print("Warning: Item " # item.id # " not found in index '" # indexName # "' for key '" # compoundKey # "'.");
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

                                // Finally, remove the item itself from the main table data.
                                Map.delete(table.items, thash, deleteItemInput.id);
                                Debug.print("item deleted with id: " # debug_show (deleteItemInput.id));
                                return #ok({});
                            };
                        };
                    };
                };
            };
        };
    };
};
