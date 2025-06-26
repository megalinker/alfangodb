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
import HashMap "mo:base/HashMap";
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

        switch (Map.get(databases, thash, createTableInput.databaseName)) {
            case (null) {
                let remark = "database does not exist: " # debug_show (createTableInput.databaseName);
                Debug.print(remark);
                return #err([remark]);
            };
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
                    items = BTree.init<Text, Database.Item>(null);
                    indexes = indexes;
                    var pendingJobs = Vector.new<Database.PendingJob>();
                    var itemCount = 0;
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

        switch (Map.get(databases, thash, createItemInput.databaseName)) {
            case (null) {
                let remark : Text = "database does not exist: " # debug_show (createItemInput.databaseName);
                Debug.print(remark);
                return #err([remark]);
            };
            case (?database) {
                let table = switch (Map.get(database.tables, thash, createItemInput.tableName)) {
                    case null {
                        let remark : Text = "table does not exist: " # debug_show (createItemInput.tableName);
                        Debug.print(remark);
                        return #err([remark]);
                    };
                    case (?tbl) { tbl };
                };

                // --- VALIDATION PHASE ---
                let errorBuffer = Buffer.Buffer<Text>(0);

                let itemDataHashMap = HashMap.fromIter<Text, Datatypes.AttributeDataValue>(
                    createItemInput.attributeDataValues.vals(),
                    createItemInput.attributeDataValues.size(),
                    Text.equal,
                    Text.hash,
                );

                // 1. Validate data types and check for unwanted attributes in one pass.
                for ((attrName, attrValue) in itemDataHashMap.entries()) {
                    switch (Map.get(table.metadata.attributesMap, thash, attrName)) {
                        case (?attrMetadata) {
                            // Attribute exists, validate its type.
                            let {
                                isValidAttributeDataType;
                                actualAttributeDataType;
                            } = Commons.validateAttributeDataType({
                                attributeDataValue = attrValue;
                                expectedAttributeDataType = attrMetadata.dataType;
                            });
                            if (not isValidAttributeDataType) {
                                let remark = "Attribute '" # attrName # "' has invalid data type. Expected " # debug_show (attrMetadata.dataType) # ", got " # debug_show (actualAttributeDataType) # ".";
                                errorBuffer.add(remark);
                            };
                        };
                        case (null) {
                            // Attribute is not defined in the table schema.
                            errorBuffer.add("Attribute '" # attrName # "' does not exist in table '" # table.name # "'.");
                        };
                    };
                };

                // 2. Validate that all required attributes are present.
                for (attrMetadata in Map.vals(table.metadata.attributesMap)) {
                    if (attrMetadata.required) {
                        if (itemDataHashMap.get(attrMetadata.name) == null) {
                            errorBuffer.add("Missing required attribute: '" # attrMetadata.name # "'.");
                        };
                    };
                };

                // If any preliminary validation failed, stop here before expensive checks.
                if (errorBuffer.size() > 0) {
                    let errs = Buffer.toArray(errorBuffer);
                    Debug.print("error(s) creating item: " # debug_show (errs));
                    return #err(errs);
                };

                // 3. Validate unique constraints. For a new item, the "original" map is empty
                let { areConstraintsMet; violatedAttributes } = Commons.validateUniqueConstraints({
                    originalItemData = Map.new<Text, Datatypes.AttributeDataValue>();
                    patchData = itemDataHashMap;
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
                                "Unique constraint violation on attributes: " # Text.join(", ", attrs.vals())
                            );
                        };
                    };
                };

                // Final check on the error buffer after all validations.
                if (errorBuffer.size() > 0) {
                    let errs = Buffer.toArray(errorBuffer);
                    Debug.print("error(s) creating item: " # debug_show (errs));
                    return #err(errs);
                };

                // --- COMMIT PHASE ---
                // All validations passed. Now create stable structures and commit.

                let itemDataMap = Map.fromIter<Text, Datatypes.AttributeDataValue>(itemDataHashMap.entries(), thash);

                // Enforce global memory budget
                let newItemSize = Utils.calculateItemSize(itemDataMap);
                if (alfangoDB.totalStableBytes + newItemSize > alfangoDB.STABLE_MEMORY_LIMIT) {
                    let remark : Text = "Stable memory limit reached. Cannot create new item.";
                    Debug.print(remark);
                    return #err([remark]);
                };
                alfangoDB.totalStableBytes += newItemSize;

                // Generate ID and update indexes
                let newItemId = await Utils.generateULIDAsync();
                for ((indexName, indexTable) in Map.entries(table.indexes)) {
                    // For a new item, there is no patch; all data is original.
                    switch (Utils.generateCompoundKey(
                        itemDataMap,
                        HashMap.HashMap<Text, Datatypes.AttributeDataValue>(
                            0,
                            Text.equal,
                            Text.hash
                        ),
                        indexTable.attributeNames
                    )) {
                        case null {
                            /* missing attributes for this index, skip */
                        };
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

                // Create the item and update count
                let item : Database.Item = {
                    id = newItemId;
                    var attributeDataValueMap = itemDataMap;
                    createdAt = Time.now();
                    var updatedAt = Time.now();
                    var sizeInBytes = newItemSize;
                };
                ignore BTree.insert(table.items, Text.compare, item.id, item);
                table.itemCount += 1;
                Debug.print("item created with id: " # debug_show (item.id));

                // Return success
                return #ok({
                    id = item.id;
                    item = Map.toArray(item.attributeDataValueMap);
                });
            };
        };
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
};
