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
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import HashMap "mo:base/HashMap";
import Set "mo:map/Set";
import Utils "../utils";
import BTree "mo:stableheapbtreemap/BTree";
module {

    type AttributeDataValue = Datatypes.AttributeDataValue;
    type NumericAttributeDataValue = Datatypes.NumericAttributeDataValue;
    type StringAttributeDataValue = Datatypes.StringAttributeDataValue;

    type RelationalExpressionAttributeDataValue = SearchTypes.RelationalExpressionAttributeDataValue;
    type FilterExpressionConditionType = SearchTypes.FilterExpressionConditionType;
    type FilterExpressionType = SearchTypes.FilterExpressionType;
    type ContaintmentExpressionAttributeDataValue = SearchTypes.ContaintmentExpressionAttributeDataValue;
    let UNBOUNDED_UPPER_KEY = "\u{10FFFF}";

    public type QueryPlan = {
        #IndexScan : {
            indexName : Text;
            scanBounds : { lower : Text; upper : Text };
            remainingFilter : SearchTypes.QueryFilter;
        };
        #FullTableScan : {
            filter : SearchTypes.QueryFilter;
        };
    };

    type ScanBounds = {
        lower : AttributeDataValue;
        upper : AttributeDataValue;
    };

    let INDEX_SCAN_BATCH_SIZE : Nat = 100;
    let FULL_SCAN_INTERNAL_BATCH_SIZE : Nat = 100;
    let INDEX_SCAN_INTERNAL_BATCH_SIZE : Nat = 50;

    private func _executePaginatedFullScanBatch(
        table : Database.Table,
        filter : SearchTypes.QueryFilter,
        limit : Nat,
        cursor : ?Text,
    ) : {
        items : [OutputTypes.ItemOutputType];
        nextCursor : ?SearchTypes.PaginatedScanCursor;
    } {
        let resultsBuffer = Buffer.Buffer<OutputTypes.ItemOutputType>(0);
        var continueScanning = true;
        var lastProcessedId : ?Text = cursor;

        label scan_loop while (continueScanning and resultsBuffer.size() <= limit) {
            let startKey = switch (lastProcessedId) {
                case null { "" };
                case (?id) { id };
            };

            // Scan a batch from the main items B-Tree.
            let scanResult = BTree.scanLimit<Text, Database.Item>(
                table.items,
                Text.compare,
                startKey,
                UNBOUNDED_UPPER_KEY,
                #fwd,
                FULL_SCAN_INTERNAL_BATCH_SIZE,
            );

            if (scanResult.results.size() == 0) {
                continueScanning := false;
                continue scan_loop;
            };

            var itemsToProcess = scanResult.results;
            if (lastProcessedId != null and itemsToProcess.size() > 0 and itemsToProcess[0].0 == startKey) {
                // Skip the cursor item from the previous page.
                itemsToProcess := Iter.toArray(Array.slice(itemsToProcess, 1, itemsToProcess.size()));
            };

            if (itemsToProcess.size() == 0) {};

            for ((itemId, item) in itemsToProcess.vals()) {
                lastProcessedId := ?itemId;
                if (evaluateFilter(item, filter)) {
                    resultsBuffer.add({
                        id = item.id;
                        item = Map.toArray(item.attributeDataValueMap);
                    });
                    if (resultsBuffer.size() > limit) {
                        break scan_loop;
                    };
                };
            };

            if (scanResult.results.size() < FULL_SCAN_INTERNAL_BATCH_SIZE) {
                // We've reached the end of the table.
                continueScanning := false;
            };
        };

        let hasMore = resultsBuffer.size() > limit;
        var itemsToReturn = Buffer.toArray(resultsBuffer);
        var nextCursor : ?SearchTypes.PaginatedScanCursor = null;

        if (hasMore) {
            let lastId = itemsToReturn[limit - 1].id;
            nextCursor := ?{
                plan = #FullTableScan({ filter });
                lastId = lastId;
            };
            itemsToReturn := Iter.toArray(Array.slice(itemsToReturn, 0, limit));
        };

        return {
            items = itemsToReturn;
            nextCursor = nextCursor;
        };
    };

    private func _executePaginatedIndexScanBatch(
        table : Database.Table,
        plan : {
            indexName : Text;
            scanBounds : { lower : Text; upper : Text };
            remainingFilter : SearchTypes.QueryFilter;
        },
        limit : Nat,
        cursorItemId : ?Text,
    ) : {
        items : [OutputTypes.ItemOutputType];
        nextCursor : ?SearchTypes.PaginatedScanCursor;
    } {
        let { indexName; scanBounds; remainingFilter } = plan;

        let indexTable = switch (Map.get(table.indexes, thash, indexName)) {
            case null { Prelude.unreachable() };
            case (?idx) { idx };
        };

        let resultsBuffer = Buffer.Buffer<OutputTypes.ItemOutputType>(0);
        var continueScanningIndex = true;
        var indexCursor : ?Text = ?scanBounds.lower;
        var pastItemCursor = (cursorItemId == null);

        // label the outer while
        label scan_loop while (continueScanningIndex and resultsBuffer.size() <= limit) {
            let lowerBound = switch (indexCursor) {
                case (?c) { c };
                case null { scanBounds.lower };
            };

            let scanResult = BTree.scanLimit<Text, Set.Set<Text>>(
                indexTable.items,
                Text.compare,
                lowerBound,
                scanBounds.upper,
                #fwd,
                INDEX_SCAN_INTERNAL_BATCH_SIZE,
            );

            // nothing more in the index
            if (scanResult.results.size() == 0) {
                continueScanningIndex := false;
                continue scan_loop;
            };

            var lastProcessedKeyInBatch : Text = "";

            // label the loop over index entries
            label key_loop for ((compoundKey, idSet) in scanResult.results.vals()) {
                lastProcessedKeyInBatch := compoundKey;

                // skip until we pass the cursor item
                if (compoundKey == lowerBound and not pastItemCursor) {
                    // (we’ll catch up on the first id_loop below)
                };

                // label the inner loop over all item-IDs in this set
                label id_loop for (itemId in Set.keys(idSet)) {
                    if (not pastItemCursor) {
                        // only start collecting once we’ve moved past the cursorItemId
                        switch (cursorItemId) {
                            case (?cId) if (itemId == cId) {
                                pastItemCursor := true;
                            };
                            case (_) {};
                        };
                        if (not pastItemCursor) {
                            continue id_loop;
                        };
                    };

                    // fetch the real item and apply the remainingFilter
                    switch (BTree.get(table.items, Text.compare, itemId)) {
                        case (?item) {
                            if (evaluateFilter(item, remainingFilter)) {
                                resultsBuffer.add({
                                    id = item.id;
                                    item = Map.toArray(item.attributeDataValueMap);
                                });
                                // once we have limit+1, we can stop immediately
                                if (resultsBuffer.size() > limit) {
                                    break scan_loop;
                                };
                            };
                        };
                        case (null) { /* item was deleted; skip */ };
                    };
                }; // end id_loop
            }; // end key_loop

            // advance the index cursor for the next batch
            indexCursor := ?(lastProcessedKeyInBatch # "\u{0}");

            // if we scanned fewer than the batch size, we’re at the end
            if (scanResult.results.size() < INDEX_SCAN_INTERNAL_BATCH_SIZE) {
                continueScanningIndex := false;
            };
        }; // end scan_loop

        // build the true “hasMore?” logic
        let hasMore = resultsBuffer.size() > limit;
        var itemsToReturn = Buffer.toArray(resultsBuffer);
        var nextCursor : ?SearchTypes.PaginatedScanCursor = null;

        if (hasMore) {
            let lastId = itemsToReturn[limit - 1].id;
            nextCursor := ?{
                plan = #IndexScan(plan);
                lastId = lastId;
            };
            itemsToReturn := Iter.toArray(Array.slice(itemsToReturn, 0, limit));
        };

        return {
            items = itemsToReturn;
            nextCursor = nextCursor;
        };
    };

    private func _iterativeIndexScanForItems({
        table : Database.Table;
        indexName : Text;
        scanBounds : { lower : Text; upper : Text };
        remainingFilter : SearchTypes.QueryFilter;
    }) : [OutputTypes.ItemOutputType] {
        let resultsBuffer = Buffer.Buffer<OutputTypes.ItemOutputType>(0);
        let indexTable = switch (Map.get(table.indexes, thash, indexName)) {
            case (null) { Prelude.unreachable() };
            case (?idx) { idx };
        };

        var continueScanning = true;
        // The cursor now tracks the last processed compound key and item ID.
        var cursor : ?(Text, Text) = null;

        label scan_loop while (continueScanning) {
            let (lowerBound, startId) = switch (cursor) {
                case (null) { (scanBounds.lower, null) };
                case (?(lastKey, lastId)) { (lastKey, ?lastId) };
            };

            let scanResult = BTree.scanLimit<Text, Set.Set<Text>>(
                indexTable.items,
                Text.compare,
                lowerBound,
                scanBounds.upper,
                #fwd,
                INDEX_SCAN_BATCH_SIZE,
            );

            if (scanResult.results.size() == 0) {
                break scan_loop;
            };

            var lastProcessedInBatch : ?(Text, Text) = cursor;

            for ((compoundKey, idSet) in scanResult.results.vals()) {
                for (itemId in Set.keys(idSet)) {
                    var processThisItem = true;
                    if (compoundKey == lowerBound) {
                        switch (startId) {
                            case (?s_id) {
                                if (Text.compare(itemId, s_id) != #greater) {
                                    processThisItem := false;
                                };
                            };
                            case (null) {};
                        };
                    };

                    if (processThisItem) {
                        switch (BTree.get(table.items, Text.compare, itemId)) {
                            case (null) { /* Item deleted, skip */ };
                            case (?item) {
                                if (evaluateFilter(item, remainingFilter)) {
                                    resultsBuffer.add({
                                        id = item.id;
                                        item = Map.toArray(item.attributeDataValueMap);
                                    });
                                };
                            };
                        };
                    };
                    lastProcessedInBatch := ?(compoundKey, itemId);
                };
            };

            switch (cursor, lastProcessedInBatch) {
                case (?c, ?lc) {
                    if (c.0 == lc.0 and c.1 == lc.1) {
                        continueScanning := false;
                    };
                };
                case (_, _) {};
            };

            cursor := lastProcessedInBatch;
        };

        return Buffer.toArray(resultsBuffer);
    };

    private func _iterativeIndexScanForIds({
        table : Database.Table;
        indexName : Text;
        scanBounds : { lower : Text; upper : Text };
        remainingFilter : SearchTypes.QueryFilter;
    }) : [Text] {
        let resultsBuffer = Buffer.Buffer<Text>(0);
        let indexTable = switch (Map.get(table.indexes, thash, indexName)) {
            case (null) { Prelude.unreachable() };
            case (?idx) { idx };
        };

        var continueScanning = true;
        var cursor : ?(Text, Text) = null;

        label scan_loop while (continueScanning) {
            let (lowerBound, startId) = switch (cursor) {
                case (null) { (scanBounds.lower, null) };
                case (?(lastKey, lastId)) { (lastKey, ?lastId) };
            };

            let scanResult = BTree.scanLimit<Text, Set.Set<Text>>(
                indexTable.items,
                Text.compare,
                lowerBound,
                scanBounds.upper,
                #fwd,
                INDEX_SCAN_BATCH_SIZE,
            );

            if (scanResult.results.size() == 0) {
                break scan_loop;
            };

            var lastProcessedInBatch : ?(Text, Text) = cursor;

            for ((compoundKey, idSet) in scanResult.results.vals()) {
                for (itemId in Set.keys(idSet)) {
                    var processThisItem = true;
                    if (compoundKey == lowerBound) {
                        switch (startId) {
                            case (?s_id) {
                                if (Text.compare(itemId, s_id) != #greater) {
                                    processThisItem := false;
                                };
                            };
                            case (null) {};
                        };
                    };

                    if (processThisItem) {
                        switch (BTree.get(table.items, Text.compare, itemId)) {
                            case (null) { /* Item deleted, skip */ };
                            case (?item) {
                                if (evaluateFilter(item, remainingFilter)) {
                                    resultsBuffer.add(item.id);
                                };
                            };
                        };
                    };
                    lastProcessedInBatch := ?(compoundKey, itemId);
                };
            };

            switch (cursor, lastProcessedInBatch) {
                case (?c, ?lc) {
                    if (c.0 == lc.0 and c.1 == lc.1) {
                        continueScanning := false;
                    };
                };
                case (_, _) {};
            };

            cursor := lastProcessedInBatch;
        };

        return Buffer.toArray(resultsBuffer);
    };

    private func evaluateFilter(item : Database.Item, filter : SearchTypes.QueryFilter) : Bool {
        switch (filter) {
            case (#expression(expr)) {
                let { attributeNames; filterExpressionCondition } = expr;
                let attributeDataValueMap = item.attributeDataValueMap;

                var currentFilterExpressionResult = false;
                switch (Map.get(attributeDataValueMap, thash, attributeNames)) {
                    case (?attributeDataValue) {
                        currentFilterExpressionResult := applyFilterExpressionCondition({
                            filterExpressionCondition;
                            attributeDataValue;
                        });
                    };
                    case (null) {
                        if (filterExpressionCondition == #NOT_EXISTS) {
                            currentFilterExpressionResult := true;
                        };
                    };
                };
                return currentFilterExpressionResult;
            };
            case (#AND(filters)) {
                for (subFilter in filters.vals()) {
                    if (not evaluateFilter(item, subFilter)) {
                        return false;
                    };
                };
                return true;
            };
            case (#OR(filters)) {
                for (subFilter in filters.vals()) {
                    if (evaluateFilter(item, subFilter)) {
                        return true;
                    };
                };
                return false;
            };
        };
    };

    private func findIndexableFilter(
        table : Database.Table,
        filter : SearchTypes.QueryFilter,
    ) : ?(Text, { lower : Text; upper : Text }, SearchTypes.QueryFilter) {

        // Helper to extract range bounds from a filter condition
        func getRangeBounds(expr : SearchTypes.FilterExpressionType) : ?{
            lower : AttributeDataValue;
            upper : AttributeDataValue;
        } {
            switch (expr.filterExpressionCondition) {
                // For GTE, upper bound is effectively infinite (represented by a high-range value)
                case (#GTE(value)) {
                    return ?{ lower = value; upper = #map([]) };
                };
                // For LTE, lower bound is effectively negative infinite (represented by a low-range value)
                case (#LTE(value)) {
                    return ?{ lower = #default; upper = value };
                };
                case (#BETWEEN(lower, upper)) {
                    return ?{ lower = lower; upper = upper };
                };
                case (_) { return null };
            };
        };

        // 1. Extract all top-level filters. We can only use an index for top-level AND conditions.
        let topLevelFilters = switch (filter) {
            case (#AND(filters)) { filters };
            case (#expression(_)) { [filter] };
            case (#OR(_)) { return null }; // OR queries cannot use a single index scan.
        };

        // 2. Create a quick-lookup map of all attribute filters.
        let filterMap = HashMap.HashMap<Database.AttributeName, SearchTypes.FilterExpressionType>(0, Text.equal, Text.hash);
        for (f in topLevelFilters.vals()) {
            switch (f) {
                case (#expression(expr)) {
                    filterMap.put(expr.attributeNames, expr);
                };
                case (_) {};
            };
        };

        var bestMatch : ?{
            indexName : Text;
            eqMatchCount : Nat;
            rangeFilter : ?SearchTypes.FilterExpressionType;
        } = null;

        // 3. Iterate through all available indexes on the table to find the best one.
        for ((indexName, indexTable) in Map.entries(table.indexes)) {
            var currentEqMatchCount : Nat = 0;
            var prefixIsContinuous = true;

            // 3a. Find the longest continuous prefix of the index that can be satisfied by EQ filters.
            for (attrName in indexTable.attributeNames.vals()) {
                if (prefixIsContinuous) {
                    switch (filterMap.get(attrName)) {
                        case (?{ filterExpressionCondition = #EQ(_) }) {
                            // This attribute in the index has a corresponding EQ filter.
                            currentEqMatchCount += 1;
                        };
                        case (_) {
                            // The prefix is broken. Stop counting EQ matches.
                            prefixIsContinuous := false;
                        };
                    };
                };
            };

            // 3b. After the EQ prefix, check if the *next* attribute in the index has a range filter.
            var currentRangeFilter : ?SearchTypes.FilterExpressionType = null;
            if (currentEqMatchCount < indexTable.attributeNames.size()) {
                // There's at least one attribute left in the index after the EQ prefix.
                let potentialRangeAttrName = indexTable.attributeNames[currentEqMatchCount];
                switch (filterMap.get(potentialRangeAttrName)) {
                    case (?expr) {
                        if (getRangeBounds(expr) != null) {
                            currentRangeFilter := ?expr;
                        };
                    };
                    case (null) {};
                };
            };

            // 4. Score this index. An EQ match is better than a range match.
            // (Score: 2 points for each EQ match, 1 point for a range match).
            let thisMatchStrength = currentEqMatchCount * 2 + (if (currentRangeFilter != null) 1 else 0);
            let bestMatchStrength = switch (bestMatch) {
                case (null) { 0 };
                case (?bm) {
                    bm.eqMatchCount * 2 + (if (bm.rangeFilter != null) 1 else 0);
                };
            };

            if (thisMatchStrength > 0 and thisMatchStrength > bestMatchStrength) {
                bestMatch := ?{
                    indexName = indexName;
                    eqMatchCount = currentEqMatchCount;
                    rangeFilter = currentRangeFilter;
                };
            };
        };

        // 5. If no suitable index was found, return null.
        if (bestMatch == null) { return null };

        // 6. Construct the scan bounds and remaining filter from the best-matched index.
        switch (bestMatch) {
            case (null) { Prelude.unreachable() };
            case (?match) {
                let indexTable = switch (Map.get(table.indexes, thash, match.indexName)) {
                    case (?idx) { idx };
                    case (null) { Prelude.unreachable() };
                };

                let usedAttrNames = HashMap.HashMap<Text, Bool>(0, Text.equal, Text.hash);

                // 6a. Build the prefix of the compound key from the EQ filters.
                let prefixKeyParts = Buffer.Buffer<Text>(match.eqMatchCount);
                var i = 0;
                while (i < match.eqMatchCount) {
                    let attrName = indexTable.attributeNames[i];
                    usedAttrNames.put(attrName, true);
                    let attrValue = switch (filterMap.get(attrName)) {
                        case (?{ filterExpressionCondition = #EQ(val) }) { val };
                        case (_) { Prelude.unreachable() };
                    };
                    prefixKeyParts.add(Utils.serializeValue(attrValue));
                    i += 1;
                };
                let keyPrefix = Text.join(Utils.COMPOUND_KEY_SEPARATOR, Iter.fromArray(Buffer.toArray(prefixKeyParts)));

                // 6b. Determine the lower and upper bounds for the B-Tree scan.
                let (lowerBound, upperBound) = switch (match.rangeFilter) {
                    case (null) {
                        (keyPrefix, keyPrefix # "~");
                    };
                    case (?rangeExpr) {
                        usedAttrNames.put(rangeExpr.attributeNames, true);
                        let rangeBounds = switch (getRangeBounds(rangeExpr)) {
                            case (?b) { b };
                            case (null) { Prelude.unreachable() };
                        };
                        let lowerPart = Utils.serializeValue(rangeBounds.lower);
                        let upperPart = Utils.serializeValue(rangeBounds.upper);

                        let sep = Utils.COMPOUND_KEY_SEPARATOR;
                        let lower = if (keyPrefix == "") lowerPart else keyPrefix # sep # lowerPart;
                        let upper = if (keyPrefix == "") upperPart else keyPrefix # sep # upperPart;
                        (lower, upper);
                    };
                };

                let scanBounds = { lower = lowerBound; upper = upperBound };

                // 6c. Collect all filters that were *not* used by the index scan.
                let remainingFilters = Buffer.Buffer<SearchTypes.QueryFilter>(0);
                for (f in topLevelFilters.vals()) {
                    var wasUsed = false;
                    switch (f) {
                        case (#expression(expr)) {
                            if (usedAttrNames.get(expr.attributeNames) != null) {
                                wasUsed := true;
                            };
                        };
                        case (_) {};
                    };
                    if (not wasUsed) {
                        remainingFilters.add(f);
                    };
                };

                let remainingFilter : SearchTypes.QueryFilter = #AND(Buffer.toArray(remainingFilters));
                return ?(match.indexName, scanBounds, remainingFilter);
            };
        };
    };

    public func scan({
        scanInput : InputTypes.ScanInputType;
        alfangoDB : Database.AlfangoDB;
    }) : async OutputTypes.ScanOutputType {

        let databases = alfangoDB.databases;
        let { databaseName; tableName; filter } = scanInput;

        if (not Map.has(databases, thash, databaseName)) {
            let remark = "database does not exist: " # debug_show (databaseName);
            Debug.print(remark);
            return #err([remark]);
        };

        switch (Map.get(databases, thash, databaseName)) {
            case (null) { return #err(["Database not found"]) };
            case (?database) {
                switch (Map.get(database.tables, thash, tableName)) {
                    case (null) {
                        return #err(["Table '" # tableName # "' not found"]);
                    };
                    case (?table) {
                        switch (findIndexableFilter(table, filter)) {
                            case (null) {
                                Debug.print("Scan strategy: Full table scan required, but not supported by this function.");
                                return #err(["Query is too broad and requires a full table scan. Please use the 'paginatedScan' method for this operation."]);
                            };
                            case (?(indexName, scanBounds, remainingFilter)) {
                                Debug.print("Scan strategy: Iterative Index range scan on '" # indexName # "'");
                                let items = _iterativeIndexScanForItems({
                                    table = table;
                                    indexName = indexName;
                                    scanBounds = scanBounds;
                                    remainingFilter = remainingFilter;
                                });
                                return #ok(items);
                            };
                        };
                    };
                };
            };
        };
    };

    public func scanAndGetIds({
        scanAndGetIdsInput : InputTypes.ScanAndGetIdsInputType;
        alfangoDB : Database.AlfangoDB;
    }) : async OutputTypes.ScanAndGetIdsOutputType {

        let databases = alfangoDB.databases;
        let { databaseName; tableName; filter } = scanAndGetIdsInput;

        if (not Map.has(databases, thash, databaseName)) {
            let remark = "database does not exist: " # debug_show (databaseName);
            Debug.print(remark);
            return #err([remark]);
        };

        switch (Map.get(databases, thash, databaseName)) {
            case (null) { return #err(["Database not found"]) };
            case (?database) {
                switch (Map.get(database.tables, thash, tableName)) {
                    case (null) {
                        return #err(["Table '" # tableName # "' not found"]);
                    };
                    case (?table) {
                        switch (findIndexableFilter(table, filter)) {
                            case (null) {
                                Debug.print("scanAndGetIds strategy: Full table scan required, but not supported by this function.");
                                return #err(["Query is too broad and requires a full table scan. Please use a paginated method for this operation."]);
                            };
                            case (?(indexName, scanBounds, remainingFilter)) {
                                Debug.print("scanAndGetIds strategy: Iterative Index range scan on '" # indexName # "'");
                                let ids = _iterativeIndexScanForIds({
                                    table = table;
                                    indexName = indexName;
                                    scanBounds = scanBounds;
                                    remainingFilter = remainingFilter;
                                });
                                return #ok({ ids = ids });
                            };
                        };
                    };
                };
            };
        };
    };

    public func paginatedScan({
        paginatedScanInput : InputTypes.PaginatedScanInputType;
        alfangoDB : Database.AlfangoDB;
    }) : async OutputTypes.PaginatedScanOutputType {

        let { databaseName; tableName; filter; limit; cursor } = paginatedScanInput;

        if (not Map.has(alfangoDB.databases, thash, databaseName)) {
            return #err(["database does not exist: " # debug_show (databaseName)]);
        };
        if (limit == 0) { return #err(["limit must be greater than 0"]) };

        switch (Map.get(alfangoDB.databases, thash, databaseName)) {
            case (null) { return #err(["Database not found"]) };
            case (?database) {
                switch (Map.get(database.tables, thash, tableName)) {
                    case (null) {
                        return #err(["Table '" # tableName # "' not found"]);
                    };
                    case (?table) {
                        let (plan, lastId) = switch (cursor) {
                            case (null) {
                                // First call: run the planner to get the query plan.
                                (findBestQueryPlan(table, filter), null);
                            };
                            case (?csr) {
                                // Subsequent call: reuse the plan from the cursor.
                                (csr.plan, ?csr.lastId);
                            };
                        };

                        let result : {
                            items : [OutputTypes.ItemOutputType];
                            nextCursor : ?SearchTypes.PaginatedScanCursor;
                        } = switch (plan) {
                            case (#FullTableScan(scanPlan)) {
                                Debug.print("paginatedScan strategy: Full Table Scan");
                                _executePaginatedFullScanBatch(table, scanPlan.filter, limit, lastId);
                            };
                            case (#IndexScan(scanPlan)) {
                                Debug.print("paginatedScan strategy: Index Scan on '" # scanPlan.indexName # "'");
                                _executePaginatedIndexScanBatch(table, scanPlan, limit, lastId);
                            };
                        };

                        return #ok({
                            items = result.items;
                            limit = limit;
                            hasMore = result.nextCursor != null;
                            nextCursor = result.nextCursor;
                        });
                    };
                };
            };
        };
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
            case (#bool(_inputDataValue)) {
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

    private func findBestQueryPlan(
        table : Database.Table,
        filter : SearchTypes.QueryFilter,
    ) : QueryPlan {

        func getRangeBounds(expr : SearchTypes.FilterExpressionType) : ?{
            lower : AttributeDataValue;
            upper : AttributeDataValue;
        } {
            switch (expr.filterExpressionCondition) {
                case (#GTE(value)) {
                    return ?{ lower = value; upper = #map([]) };
                };
                case (#LTE(value)) {
                    return ?{ lower = #default; upper = value };
                };
                case (#BETWEEN(lower, upper)) {
                    return ?{ lower = lower; upper = upper };
                };
                case (_) { return null };
            };
        };

        let topLevelFilters = switch (filter) {
            case (#AND(filters)) { filters };
            case (#expression(_)) { [filter] };
            case (#OR(_)) { return #FullTableScan({ filter }) };
        };

        let filterMap = HashMap.HashMap<Database.AttributeName, SearchTypes.FilterExpressionType>(0, Text.equal, Text.hash);
        for (f in topLevelFilters.vals()) {
            switch (f) {
                case (#expression(expr)) {
                    filterMap.put(expr.attributeNames, expr);
                };
                case (_) {};
            };
        };

        var bestMatch : ?{
            indexName : Text;
            eqMatchCount : Nat;
            rangeFilter : ?SearchTypes.FilterExpressionType;
        } = null;

        for ((indexName, indexTable) in Map.entries(table.indexes)) {
            var currentEqMatchCount : Nat = 0;
            var prefixIsContinuous = true;
            for (attrName in indexTable.attributeNames.vals()) {
                if (prefixIsContinuous) {
                    switch (filterMap.get(attrName)) {
                        case (?{ filterExpressionCondition = #EQ(_) }) {
                            currentEqMatchCount += 1;
                        };
                        case (_) {
                            prefixIsContinuous := false;
                        };
                    };
                };
            };
            var currentRangeFilter : ?SearchTypes.FilterExpressionType = null;
            if (currentEqMatchCount < indexTable.attributeNames.size()) {
                let potentialRangeAttrName = indexTable.attributeNames[currentEqMatchCount];
                switch (filterMap.get(potentialRangeAttrName)) {
                    case (?expr) {
                        if (getRangeBounds(expr) != null) {
                            currentRangeFilter := ?expr;
                        };
                    };
                    case (null) {};
                };
            };
            let thisMatchStrength = currentEqMatchCount * 2 + (if (currentRangeFilter != null) 1 else 0);
            let bestMatchStrength = switch (bestMatch) {
                case (null) { 0 };
                case (?bm) {
                    bm.eqMatchCount * 2 + (if (bm.rangeFilter != null) 1 else 0);
                };
            };
            if (thisMatchStrength > 0 and thisMatchStrength > bestMatchStrength) {
                bestMatch := ?{
                    indexName = indexName;
                    eqMatchCount = currentEqMatchCount;
                    rangeFilter = currentRangeFilter;
                };
            };
        };

        if (bestMatch == null) { return #FullTableScan({ filter }) };

        switch (bestMatch) {
            case (null) { Prelude.unreachable() };
            case (?match) {
                let indexTable = switch (Map.get(table.indexes, thash, match.indexName)) {
                    case (?idx) { idx };
                    case (null) { Prelude.unreachable() };
                };
                let usedAttrNames = HashMap.HashMap<Text, Bool>(0, Text.equal, Text.hash);
                let prefixKeyParts = Buffer.Buffer<Text>(match.eqMatchCount);
                var i = 0;
                while (i < match.eqMatchCount) {
                    let attrName = indexTable.attributeNames[i];
                    usedAttrNames.put(attrName, true);
                    let attrValue = switch (filterMap.get(attrName)) {
                        case (?{ filterExpressionCondition = #EQ(val) }) { val };
                        case (_) { Prelude.unreachable() };
                    };
                    prefixKeyParts.add(Utils.serializeValue(attrValue));
                    i += 1;
                };
                let keyPrefix = Text.join(Utils.COMPOUND_KEY_SEPARATOR, Iter.fromArray(Buffer.toArray(prefixKeyParts)));
                let (lowerBound, upperBound) = switch (match.rangeFilter) {
                    case (null) {
                        (keyPrefix, keyPrefix # "~");
                    };
                    case (?rangeExpr) {
                        usedAttrNames.put(rangeExpr.attributeNames, true);
                        let rangeBounds = switch (getRangeBounds(rangeExpr)) {
                            case (?b) { b };
                            case (null) { Prelude.unreachable() };
                        };
                        let lowerPart = Utils.serializeValue(rangeBounds.lower);
                        let upperPart = Utils.serializeValue(rangeBounds.upper);
                        let sep = Utils.COMPOUND_KEY_SEPARATOR;
                        let lower = if (keyPrefix == "") lowerPart else keyPrefix # sep # lowerPart;
                        let upper = if (keyPrefix == "") upperPart else keyPrefix # sep # upperPart;
                        (lower, upper);
                    };
                };
                let scanBounds = { lower = lowerBound; upper = upperBound };
                let remainingFilters = Buffer.Buffer<SearchTypes.QueryFilter>(0);
                for (f in topLevelFilters.vals()) {
                    var wasUsed = false;
                    switch (f) {
                        case (#expression(expr)) {
                            if (usedAttrNames.get(expr.attributeNames) != null) {
                                wasUsed := true;
                            };
                        };
                        case (_) {};
                    };
                    if (not wasUsed) {
                        remainingFilters.add(f);
                    };
                };
                let remainingFilter : SearchTypes.QueryFilter = #AND(Buffer.toArray(remainingFilters));

                return #IndexScan({
                    indexName = match.indexName;
                    scanBounds = scanBounds;
                    remainingFilter = remainingFilter;
                });
            };
        };
    };
};
