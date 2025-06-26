import Database "../types/database";
import Datatypes "../types/datatype";
import InputTypes "../types/input";
import OutputTypes "../types/output";
import Commons "commons";
import Utils "../utils";
import Map "mo:map/Map";
import Set "mo:map/Set";
import { thash } "mo:map/Map";
import Debug "mo:base/Debug";
import Buffer "mo:base/Buffer";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Iter "mo:base/Iter";
import Vector "mo:vector";
import BTree "mo:stableheapbtreemap/BTree";

module {

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public func createDatabase({
        createDatabaseInput : InputTypes.CreateDatabaseInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.CreateDatabaseOutputType {

        let databases = alfangoDB.databases;

        if (Map.has(databases, thash, createDatabaseInput.name)) {
            let remark = "database already exists: " # debug_show (createDatabaseInput.name);
            Debug.print(remark);
            return #err([remark]);
        };

        let database : Database.Database = {
            name = createDatabaseInput.name;
            tables = Map.new<Text, Database.Table>();
        };

        Map.set(databases, thash, database.name, database);
        Debug.print("database created with name: " # debug_show (database.name));
        return #ok({});
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public func createTable({
        createTableInput : InputTypes.CreateTableInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.CreateTableOutputType {

        let databases = alfangoDB.databases;

        if (not Map.has(databases, thash, createTableInput.databaseName)) {
            let remark = "database does not exist: " # debug_show (createTableInput.databaseName);
            Debug.print(remark);
            return #err([remark]);
        };

        switch (Map.get(databases, thash, createTableInput.databaseName)) {
            case (null) { return #err(["Database not found"]) };
            case (?database) {
                if (Map.has(database.tables, thash, createTableInput.name)) {
                    let remark = "table already exists: " # debug_show (createTableInput.name);
                    Debug.print(remark);
                    return #err([remark]);
                };

                let indexes = Map.new<Text, Database.IndexTable>();

                for (indexMetadata in createTableInput.indexes.vals()) {
                    let indexTable : Database.IndexTable = {
                        attributeNames = indexMetadata.attributeNames;
                        items = BTree.init<Text, Set.Set<Text>>(null);
                    };
                    Map.set(indexes, thash, indexMetadata.name, indexTable);
                };

                let table : Database.Table = {
                    name = createTableInput.name;
                    metadata = {
                        attributesMap = Map.fromIter<Text, Database.AttributeMetadata>(
                            Iter.map<Database.AttributeMetadata, (Text, Database.AttributeMetadata)>(
                                createTableInput.attributes.vals(),
                                func attributeMetadata = (attributeMetadata.name, attributeMetadata),
                            ),
                            thash,
                        );
                        var indexes = Vector.fromArray(createTableInput.indexes);
                    };
                    items = Map.new<Text, Database.Item>();
                    indexes = indexes;
                    var pendingJobs = Vector.new<Database.PendingJob>();
                };

                Map.set(database.tables, thash, table.name, table);
                Debug.print("table created with name: " # debug_show (table.name));
                return #ok({});
            };
        };
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public func createItem({
        createItemInput : InputTypes.CreateItemInputType;
        alfangoDB : Database.AlfangoDB;
    }) : async OutputTypes.CreateItemOutputType {
        let databases = alfangoDB.databases;

        // 1. Ensure the database exists
        if (not Map.has(databases, thash, createItemInput.databaseName)) {
            let remark : Text = "database does not exist: " # debug_show (createItemInput.databaseName);
            Debug.print(remark);
            return #err([remark]);
        };

        // 2. Unwrap the database
        let database = switch (Map.get(databases, thash, createItemInput.databaseName)) {
            case null {
                let remark : Text = "Database not found";
                Debug.print(remark);
                return #err([remark]);
            };
            case (?db) { db };
        };

        // 3. Ensure the table exists
        let table = switch (Map.get(database.tables, thash, createItemInput.tableName)) {
            case null {
                let remark : Text = "table does not exist: " # debug_show (createItemInput.tableName);
                Debug.print(remark);
                return #err([remark]);
            };
            case (?tbl) { tbl };
        };

        // 4. Validate attribute data
        let errorBuffer = Buffer.Buffer<Text>(0);
        let itemDataMap = Map.fromIter<Text, Datatypes.AttributeDataValue>(
            createItemInput.attributeDataValues.vals(),
            thash,
        );

        let { isValidAttributesDataType } = Commons.validateAttributeDataTypes({
            attributeKeyDataValues = createItemInput.attributeDataValues;
            attributeNameToMetadataMap = table.metadata.attributesMap;
        });
        if (not isValidAttributesDataType) {
            errorBuffer.add("At least one attribute has wrong data-type");
        };

        let { requiredAttributesPresent } = validateRequiredAttributes({
            attributeDataValues = createItemInput.attributeDataValues;
            tableMetadata = table.metadata;
        });
        if (not requiredAttributesPresent) {
            errorBuffer.add("At least one required attribute is missing");
        };

        let { areConstraintsMet; violatedAttributes } = Commons.validateUniqueConstraints({
            itemDataMap = itemDataMap;
            table = table;
            itemIdToIgnore = null;
        });
        if (not areConstraintsMet) {
            switch (violatedAttributes) {
                case null {
                    errorBuffer.add("A unique constraint was violated.");
                };
                case (?attrs) {
                    errorBuffer.add(
                        "Unique constraint violation on attributes: " # debug_show (attrs)
                    );
                };
            };
        };

        if (errorBuffer.size() > 0) {
            let errs = Buffer.toArray(errorBuffer);
            Debug.print("error(s) creating item: " # debug_show (errs));
            return #err(errs);
        };

        // 5. Enforce global memory budget
        let newItemSize = Utils.calculateItemSize(itemDataMap);
        if (alfangoDB.totalStableBytes + newItemSize > alfangoDB.STABLE_MEMORY_LIMIT) {
            let remark : Text = "Stable memory limit reached. Cannot create new item.";
            Debug.print(remark);
            return #err([remark]);
        };
        alfangoDB.totalStableBytes += newItemSize;

        // 6. Generate ID and update indexes
        let newItemId = await Utils.generateULIDAsync();
        for ((indexName, indexTable) in Map.entries(table.indexes)) {
            switch (Utils.generateCompoundKey(itemDataMap, indexTable.attributeNames)) {
                case null { /* missing attributes for this index, skip */ };
                case (?compoundKey) {
                    let idSet = switch (BTree.get(indexTable.items, Text.compare, compoundKey)) {
                        case null { Set.new<Text>() };
                        case (?existing) { existing };
                    };
                    Set.add(idSet, thash, newItemId);
                    ignore BTree.insert(indexTable.items, Text.compare, compoundKey, idSet);
                };
            };
        };

        // 7. Create the item
        let item : Database.Item = {
            id = newItemId;
            var attributeDataValueMap = itemDataMap;
            createdAt = Time.now();
            var updatedAt = Time.now();
        };
        Map.set(table.items, thash, item.id, item);
        Debug.print("item created with id: " # debug_show (item.id));

        // 8. Return success
        return #ok({
            id = item.id;
            item = Map.toArray(item.attributeDataValueMap);
        });
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    private func validateRequiredAttributes({
        attributeDataValues : [(Text, Datatypes.AttributeDataValue)];
        tableMetadata : Database.TableMetadata;
    }) : {
        actualRequiredAttributes : [Text];
        requiredAttributesPresent : Bool;
    } {
        let expectedRequiredAttributesMap = Map.filter<Text, Database.AttributeMetadata>(tableMetadata.attributesMap, thash, func _acceptEntry(_attributeNames : Text, attributeMetadata : Database.AttributeMetadata) : Bool { attributeMetadata.required });
        let actualRequiredAttributes = Buffer.Buffer<Text>(0);

        for ((attributeName, _) in attributeDataValues.vals()) {
            if (Map.has(expectedRequiredAttributesMap, thash, attributeName)) {
                actualRequiredAttributes.add(attributeName);
            };
        };

        return {
            actualRequiredAttributes = Buffer.toArray(actualRequiredAttributes);
            requiredAttributesPresent = Map.size(expectedRequiredAttributesMap) == actualRequiredAttributes.size();
        };
    };

};
