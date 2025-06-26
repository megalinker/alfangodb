import Database "../types/database";
import InputTypes "../types/input";
import OutputTypes "../types/output";
import Map "mo:map/Map";
import { thash } "mo:map/Map";
import Debug "mo:base/Debug";
import Iter "mo:base/Iter";
import Buffer "mo:base/Buffer";
import Text "mo:base/Text";
import Vector "mo:vector";
import BTree "mo:stableheapbtreemap/BTree";

module {

    public func getTableMetadata({
        getTableMetadataInput : InputTypes.GetTableMetadataInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.GetTableMetadataOutputType {
        switch (Map.get(alfangoDB.databases, thash, getTableMetadataInput.databaseName)) {
            case (?database) {
                switch (Map.get(database.tables, thash, getTableMetadataInput.tableName)) {
                    case (?table) {
                        return ?{
                            databaseName = getTableMetadataInput.databaseName;
                            tableName = getTableMetadataInput.tableName;
                            metadata = {
                                attributes = Iter.toArray(Map.vals(table.metadata.attributesMap));
                                indexes = Vector.toArray(table.metadata.indexes);
                            };
                        };
                    };
                    case (null) {
                        Debug.print("table does not exist");
                        return null;
                    };
                };
            };
            case (null) {
                Debug.print("database does not exist");
                return null;
            };
        };
    };

    public func getItemById({
        getItemByIdInput : InputTypes.GetItemByIdInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.GetItemByIdOutputType {
        switch (Map.get(alfangoDB.databases, thash, getItemByIdInput.databaseName)) {
            case (?database) {
                switch (Map.get(database.tables, thash, getItemByIdInput.tableName)) {
                    case (?table) {
                        switch (BTree.get(table.items, Text.compare, getItemByIdInput.id)) {
                            case (?item) {
                                return #ok({
                                    id = getItemByIdInput.id;
                                    item = Map.toArray(item.attributeDataValueMap);
                                });
                            };
                            case (null) {
                                let remark = "item does not exist" # debug_show (getItemByIdInput.id);
                                Debug.print(remark);
                                return #err([remark]);
                            };
                        };
                    };
                    case (null) {
                        let remark = "table does not exist: " # debug_show (getItemByIdInput.tableName);
                        Debug.print(remark);
                        return #err([remark]);
                    };
                };
            };
            case (null) {
                let remark = "database does not exist: " # debug_show (getItemByIdInput.databaseName);
                Debug.print(remark);
                return #err([remark]);
            };
        };
    };

    public func batchGetItemById({
        batchGetItemByIdInput : InputTypes.BatchGetItemByIdInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.BatchGetItemByIdOutputType {
        switch (Map.get(alfangoDB.databases, thash, batchGetItemByIdInput.databaseName)) {
            case (?database) {
                switch (Map.get(database.tables, thash, batchGetItemByIdInput.tableName)) {
                    case (?table) {
                        let notFoundIdsBuffer = Buffer.Buffer<Text>(0);
                        let itemsBuffer = Buffer.Buffer<OutputTypes.ItemOutputType>(0);

                        for (id in batchGetItemByIdInput.ids.vals()) {
                            switch (BTree.get(table.items, Text.compare, id)) {
                                case (null) {
                                    notFoundIdsBuffer.add(id);
                                };
                                case (?item) {
                                    itemsBuffer.add({
                                        id = id;
                                        item = Map.toArray(item.attributeDataValueMap);
                                    });
                                };
                            };
                        };

                        return #ok({
                            items = Buffer.toArray(itemsBuffer);
                            notFoundIds = Buffer.toArray(notFoundIdsBuffer);
                        });
                    };
                    case (null) {
                        let remark = "table does not exist: " # debug_show (batchGetItemByIdInput.tableName);
                        Debug.print(remark);
                        return #err([remark]);
                    };
                };
            };
            case (null) {
                let remark = "database does not exist: " # debug_show (batchGetItemByIdInput.databaseName);
                Debug.print(remark);
                return #err([remark]);
            };
        };
    };

    public func getItemCount({
        getItemCountInput : InputTypes.GetItemCountInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.GetItemCountOutputType {
        switch (Map.get(alfangoDB.databases, thash, getItemCountInput.databaseName)) {
            case (?database) {
                switch (Map.get(database.tables, thash, getItemCountInput.tableName)) {
                    case (?table) {
                        return #ok({
                            count = table.itemCount;
                        });
                    };
                    case (null) {
                        let remark = "table does not exist: " # debug_show (getItemCountInput.tableName);
                        Debug.print(remark);
                        return #err([remark]);
                    };
                };
            };
            case (null) {
                let remark = "database does not exist: " # debug_show (getItemCountInput.databaseName);
                Debug.print(remark);
                return #err([remark]);
            };
        };
    };

    public func getDatabases(alfangoDB : Database.AlfangoDB) : OutputTypes.GetDatabasesOutputType {
        let databasesInfo = Buffer.Buffer<{ name : Text; tables : [Text] }>(0);

        // Iterate over all databases
        for ((dbName, database) in Map.entries(alfangoDB.databases)) {
            let tableNames = Buffer.Buffer<Text>(0);

            // Iterate over all tables in the current database
            for ((tableName, table) in Map.entries(database.tables)) {
                tableNames.add(tableName);
            };

            // Add the database info (name and tables) to the main buffer
            databasesInfo.add({
                name = dbName;
                tables = Buffer.toArray(tableNames);
            });
        };

        return {
            databases = Buffer.toArray(databasesInfo);
        };
    };
};
