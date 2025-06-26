import Datatypes "../types/datatype";
import Database "../types/database";
import Utils "../utils";
import Text "mo:base/Text";
import Buffer "mo:base/Buffer";
import Debug "mo:base/Debug";
import Map "mo:map/Map";
import Set "mo:map/Set";
import { thash } "mo:map/Map";
import BTree "mo:stableheapbtreemap/BTree";
import Vector "mo:vector";

module {

    type AttributeDataType = Datatypes.AttributeDataType;
    type AttributeDataValue = Datatypes.AttributeDataValue;
    type Item = Database.Item;
    type AttributeName = Database.AttributeName;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public func unwrapAttributeDataValue({
        attributeDataValue : AttributeDataValue;
    }) : (AttributeDataType) {

        var unwrappedAttributeDataType : AttributeDataType = #default;

        switch (attributeDataValue) {
            case (#int(_intValue)) { unwrappedAttributeDataType := #int };
            case (#int8(_int8Value)) { unwrappedAttributeDataType := #int8 };
            case (#int16(_int16Value)) { unwrappedAttributeDataType := #int16 };
            case (#int32(_int32Value)) { unwrappedAttributeDataType := #int32 };
            case (#int64(_int64Value)) { unwrappedAttributeDataType := #int64 };
            case (#nat(_natValue)) { unwrappedAttributeDataType := #nat };
            case (#nat8(_nat8Value)) { unwrappedAttributeDataType := #nat8 };
            case (#nat16(_nat16Value)) { unwrappedAttributeDataType := #nat16 };
            case (#nat32(_nat32Value)) { unwrappedAttributeDataType := #nat32 };
            case (#nat64(_nat64Value)) { unwrappedAttributeDataType := #nat64 };
            case (#float(_floatValue)) { unwrappedAttributeDataType := #float };
            case (#text(_textValue)) { unwrappedAttributeDataType := #text };
            case (#char(_charValue)) { unwrappedAttributeDataType := #char };
            case (#bool(_boolValue)) { unwrappedAttributeDataType := #bool };
            case (#principal(_principalValue)) {
                unwrappedAttributeDataType := #principal;
            };
            case (#blob(_blobValue)) { unwrappedAttributeDataType := #blob };
            case (#list(_listValue)) { unwrappedAttributeDataType := #list };
            case (#map(_mapValue)) { unwrappedAttributeDataType := #map };
            case (#default) { unwrappedAttributeDataType := #default };
        };

        return (unwrappedAttributeDataType);
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public func validateAttributeDataType({
        attributeDataValue : AttributeDataValue;
        expectedAttributeDataType : AttributeDataType;
    }) : {
        isValidAttributeDataType : Bool;
        actualAttributeDataType : AttributeDataType;
    } {

        let actualAttributeDataType = unwrapAttributeDataValue({
            attributeDataValue;
        });

        return {
            isValidAttributeDataType = (actualAttributeDataType == expectedAttributeDataType);
            actualAttributeDataType;
        };
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public func validateAttributeDataTypes({
        attributeKeyDataValues : [(Text, AttributeDataValue)];
        attributeNameToMetadataMap : Map.Map<Text, Database.AttributeMetadata>;
    }) : {
        isValidAttributesDataType : Bool;
    } {

        let unwantedAttributes = Buffer.Buffer<Text>(0);
        let invalidAttributes = Buffer.Buffer<Text>(0);

        for ((attributeName, attributeDataValue) in attributeKeyDataValues.vals()) {
            let attributeExistInTable = Map.has(attributeNameToMetadataMap, thash, attributeName);

            if (attributeExistInTable) {
                var expectedAttributeDataType : Datatypes.AttributeDataType = #default;
                ignore do ? {
                    expectedAttributeDataType := Map.get(attributeNameToMetadataMap, thash, attributeName)!.dataType;
                };
                let {
                    isValidAttributeDataType;
                    actualAttributeDataType;
                } = validateAttributeDataType({
                    attributeDataValue;
                    expectedAttributeDataType;
                });

                if (not isValidAttributeDataType) {
                    invalidAttributes.add(attributeName);
                    Debug.print("attribute: " # debug_show (attributeName) # " has invalid data type: " # debug_show (actualAttributeDataType));
                };
            } else {
                unwantedAttributes.add(attributeName);
                Debug.print("attribute: " # debug_show (attributeName) # " is not in table");
            };
        };

        return {
            isValidAttributesDataType = invalidAttributes.size() == 0 and unwantedAttributes.size() == 0;
        };
    };

    private func checkUniqueIndexViolation(
        indexTable : Database.IndexTable,
        compoundKey : Text,
        itemIdToIgnore : ?Text,
    ) : Bool {
        let indexBTree = indexTable.items;

        switch (BTree.get(indexBTree, Text.compare, compoundKey)) {
            case (null) {
                return true;
            };
            case (?idSet) {
                let size = Set.size(idSet);

                if (size > 1) {
                    return false;
                };

                if (size == 0) {
                    return true;
                };

                switch (itemIdToIgnore) {
                    case (null) {
                        return false;
                    };
                    case (?id) {
                        return Set.has(idSet, thash, id);
                    };
                };
            };
        };
    };

    public func validateUniqueConstraints({
        itemDataMap : Map.Map<AttributeName, AttributeDataValue>;
        table : Database.Table;
        itemIdToIgnore : ?Text;
    }) : {
        violatedAttributes : ?[AttributeName];
        areConstraintsMet : Bool;
    } {
        for (indexMetadata in Vector.vals(table.metadata.indexes)) {
            if (indexMetadata.unique) {
                switch (Map.get(table.indexes, thash, indexMetadata.name)) {
                    case (null) {
                        Debug.print("CRITICAL: Inconsistency found. Metadata for index '" # indexMetadata.name # "' exists, but the index table does not.");
                        return {
                            violatedAttributes = ?indexMetadata.attributeNames;
                            areConstraintsMet = false;
                        };
                    };
                    case (?indexTable) {
                        switch (Utils.generateCompoundKey(itemDataMap, indexTable.attributeNames)) {
                            case (null) {};
                            case (?compoundKey) {
                                let isIndexValid = checkUniqueIndexViolation(
                                    indexTable,
                                    compoundKey,
                                    itemIdToIgnore,
                                );

                                if (not isIndexValid) {
                                    return {
                                        violatedAttributes = ?indexTable.attributeNames;
                                        areConstraintsMet = false;
                                    };
                                };
                            };
                        };
                    };
                };
            };
        };

        for (attr in Map.vals(table.metadata.attributesMap)) {
            if (attr.unique) {
                // This is a simplified check for single-attribute uniqueness.
                // A more robust implementation would have an implicit index for every `unique` attribute.
                // For now, this logic is deferred to the explicit unique index check above.
                // To make this work, a user MUST create a unique index on any attribute they mark as `unique`.
            };
        };

        return {
            violatedAttributes = null;
            areConstraintsMet = true;
        };
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

};
