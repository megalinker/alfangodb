import Database "../types/database";
import Datatypes "../types/datatype";
import InputTypes "../types/input";
import OutputTypes "../types/output";
import SearchTypes "../types/search";
import Map "mo:map/Map";
import { thash } "mo:map/Map";
import Debug "mo:base/Debug";
import Prelude "mo:base/Prelude";
import Text "mo:base/Text";
import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Set "mo:map/Set";
import Utils "../utils";
module {

    type AttributeDataValue = Datatypes.AttributeDataValue;
    type NumericAttributeDataValue = Datatypes.NumericAttributeDataValue;
    type StringAttributeDataValue = Datatypes.StringAttributeDataValue;

    type RelationalExpressionAttributeDataValue = SearchTypes.RelationalExpressionAttributeDataValue;
    type FilterExpressionConditionType = SearchTypes.FilterExpressionConditionType;
    type FilterExpressionType = SearchTypes.FilterExpressionType;
    type ContaintmentExpressionAttributeDataValue = SearchTypes.ContaintmentExpressionAttributeDataValue;

    private func findIndexableFilter(
        table : Database.Table,
        filterExpressions : [FilterExpressionType],
    ) : ?(Text, Datatypes.AttributeDataValue, [FilterExpressionType]) {

        var i = 0;
        while (i < filterExpressions.size()) {
            let filter = filterExpressions[i];

            // Check if the filter is an #EQ filter
            switch (filter.filterExpressionCondition) {
                case (#EQ(value)) {
                    // Check if the attribute for this #EQ filter is indexed
                    if (Map.has(table.indexes, thash, filter.attributeName)) {
                        // Found an optimizable filter!
                        // Now, build an array of all the OTHER filters.
                        let otherFilters = Buffer.Buffer<FilterExpressionType>(filterExpressions.size() - 1);
                        var j = 0;
                        while (j < filterExpressions.size()) {
                            if (i != j) {
                                otherFilters.add(filterExpressions[j]);
                            };
                            j += 1;
                        };
                        // Return the index name, the value to look up, and the remaining filters.
                        return ?(filter.attributeName, value, Buffer.toArray(otherFilters));
                    };
                };
                case (_) {
                    // Not an #EQ filter, do nothing.
                };
            };
            i += 1;
        };

        // No indexable filter was found after checking all expressions.
        return null;
    };

    public func scan({
        scanInput : InputTypes.ScanInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.ScanOutputType {

        // get databases
        let databases = alfangoDB.databases;

        let { databaseName; tableName; filterExpressions } = scanInput;

        // check if database exists
        if (not Map.has(databases, thash, databaseName)) {
            let remark = "database does not exist: " # debug_show (databaseName);
            Debug.print(remark);
            return #err([remark]);
        };

        ignore do ? {
            let database = Map.get(databases, thash, databaseName)!;

            // check if table exists
            if (not Map.has(database.tables, thash, tableName)) {
                let remark = "table does not exist: " # debug_show (tableName);
                Debug.print(remark);
                return #err([remark]);
            };

            let table = Map.get(database.tables, thash, tableName)!;
            let filteredItemsBuffer = Buffer.Buffer<OutputTypes.ItemOutputType>(0);

            switch (findIndexableFilter(table, filterExpressions)) {
                case (null) {
                    Debug.print("Scan strategy: Full table scan");
                    let filteredItemMap = Map.filter(
                        table.items,
                        thash,
                        func(_itemId : Database.Id, item : Database.Item) : Bool {
                            applyFilterExpression({ item; filterExpressions });
                        },
                    );

                    for (filteredItem in Map.vals(filteredItemMap)) {
                        filteredItemsBuffer.add({
                            id = filteredItem.id;
                            item = Map.toArray(filteredItem.attributeDataValueMap);
                        });
                    };
                };
                case (?(indexName, valueToFind, remainingFilters)) {
                    Debug.print("Scan strategy: Index scan on '" # indexName # "'");

                    let indexTable = Map.get(table.indexes, thash, indexName)!;

                    switch (Map.get(indexTable.items, Utils.DataTypeValueHashUtils, valueToFind)) {
                        case (null) {};
                        case (?idSet) {
                            for (itemId in Set.keys(idSet)) {
                                let item = Map.get(table.items, thash, itemId)!;
                                if (applyFilterExpression({ item; filterExpressions = remainingFilters })) {
                                    filteredItemsBuffer.add({
                                        id = item.id;
                                        item = Map.toArray(item.attributeDataValueMap);
                                    });
                                };
                            };
                        };
                    };
                };
            };

            return #ok(Buffer.toArray(filteredItemsBuffer));
        };

        Prelude.unreachable();
    };

    public func scanAndGetIds({
        scanAndGetIdsInput : InputTypes.ScanAndGetIdsInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.ScanAndGetIdsOutputType {

        // get databases
        let databases = alfangoDB.databases;

        let { databaseName; tableName; filterExpressions } = scanAndGetIdsInput;

        // check if database exists
        if (not Map.has(databases, thash, databaseName)) {
            let remark = "database does not exist: " # debug_show (databaseName);
            Debug.print(remark);
            return #err([remark]);
        };

        ignore do ? {
            let database = Map.get(databases, thash, databaseName)!;

            // check if table exists
            if (not Map.has(database.tables, thash, tableName)) {
                let remark = "table does not exist: " # debug_show (tableName);
                Debug.print(remark);
                return #err([remark]);
            };

            let table = Map.get(database.tables, thash, tableName)!;
            let tableItems = table.items;

            let filteredItemIdsBuffer = Buffer.Buffer<Text>(0);
            for (item in Map.vals(tableItems)) {
                // apply filter expression
                if (applyFilterExpression({ item; filterExpressions })) {
                    filteredItemIdsBuffer.add(item.id);
                };
            };

            return #ok({
                ids = Buffer.toArray(filteredItemIdsBuffer);
            });
        };

        Prelude.unreachable();
    };

    public func paginatedScan({
        paginatedScanInput : InputTypes.PaginatedScanInputType;
        alfangoDB : Database.AlfangoDB;
    }) : OutputTypes.PaginatedScanOutputType {

        let databases = alfangoDB.databases;
        let { databaseName; tableName; filterExpressions; limit; offset } = paginatedScanInput;

        if (not Map.has(databases, thash, databaseName)) {
            let remark = "database does not exist: " # debug_show (databaseName);
            Debug.print(remark);
            return #err([remark]);
        };

        ignore do ? {
            let database = Map.get(databases, thash, databaseName)!;

            if (not Map.has(database.tables, thash, tableName)) {
                let remark = "table does not exist: " # debug_show (tableName);
                Debug.print(remark);
                return #err([remark]);
            };

            let table = Map.get(database.tables, thash, tableName)!;

            let allFilteredItems = Buffer.Buffer<Database.Item>(0);
            for (item in Map.vals(table.items)) {
                if (applyFilterExpression({ item; filterExpressions })) {
                    allFilteredItems.add(item);
                };
            };

            let allFilteredItemsArray = Buffer.toArray(allFilteredItems);
            let totalMatchCount = allFilteredItemsArray.size();

            if (offset >= totalMatchCount and totalMatchCount > 0) {
                return #err(["offset is greater than the total number of matching items"]);
            };

            if (limit == 0) {
                return #err(["limit should be greater than 0"]);
            };

            let sliceLength = if (offset + limit > totalMatchCount) {
                totalMatchCount - offset;
            } else {
                limit;
            };

            var finalItemsPage : [{
                id : Text;
                item : [(Text, Datatypes.AttributeDataValue)];
            }] = [];
            if (sliceLength > 0) {
                let slicedItemArray = Array.subArray<Database.Item>(allFilteredItemsArray, offset, sliceLength);
                finalItemsPage := Array.map<Database.Item, { id : Text; item : [(Text, Datatypes.AttributeDataValue)] }>(
                    slicedItemArray,
                    func(item) {
                        return {
                            id = item.id;
                            item = Map.toArray(item.attributeDataValueMap);
                        };
                    },
                );
            };

            return #ok({
                items = finalItemsPage;
                offset;
                limit;
                scannedItemCount = Map.size(table.items);
                nonScannedItemCount = totalMatchCount;
            });
        };

        Prelude.unreachable();
    };

    private func applyFilterExpression({
        item : Database.Item;
        filterExpressions : [FilterExpressionType];
    }) : Bool {

        let attributeDataValueMap = item.attributeDataValueMap;
        var filterExpressionResult = true;

        // iterate over filter expressions and apply them
        for (filterExpression in filterExpressions.vals()) {
            let { attributeName; filterExpressionCondition } = filterExpression;

            var currentFilterExpressionResult = false;
            // check if attribute exists
            if (Map.has(attributeDataValueMap, thash, attributeName)) {
                ignore do ? {
                    // apply filter expression condition when attribute exists
                    currentFilterExpressionResult := applyFilterExpressionCondition({
                        filterExpressionCondition;
                        attributeDataValue = Map.get(attributeDataValueMap, thash, attributeName)!;
                    });
                };
            }
            // if attribute does not exist, apply #NOT_EXISTS condition
            else if (filterExpressionCondition == #NOT_EXISTS) {
                currentFilterExpressionResult := true;
            };

            filterExpressionResult := filterExpressionResult and currentFilterExpressionResult;
        };

        return filterExpressionResult;
    };

    private func applyFilterExpressionCondition({
        filterExpressionCondition : FilterExpressionConditionType;
        attributeDataValue : AttributeDataValue;
    }) : Bool {

        switch (filterExpressionCondition) {
            case (#EQ(conditionAttributeDataValue)) {
                return applyFilterEQ({
                    attributeDataValue;
                    conditionAttributeDataValue;
                });
            };
            case (#NEQ(conditionAttributeDataValue)) {
                return not applyFilterEQ({
                    attributeDataValue;
                    conditionAttributeDataValue;
                });
            };
            case (#LT(conditionAttributeDataValue)) {
                return applyFilterLT({
                    attributeDataValue;
                    conditionAttributeDataValue;
                });
            };
            case (#LTE(conditionAttributeDataValue)) {
                return applyFilterLTE({
                    attributeDataValue;
                    conditionAttributeDataValue;
                });
            };
            case (#GT(conditionAttributeDataValue)) {
                return not applyFilterLTE({
                    attributeDataValue;
                    conditionAttributeDataValue;
                });
            };
            case (#GTE(conditionAttributeDataValue)) {
                return not applyFilterLT({
                    attributeDataValue;
                    conditionAttributeDataValue;
                });
            };
            case (#EXISTS) {
                return true;
            };
            case (#NOT_EXISTS) {
                return false;
            };
            case (#BEGINS_WITH(conditionAttributeDataValue)) {
                return applyFilterBEGINS_WITH({
                    attributeDataValue;
                    conditionAttributeDataValue;
                });
            };
            case (#CONTAINS(conditionAttributeDataValue)) {
                return applyFilterCONTAINS({
                    attributeDataValue;
                    conditionAttributeDataValue;
                });
            };
            case (#NOT_CONTAINS(conditionAttributeDataValue)) {
                return not applyFilterCONTAINS({
                    attributeDataValue;
                    conditionAttributeDataValue;
                });
            };
            case (#IN(conditionAttributeDataValue)) {
                return applyFilterIN({
                    attributeDataValue;
                    conditionAttributeDataValue;
                });
            };
            case (#BETWEEN(conditionAttributeDataValue)) {
                return applyFilterBETWEEN({
                    attributeDataValue;
                    conditionAttributeDataValue;
                });
            };
            case (#NOT_BETWEEN(conditionAttributeDataValue)) {
                return not applyFilterBETWEEN({
                    attributeDataValue;
                    conditionAttributeDataValue;
                });
            };
        };

        return false;
    };

    private func applyFilterEQ({
        attributeDataValue : AttributeDataValue;
        conditionAttributeDataValue : RelationalExpressionAttributeDataValue;
    }) : Bool {
        return Utils.areEqual(attributeDataValue, conditionAttributeDataValue);
    };

    private func applyFilterLT({
        attributeDataValue : AttributeDataValue;
        conditionAttributeDataValue : RelationalExpressionAttributeDataValue;
    }) : Bool {

        var isLessThan = false;
        switch (conditionAttributeDataValue) {
            case (#int(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#int(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#int8(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#int8(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#int16(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#int16(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#int32(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#int32(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#int64(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#int64(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#nat(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#nat(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#nat8(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#nat8(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#nat16(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#nat16(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#nat32(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#nat32(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#nat64(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#nat64(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#float(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#float(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#text(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#text(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#char(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#char(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#bool(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#bool(attributeDataValue)) isLessThan := false;
                    case (_) isLessThan := false;
                };
            };
            case (#blob(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#blob(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
            case (#principal(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#principal(attributeDataValue)) isLessThan := attributeDataValue < inputDataValue;
                    case (_) isLessThan := false;
                };
            };
        };

        return isLessThan;
    };

    private func applyFilterLTE({
        attributeDataValue : AttributeDataValue;
        conditionAttributeDataValue : RelationalExpressionAttributeDataValue;
    }) : Bool {

        var isLessThanOrEqual = false;
        switch (conditionAttributeDataValue) {
            case (#int(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#int(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#int8(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#int8(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#int16(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#int16(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#int32(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#int32(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#int64(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#int64(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#nat(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#nat(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#nat8(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#nat8(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#nat16(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#nat16(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#nat32(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#nat32(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#nat64(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#nat64(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#float(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#float(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#text(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#text(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#char(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#char(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#bool(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#bool(attributeDataValue)) isLessThanOrEqual := attributeDataValue == inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#blob(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#blob(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
            case (#principal(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#principal(attributeDataValue)) isLessThanOrEqual := attributeDataValue <= inputDataValue;
                    case (_) isLessThanOrEqual := false;
                };
            };
        };

        return isLessThanOrEqual;
    };

    private func applyFilterBEGINS_WITH({
        attributeDataValue : AttributeDataValue;
        conditionAttributeDataValue : StringAttributeDataValue;
    }) : Bool {

        var beginsWith = false;
        switch (conditionAttributeDataValue) {
            case (#text(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#text(attributeDataValue)) beginsWith := Text.startsWith(attributeDataValue, #text inputDataValue);
                    case (_) beginsWith := false;
                };
            };
            case (#char(inputDataValue)) {
                switch (attributeDataValue) {
                    case (#char(attributeDataValue)) beginsWith := attributeDataValue == inputDataValue;
                    case (_) beginsWith := false;
                };
            };
        };

        return beginsWith;
    };

    private func applyFilterCONTAINS({
        attributeDataValue : AttributeDataValue;
        conditionAttributeDataValue : ContaintmentExpressionAttributeDataValue;
    }) : Bool {
        switch (conditionAttributeDataValue) {
            case (#text(substringToFind)) {
                switch (attributeDataValue) {
                    case (#text(textToSearchIn)) {
                        return Text.contains(textToSearchIn, #text substringToFind);
                    };
                    case (_) { return false };
                };
            };
            case (#char(charToFind)) {
                switch (attributeDataValue) {
                    case (#text(textToSearchIn)) {
                        return Text.contains(textToSearchIn, #char charToFind);
                    };
                    case (#char(charToSearchIn)) {
                        return charToFind == charToSearchIn;
                    };
                    case (_) { return false };
                };
            };
            case (#list(valuesToFind)) {
                switch (attributeDataValue) {
                    case (#list(dbList)) {
                        for (valueToFind in valuesToFind.vals()) {
                            for (dbValue in dbList.vals()) {
                                if (applyFilterEQ({ attributeDataValue = dbValue; conditionAttributeDataValue = valueToFind })) {
                                    return true;
                                };
                            };
                        };
                        return false;
                    };
                    case (_) { return false };
                };
            };
        };
    };

    private func applyFilterIN({
        attributeDataValue : AttributeDataValue;
        conditionAttributeDataValue : [RelationalExpressionAttributeDataValue];
    }) : Bool {

        return Array.find<RelationalExpressionAttributeDataValue>(
            conditionAttributeDataValue,
            func(conditionAttributeDataValueInValue : RelationalExpressionAttributeDataValue) : Bool {
                applyFilterEQ({
                    attributeDataValue;
                    conditionAttributeDataValue = conditionAttributeDataValueInValue;
                });
            },
        ) != null;
    };

    private func applyFilterBETWEEN({
        attributeDataValue : AttributeDataValue;
        conditionAttributeDataValue : (RelationalExpressionAttributeDataValue, RelationalExpressionAttributeDataValue);
    }) : Bool {

        var isBetween = false;
        switch (conditionAttributeDataValue) {
            case ((#int(lowerInputDataValue), #int(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#int(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case ((#int8(lowerInputDataValue), #int8(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#int8(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case ((#int16(lowerInputDataValue), #int16(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#int16(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case ((#int32(lowerInputDataValue), #int32(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#int32(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case ((#int64(lowerInputDataValue), #int64(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#int64(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case ((#nat(lowerInputDataValue), #nat(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#nat(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case ((#nat8(lowerInputDataValue), #nat8(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#nat8(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case ((#nat16(lowerInputDataValue), #nat16(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#nat16(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case ((#nat32(lowerInputDataValue), #nat32(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#nat32(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case ((#nat64(lowerInputDataValue), #nat64(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#nat64(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case ((#float(lowerInputDataValue), #float(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#float(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case ((#text(lowerInputDataValue), #text(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#text(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case ((#char(lowerInputDataValue), #char(upperInputDataValue))) {
                switch (attributeDataValue) {
                    case (#char(attributeDataValue)) isBetween := lowerInputDataValue <= attributeDataValue and attributeDataValue <= upperInputDataValue;
                    case (_) isBetween := false;
                };
            };
            case _ {
                Prelude.unreachable();
            };
        };

        return isBetween;
    };

};
