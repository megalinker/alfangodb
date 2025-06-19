import Database "../types/database";
import InputTypes "../types/input";
import OutputTypes "../types/output";
import Utils "../utils";
import Map "mo:map/Map";
import Set "mo:map/Set";
import { thash } "mo:map/Map";
import Debug "mo:base/Debug";
import Prelude "mo:base/Prelude";

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

        if (not Map.has(databases, thash, deleteTableInput.databaseName)) {
            let remark = "database does not exist: " # debug_show (deleteTableInput.databaseName);
            Debug.print(remark);
            return #err([remark]);
        };

        ignore do ? {
            let database = Map.get(databases, thash, deleteTableInput.databaseName)!;

            if (not Map.has(database.tables, thash, deleteTableInput.tableName)) {
                let remark = "table does not exist: " # debug_show (deleteTableInput.tableName);
                Debug.print(remark);
                return #err([remark]);
            };

            Map.delete(database.tables, thash, deleteTableInput.tableName);
            Debug.print("table deleted with name: " # debug_show (deleteTableInput.tableName));
            return #ok({});
        };

        Prelude.unreachable();
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

        ignore do ? {
            let database = Map.get(databases, thash, deleteItemInput.databaseName)!;

            if (not Map.has(database.tables, thash, deleteItemInput.tableName)) {
                let remark = "table does not exist: " # debug_show (deleteItemInput.tableName);
                Debug.print(remark);
                return #err([remark]);
            };

            let table = Map.get(database.tables, thash, deleteItemInput.tableName)!;

            if (not Map.has(table.items, thash, deleteItemInput.id)) {
                let remark = "item does not exist: " # debug_show (deleteItemInput.id);
                Debug.print(remark);
                return #err([remark]);
            };

            let item = Map.get(table.items, thash, deleteItemInput.id)!;

            for ((attributeName, attributeDataValue) in Map.entries(item.attributeDataValueMap)) {
                switch (Map.get(table.indexes, thash, attributeName)) {
                    case (null) {};
                    case (?indexTable) {
                        let indexItems = indexTable.items;
                        switch (Map.get(indexItems, Utils.DataTypeValueHashUtils, attributeDataValue)) {
                            case (null) {};
                            case (?idSet) {
                                Set.delete(idSet, thash, item.id);

                                if (Set.size(idSet) == 0) {
                                    Map.delete(indexItems, Utils.DataTypeValueHashUtils, attributeDataValue);
                                };
                            };
                        };
                    };
                };
            };

            // remove item from table
            Map.delete(table.items, thash, deleteItemInput.id);
            Debug.print("item deleted with id: " # debug_show (deleteItemInput.id));
            return #ok({});
        };

        Prelude.unreachable();
    };
};
