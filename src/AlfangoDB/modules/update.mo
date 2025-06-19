import InputTypes "../types/input";
import OutputTypes "../types/output";
import Database "../types/database";
import Datatypes "../types/datatype";
import Commons "commons";
import Utils "../utils";
import Buffer "mo:base/Buffer";
import Debug "mo:base/Debug";
import Prelude "mo:base/Prelude";
import Text "mo:base/Text";
import Option "mo:base/Option";
import Time "mo:base/Time";
import Map "mo:map/Map";
import Set "mo:map/Set";
import { thash } "mo:map/Map";

module {

    public func addAttribute({
        addAttributeInput : InputTypes.AddAttributeInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.AddAttributeOutputType {

        let databases = alfangoDB.databases;

        if (not Map.has(databases, thash, addAttributeInput.databaseName)) {
            Debug.print("database does not exist");
            return #err(["database does not exist"]);
        };

        let errorBuffer = Buffer.Buffer<Text>(0);
        ignore do ? {
            let database = Map.get(databases, thash, addAttributeInput.databaseName)!;

            if (not Map.has(database.tables, thash, addAttributeInput.tableName)) {
                errorBuffer.add("table " # debug_show (addAttributeInput.tableName) # " does not exist");
                Debug.print("error(s) adding attribute: " # debug_show (Buffer.toArray(errorBuffer)));
                return #err(Buffer.toArray(errorBuffer));
            };

            let table = Map.get(database.tables, thash, addAttributeInput.tableName)!;

            if (Map.has(table.metadata.attributesMap, thash, addAttributeInput.attribute.name)) {
                errorBuffer.add("attribute " # debug_show (addAttributeInput.attribute.name) # " already exists");
                Debug.print("error(s) adding attribute: " # debug_show (Buffer.toArray(errorBuffer)));
                return #err(Buffer.toArray(errorBuffer));
            };

            if (addAttributeInput.attribute.unique) {
                Map.set(
                    table.indexes,
                    thash,
                    addAttributeInput.attribute.name,
                    {
                        attributeName = addAttributeInput.attribute.name;
                        items = Map.new<Datatypes.AttributeDataValue, Set.Set<Text>>();
                    },
                );
            };

            Map.set(table.metadata.attributesMap, thash, addAttributeInput.attribute.name, addAttributeInput.attribute);

            return #ok({
                databaseName = addAttributeInput.databaseName;
                tableName = addAttributeInput.tableName;
                attributeName = addAttributeInput.attribute.name;
            });
        };

        Prelude.unreachable();
    };

    public func dropAttribute({
        dropAttributeInput : InputTypes.DropAttributeInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.DropAttributeOutputType {

        let databases = alfangoDB.databases;

        if (not Map.has(databases, thash, dropAttributeInput.databaseName)) {
            Debug.print("database does not exist");
            return #err(["database does not exist"]);
        };

        let errorBuffer = Buffer.Buffer<Text>(0);
        ignore do ? {
            let database = Map.get(databases, thash, dropAttributeInput.databaseName)!;

            if (not Map.has(database.tables, thash, dropAttributeInput.tableName)) {
                errorBuffer.add("table " # debug_show (dropAttributeInput.tableName) # " does not exist");
                Debug.print("error(s) dropping attribute: " # debug_show (Buffer.toArray(errorBuffer)));
                return #err(Buffer.toArray(errorBuffer));
            };

            let table = Map.get(database.tables, thash, dropAttributeInput.tableName)!;

            if (not Map.has(table.metadata.attributesMap, thash, dropAttributeInput.attributeName)) {
                errorBuffer.add("attribute " # debug_show (dropAttributeInput.attributeName) # " does not exist");
                Debug.print("error(s) dropping attribute: " # debug_show (Buffer.toArray(errorBuffer)));
                return #err(Buffer.toArray(errorBuffer));
            };

            if (Map.has(table.indexes, thash, dropAttributeInput.attributeName)) {
                Map.delete(table.indexes, thash, dropAttributeInput.attributeName);
            };

            Map.delete(table.metadata.attributesMap, thash, dropAttributeInput.attributeName);

            return #ok({
                databaseName = dropAttributeInput.databaseName;
                tableName = dropAttributeInput.tableName;
                attributeName = dropAttributeInput.attributeName;
            });
        };

        Prelude.unreachable();
    };

    public func updateItem({
        updateItemInput : InputTypes.UpdateItemInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.UpdateItemOutputType {

        let databases = alfangoDB.databases;

        if (not Map.has(databases, thash, updateItemInput.databaseName)) {
            Debug.print("database does not exist");
            return #err(["database does not exist"]);
        };

        let errorBuffer = Buffer.Buffer<Text>(0);
        ignore do ? {
            let database = Map.get(databases, thash, updateItemInput.databaseName)!;

            if (not Map.has(database.tables, thash, updateItemInput.tableName)) {
                errorBuffer.add("table " # debug_show (updateItemInput.tableName) # " does not exist");
                Debug.print("error(s) creating item: " # debug_show (Buffer.toArray(errorBuffer)));
                return #err(Buffer.toArray(errorBuffer));
            };

            let table = Map.get(database.tables, thash, updateItemInput.tableName)!;

            if (not Map.has(table.items, thash, updateItemInput.id)) {
                errorBuffer.add("item " # debug_show (updateItemInput.id) # " does not exist");
                Debug.print("error(s) creating item: " # debug_show (Buffer.toArray(errorBuffer)));
                return #err(Buffer.toArray(errorBuffer));
            };

            //////////////////////////////// START VALIDATION ////////////////////////////////

            let { isValidAttributesDataType } = Commons.validateAttributeDataTypes({
                attributeKeyDataValues = updateItemInput.attributeDataValues;
                attributeNameToMetadataMap = table.metadata.attributesMap;
            });
            if (not isValidAttributesDataType) {
                errorBuffer.add("At least one update attribute has wrong data-type");
            };

            let { uniqueAttributesUnique } = Commons.validateUniqueAttributes({
                attributeKeyDataValues = updateItemInput.attributeDataValues;
                indexes = table.indexes;
                tableMetadata = table.metadata;
                itemIdToIgnore = ?updateItemInput.id;
            });
            if (not uniqueAttributesUnique) {
                errorBuffer.add("At least one unique update attribute is not unique");
            };

            if (errorBuffer.size() > 0) {
                Debug.print("error(s) creating item: " # debug_show (Buffer.toArray(errorBuffer)));
                return #err(Buffer.toArray(errorBuffer));
            };

            ////////////////////////////////   END VALIDATION    ////////////////////////////////

            let item = Map.get(table.items, thash, updateItemInput.id)!;

            // --- FIXED: Replaced dangerous `ignore do ?` with safe `switch` statements ---
            for ((attributeName, updatedAttributeDataValue) in updateItemInput.attributeDataValues.vals()) {
                // First, check if there is an index for the attribute being updated.
                switch (Map.get(table.indexes, thash, attributeName)) {
                    case (null) {
                        // No index for this attribute. Do nothing with indexes.
                    };
                    case (?indexTable) {
                        // An index exists. We must remove the old value and add the new one.
                        let indexItems = indexTable.items;

                        // 1. Remove the old value from the index
                        switch (Map.get(item.attributeDataValueMap, thash, attributeName)) {
                            case (null) {
                                // The item didn't have a previous value for this attribute.
                                // This can happen if an optional attribute is being set for the first time.
                                // Nothing to remove.
                            };
                            case (?oldAttributeDataValue) {
                                // The item had a previous value. Remove it from the index.
                                switch (Map.get(indexItems, Utils.DataTypeValueHashUtils, oldAttributeDataValue)) {
                                    case (null) {
                                        /* Value wasn't indexed, do nothing */
                                    };
                                    case (?idSet) {
                                        Set.delete(idSet, thash, updateItemInput.id);
                                        if (Set.size(idSet) == 0) {
                                            Map.delete(indexItems, Utils.DataTypeValueHashUtils, oldAttributeDataValue);
                                        };
                                    };
                                };
                            };
                        };

                        // 2. Add the new value to the index
                        let newIdSet = Option.get(Map.get(indexItems, Utils.DataTypeValueHashUtils, updatedAttributeDataValue), Set.new<Text>());
                        if (Set.size(newIdSet) == 0) {
                            Map.set(indexItems, Utils.DataTypeValueHashUtils, updatedAttributeDataValue, newIdSet);
                        };
                        Set.add(newIdSet, thash, updateItemInput.id);
                    };
                };

                // Finally, update the actual item data
                Map.set(item.attributeDataValueMap, thash, attributeName, updatedAttributeDataValue);
            };

            item.updatedAt := Time.now();

            Debug.print("item updated with id: " # debug_show (updateItemInput.id));
            return #ok({
                id = updateItemInput.id;
                item = Map.toArray(item.attributeDataValueMap);
            });
        };

        Prelude.unreachable();
    };
};
