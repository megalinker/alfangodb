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
                        var items = BTree.init<Text, Set.Set<Text>>(null);
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
                        var schemaVersion = 0;
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

                // Use a HashMap for efficient validation lookups.
                let itemDataHashMap = HashMap.fromIter<Text, Datatypes.AttributeDataValue>(
                    createItemInput.attributeDataValues.vals(),
                    createItemInput.attributeDataValues.size(),
                    Text.equal,
                    Text.hash,
                );

                // 1. Validate data types and check for unwanted attributes.
                for ((attrName, attrValue) in itemDataHashMap.entries()) {
                    switch (Map.get(table.metadata.attributesMap, thash, attrName)) {
                        case (?attrMetadata) {
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

                // If any preliminary validation failed, stop here.
                if (errorBuffer.size() > 0) {
                    let errs = Buffer.toArray(errorBuffer);
                    Debug.print("error(s) creating item: " # debug_show (errs));
                    return #err(errs);
                };

                // 3. Validate unique constraints.
                // For a new item, the "original" map is empty. The patch data is the new item data.
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

                // Final check on the error buffer.
                if (errorBuffer.size() > 0) {
                    let errs = Buffer.toArray(errorBuffer);
                    Debug.print("error(s) creating item: " # debug_show (errs));
                    return #err(errs);
                };

                // --- COMMIT PHASE ---
                // All validations passed. Now create stable structures and commit.

                // 1. Create the map of StoredAttribute records, calculating size for each.
                let itemStoredAttrMap = Map.new<Text, Database.StoredAttribute>();
                for ((attrName, attrValue) in itemDataHashMap.entries()) {
                    Map.set(
                        itemStoredAttrMap,
                        thash,
                        attrName,
                        {
                            value = attrValue;
                            // Calculate and cache the size ONCE at creation time.
                            sizeInBytes = Utils.calculateAttributeDataValueSize(attrValue);
                        },
                    );
                };

                // 2. Enforce global memory budget using the new calculateItemSize.
                let newItemSize = Utils.calculateItemSize(itemStoredAttrMap);
                if (alfangoDB.totalStableBytes + newItemSize > alfangoDB.STABLE_MEMORY_LIMIT) {
                    let remark : Text = "Stable memory limit reached. Cannot create new item.";
                    Debug.print(remark);
                    return #err([remark]);
                };
                alfangoDB.totalStableBytes += newItemSize;

                // 3. Generate ID and update indexes.
                let newItemId = await Utils.generateULIDAsync();

                // Create a simple map of raw values just for key generation.
                let valuesMap = Map.fromIter<Text, Datatypes.AttributeDataValue>(
                    Iter.map<(Text, Database.StoredAttribute), (Text, Datatypes.AttributeDataValue)>(
                        Map.entries(itemStoredAttrMap),
                        func(entry : (Text, Database.StoredAttribute)) : (Text, Datatypes.AttributeDataValue) {
                            let (attrName, storedAttr) = entry;
                            return (attrName, storedAttr.value);
                        },
                    ),
                    thash,
                );

                for ((indexName, indexTable) in Map.entries(table.indexes)) {
                    switch (Utils.generateCompoundKey(valuesMap, indexTable.attributeNames)) {
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

                // 4. Create the final item and update table count.
                let item : Database.Item = {
                    id = newItemId;
                    var attributeDataValueMap = itemStoredAttrMap;
                    createdAt = Time.now();
                    var updatedAt = Time.now();
                    var sizeInBytes = newItemSize;
                };
                ignore BTree.insert(table.items, Text.compare, item.id, item);
                table.itemCount += 1;
                Debug.print("item created with id: " # debug_show (item.id));

                // 5. Return success, converting the stored map to the public output format.
                return #ok({
                    id = item.id;
                    item = Map.toArray(valuesMap); // Return the simple map of values
                });
            };
        };
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
};
