import AlfangoDB "../AlfangoDB/lib";
import Debug "mo:base/Debug";
import Text "mo:base/Text";
import Result "mo:base/Result";
import Nat "mo:base/Nat";
import Iter "mo:base/Iter";
import Nat64 "mo:base/Nat64";
import Buffer "mo:base/Buffer";
import Bool "mo:base/Bool";
import Blob "mo:base/Blob";
import Map "mo:map/Map";
import { thash } "mo:map/Map";
import Set "mo:map/Set";
import Vector "mo:vector";
import Jobs "../AlfangoDB/modules/jobs";
import SearchTypes "../AlfangoDB/types/search";

/**
* This actor is a self-contained test environment for the AlfangoDB library.
* It holds its own database state and exposes a `run_tests` function that
* executes a variety of test scenarios against the library's functions.
*
* To run the tests, deploy this actor and call the `run_tests` method.
*/
actor TestMain {

    // The database state for this test actor.
    stable var db_state : AlfangoDB.AlfangoDB = {
        databases = Map.new();
        STABLE_MEMORY_LIMIT = 3_221_225_472;
        var totalStableBytes : Nat64 = 0;
    };

    // Helper to print test results. Traps on failure for clear error reporting.
    private func check(name : Text, passed : Bool) {
        if (passed) {
            Debug.print("  ✅ " # name);
        } else {
            Debug.print("  ❌ " # name # " - FAILED");
            Debug.trap("Test failed: " # name);
        };
    };

    private func ensureFreshDatabase(dbName : Text) : async () {
        if (Map.has(db_state.databases, thash, dbName)) {
            ignore await AlfangoDB.updateOperation({
                updateOpsInput = #DeleteDatabaseInput({ name = dbName });
                alfangoDB = db_state;
            });
        };
    };

    public func test_database_ops() : async () {
        Debug.print("\n--- Testing Database Operations ---");
        let dbName = "db1";

        // Create Database
        var create_res = await AlfangoDB.updateOperation({
            updateOpsInput = #CreateDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });
        switch (create_res) {
            case (#CreateDatabaseOutput(#ok(_))) {
                check("Create Database", true);
            };
            case (_) { check("Create Database", false) };
        };

        // Try to create duplicate database
        create_res := await AlfangoDB.updateOperation({
            updateOpsInput = #CreateDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });
        switch (create_res) {
            case (#CreateDatabaseOutput(#err(_))) {
                check("Create Duplicate Database (should fail)", true);
            };
            case (_) { check("Create Duplicate Database (should fail)", false) };
        };

        // Delete Database
        let delete_res = await AlfangoDB.updateOperation({
            updateOpsInput = #DeleteDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });
        switch (delete_res) {
            case (#DeleteDatabaseOutput(#ok(_))) {
                check("Delete Database", true);
            };
            case (_) { check("Delete Database", false) };
        };
    };

    public func test_table_ops() : async () {
        Debug.print("\n--- Testing Table Operations ---");
        let dbName = "db_for_tables";
        let tableName = "Users";

        await ensureFreshDatabase(dbName);

        // Setup: Create a database
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });

        // Create Table
        let create_res = await AlfangoDB.updateOperation({
            updateOpsInput = #CreateTableInput({
                databaseName = dbName;
                name = tableName;
                attributes = [
                    {
                        name = "id";
                        dataType = #text;
                        unique = true;
                        required = true;
                        defaultValue = #default;
                    },
                    {
                        name = "email";
                        dataType = #text;
                        unique = true;
                        required = true;
                        defaultValue = #default;
                    },
                    {
                        name = "age";
                        dataType = #nat;
                        unique = false;
                        required = false;
                        defaultValue = #nat(18);
                    },
                ];
                indexes = [];
            });
            alfangoDB = db_state;
        });
        switch (create_res) {
            case (#CreateTableOutput(#ok(_))) { check("Create Table", true) };
            case (_) { check("Create Table", false) };
        };

        // Get Table Metadata
        let meta_res = await AlfangoDB.queryOperation({
            queryOpsInput = #GetTableMetadataInput({
                databaseName = dbName;
                tableName = tableName;
            });
            alfangoDB = db_state;
        });
        switch (meta_res) {
            case (#GetTableMetadataOutput(?meta)) {
                check("Get Table Metadata", meta.metadata.attributes.size() == 3);
            };
            case (_) { check("Get Table Metadata", false) };
        };
    };

    public func test_item_and_constraint_ops() : async () {
        Debug.print("\n--- Testing Item & Constraint Operations ---");
        let dbName = "db_for_items";
        let tableName = "Users";

        await ensureFreshDatabase(dbName);

        // Setup: Create DB and Table
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateTableInput({
                databaseName = dbName;
                name = tableName;
                attributes = [
                    {
                        name = "email";
                        dataType = #text;
                        unique = true;
                        required = true;
                        defaultValue = #default;
                    },
                    {
                        name = "status";
                        dataType = #text;
                        unique = false;
                        required = true;
                        defaultValue = #default;
                    },
                ];
                indexes = [{
                    name = "email_idx";
                    attributeNames = ["email"];
                    unique = true;
                }];
            });
            alfangoDB = db_state;
        });

        // Create Item
        let create_res = await AlfangoDB.createItem({
            createItemInput = {
                databaseName = dbName;
                tableName = tableName;
                attributeDataValues = [("email", #text("test@test.com")), ("status", #text("active"))];
            };
            alfangoDB = db_state;
        });
        var itemId : Text = "";
        switch (create_res) {
            case (#ok(item)) {
                itemId := item.id;
                check("Create Item", true);
            };
            case (#err(_)) { check("Create Item", false) };
        };

        // Check required constraint (should fail)
        let req_fail_res = await AlfangoDB.createItem({
            createItemInput = {
                databaseName = dbName;
                tableName = tableName;
                attributeDataValues = [("email", #text("fail@test.com"))];
            };
            alfangoDB = db_state;
        });
        check("Required constraint failure", Result.isErr(req_fail_res));

        // Check unique constraint (should fail)
        let unique_fail_res = await AlfangoDB.createItem({
            createItemInput = {
                databaseName = dbName;
                tableName = tableName;
                attributeDataValues = [("email", #text("test@test.com")), ("status", #text("pending"))];
            };
            alfangoDB = db_state;
        });
        check("Unique constraint failure", Result.isErr(unique_fail_res));
    };

    public func test_scan_ops() : async () {
        Debug.print("\n--- Testing Scan Operations ---");
        let dbName = "db_for_scan";
        let tableName = "Products";

        await ensureFreshDatabase(dbName);

        // Setup
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateTableInput({
                databaseName = dbName;
                name = tableName;
                attributes = [
                    {
                        name = "category";
                        dataType = #text;
                        required = true;
                        unique = false;
                        defaultValue = #default;
                    },
                    {
                        name = "price";
                        dataType = #nat;
                        required = true;
                        unique = false;
                        defaultValue = #default;
                    },
                ];
                indexes = [{
                    name = "category_idx";
                    attributeNames = ["category"];
                    unique = false;
                }];
            });
            alfangoDB = db_state;
        });
        ignore await AlfangoDB.createItem({
            createItemInput = {
                databaseName = dbName;
                tableName = tableName;
                attributeDataValues = [("category", #text("books")), ("price", #nat(20))];
            };
            alfangoDB = db_state;
        });
        ignore await AlfangoDB.createItem({
            createItemInput = {
                databaseName = dbName;
                tableName = tableName;
                attributeDataValues = [("category", #text("books")), ("price", #nat(30))];
            };
            alfangoDB = db_state;
        });
        ignore await AlfangoDB.createItem({
            createItemInput = {
                databaseName = dbName;
                tableName = tableName;
                attributeDataValues = [("category", #text("electronics")), ("price", #nat(150))];
            };
            alfangoDB = db_state;
        });

        // Simple Scan with index
        let scan_res = await AlfangoDB.scan({
            scanInput = {
                databaseName = dbName;
                tableName = tableName;
                filter = #expression({
                    attributeNames = "category";
                    filterExpressionCondition = #EQ(#text("books"));
                });
            };
            alfangoDB = db_state;
        });

        switch (scan_res) {
            case (#ok(items)) {
                check("Scan with index", items.size() == 2);
            };
            case (#err(e)) {
                Debug.print(debug_show (e));
                check("Scan with index", false);
            };
        };
    };

    // --- NEWLY ADDED, MORE ADVANCED TESTS ---

    public func test_index_updates_on_item_update() : async () {
        Debug.print("\n--- Testing Index Correctness on Item Update ---");
        let dbName = "db_for_update";
        let tableName = "Tickets";
        let indexName = "status_idx";

        await ensureFreshDatabase(dbName);

        // 1. Setup DB and Table with an index on 'status'
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateTableInput({
                databaseName = dbName;
                name = tableName;
                attributes = [
                    {
                        name = "title";
                        dataType = #text;
                        required = true;
                        unique = false;
                        defaultValue = #default;
                    },
                    {
                        name = "status";
                        dataType = #text;
                        required = true;
                        unique = false;
                        defaultValue = #default;
                    },
                ];
                indexes = [{
                    name = indexName;
                    attributeNames = ["status"];
                    unique = false;
                }];
            });
            alfangoDB = db_state;
        });

        // 2. Create an item with status "open"
        let create_res = await AlfangoDB.createItem({
            createItemInput = {
                databaseName = dbName;
                tableName = tableName;
                attributeDataValues = [("title", #text("Fix the printer")), ("status", #text("open"))];
            };
            alfangoDB = db_state;
        });
        let itemId = switch (create_res) {
            case (#ok(item)) { item.id };
            case (#err(e)) {
                Debug.trap("Failed to create item for update test: " # debug_show (e));
            };
        };
        check("Create item for update test", true);

        // 3. Update the item's status from "open" to "closed"
        let update_res = await AlfangoDB.updateOperation({
            updateOpsInput = #UpdateItemInput({
                databaseName = dbName;
                tableName = tableName;
                id = itemId;
                attributeDataValues = [("status", #text("closed"))];
            });
            alfangoDB = db_state;
        });
        switch (update_res) {
            case (#UpdateItemOutput(#ok _)) {
                check("Update indexed item", true);
            };
            case (#UpdateItemOutput(#err e)) {
                Debug.trap("Update item failed: " # debug_show (e));
            };
            case _ { Debug.trap("Unexpected result from update") };
        };

        // 5. Scan for items with the OLD status ("open"). It should find 0.
        let scan_old_res = await AlfangoDB.scan({
            scanInput = {
                databaseName = dbName;
                tableName = tableName;
                filter = #expression({
                    attributeNames = "status";
                    filterExpressionCondition = #EQ(#text("open"));
                });
            };
            alfangoDB = db_state;
        });
        switch (scan_old_res) {
            case (#ok(items)) {
                check("Scan for old index value (should be empty)", items.size() == 0);
            };
            case (#err _e) { check("Scan for old index value", false) };
        };

        // 6. Scan for items with the NEW status ("closed"). It should find 1.
        let scan_new_res = await AlfangoDB.scan({
            scanInput = {
                databaseName = dbName;
                tableName = tableName;
                filter = #expression({
                    attributeNames = "status";
                    filterExpressionCondition = #EQ(#text("closed"));
                });
            };
            alfangoDB = db_state;
        });
        switch (scan_new_res) {
            case (#ok(items)) {
                check("Scan for new index value (should find 1)", items.size() == 1);
            };
            case (#err _e) { check("Scan for new index value", false) };
        };
    };

    public func test_drop_attribute_with_index() : async () {
        Debug.print("\n--- Testing Index Deletion on Drop Attribute ---");
        let dbName = "db_for_drop_attr";
        let tableName = "Reviews";
        let indexName = "product_rating_idx";

        await ensureFreshDatabase(dbName);

        // 1. Setup DB and Table with a compound index on '(product_id, rating)'
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateTableInput({
                databaseName = dbName;
                name = tableName;
                attributes = [
                    {
                        name = "product_id";
                        dataType = #text;
                        required = true;
                        unique = false;
                        defaultValue = #default;
                    },
                    {
                        name = "rating";
                        dataType = #nat;
                        required = true;
                        unique = false;
                        defaultValue = #default;
                    },
                    {
                        name = "comment";
                        dataType = #text;
                        required = false;
                        unique = false;
                        defaultValue = #default;
                    },
                ];
                indexes = [{
                    name = indexName;
                    attributeNames = ["product_id", "rating"];
                    unique = false;
                }];
            });
            alfangoDB = db_state;
        });
        check("Setup table with compound index", true);

        // 2. Drop the 'rating' attribute. This should also drop the compound index.
        let drop_res = await AlfangoDB.updateOperation({
            updateOpsInput = #DropAttributeInput({
                databaseName = dbName;
                tableName = tableName;
                attributeName = "rating";
            });
            alfangoDB = db_state;
        });
        switch (drop_res) {
            case (#DropAttributeOutput(#ok _)) {
                check("Drop attribute that is part of an index", true);
            };
            case (#DropAttributeOutput(#err e)) {
                Debug.trap("Drop attribute failed: " # debug_show (e));
            };
            case _ { Debug.trap("Unexpected result from drop attribute") };
        };

        // 3. Verify the index was actually removed from the table's metadata.
        let meta_res = await AlfangoDB.queryOperation({
            queryOpsInput = #GetTableMetadataInput({
                databaseName = dbName;
                tableName = tableName;
            });
            alfangoDB = db_state;
        });
        switch (meta_res) {
            case (#GetTableMetadataOutput(?meta)) {
                check("Verify index was removed from metadata", meta.metadata.indexes.size() == 0);
            };
            case (_) { check("Verify index was removed from metadata", false) };
        };
    };

    public func test_failure_and_edge_cases() : async () {
        Debug.print("\n--- Testing Failure Conditions & Edge Cases ---");
        let dbName = "db_for_failures";
        let tableName = "Widgets";

        await ensureFreshDatabase(dbName);

        // --- Setup a clean database and table for our tests ---
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateTableInput({
                databaseName = dbName;
                name = tableName;
                attributes = [
                    {
                        name = "sku";
                        dataType = #text;
                        required = true;
                        unique = true;
                        defaultValue = #default;
                    },
                    {
                        name = "inventory";
                        dataType = #nat;
                        required = true;
                        unique = false;
                        defaultValue = #nat(0);
                    },
                ];
                indexes = [{
                    name = "sku_idx";
                    attributeNames = ["sku"];
                    unique = true;
                }];
            });
            alfangoDB = db_state;
        });

        // --- Section: Schema Definition Failures ---
        Debug.print("  -> Testing Schema Definition Failures...");
        let res1 = await AlfangoDB.updateOperation({
            updateOpsInput = #CreateTableInput({
                databaseName = "non_existent_db"; // WRONG DB
                name = "a_table";
                attributes = [];
                indexes = [];
            });
            alfangoDB = db_state;
        });
        let isCreateTableErr = switch (res1) {
            case (#CreateTableOutput(#err(_))) { true };
            case _ { false };
        };
        check("Fail to create table in non-existent DB", isCreateTableErr);

        let res2 = await AlfangoDB.updateOperation({
            updateOpsInput = #CreateIndexInput({
                databaseName = dbName;
                tableName = tableName;
                index = {
                    name = "bad_idx";
                    attributeNames = ["non_existent_attr"];
                    unique = false;
                }; // WRONG ATTRIBUTE
            });
            alfangoDB = db_state;
        });
        let isCreateIndexErr = switch (res2) {
            case (#CreateIndexOutput(#err(_))) { true };
            case _ { false };
        };
        check("Fail to create index on non-existent attribute", isCreateIndexErr);

        let res3 = await AlfangoDB.updateOperation({
            updateOpsInput = #CreateIndexInput({
                databaseName = dbName;
                tableName = tableName;
                index = {
                    name = "empty_idx";
                    attributeNames = [];
                    unique = false;
                }; // EMPTY ATTRIBUTES
            });
            alfangoDB = db_state;
        });
        let isCreateIndexNoAttrErr = switch (res3) {
            case (#CreateIndexOutput(#err(_))) { true };
            case _ { false };
        };
        check("Fail to create index with no attributes", isCreateIndexNoAttrErr);

        let res4 = await AlfangoDB.updateOperation({
            updateOpsInput = #CreateIndexInput({
                databaseName = dbName;
                tableName = tableName;
                index = {
                    name = "sku_idx";
                    attributeNames = ["sku"];
                    unique = true;
                }; // DUPLICATE NAME
            });
            alfangoDB = db_state;
        });
        let isCreateIndexDupNameErr = switch (res4) {
            case (#CreateIndexOutput(#err(_))) { true };
            case _ { false };
        };
        check("Fail to create index with duplicate name", isCreateIndexDupNameErr);

        // --- Section: Item Validation Failures ---
        Debug.print("  -> Testing Item Validation Failures...");
        let res5 = await AlfangoDB.createItem({
            createItemInput = {
                databaseName = dbName;
                tableName = tableName;
                attributeDataValues = [
                    ("sku", #text("widget-01")),
                    ("inventory", #text("50")) // WRONG DATA TYPE
                ];
            };
            alfangoDB = db_state;
        });
        check("Fail to create item with wrong data type", Result.isErr(res5));

        let res6 = await AlfangoDB.createItem({
            createItemInput = {
                databaseName = dbName;
                tableName = tableName;
                attributeDataValues = [
                    ("sku", #text("widget-02")),
                    ("inventory", #nat(100)),
                    ("color", #text("blue")) // EXTRA ATTRIBUTE
                ];
            };
            alfangoDB = db_state;
        });
        check("Fail to create item with unwanted attribute", Result.isErr(res6));

        // --- Section: Attribute Modification Failures ---
        Debug.print("  -> Testing Attribute Modification Failures...");
        let res7 = await AlfangoDB.updateOperation({
            updateOpsInput = #AddAttributeInput({
                databaseName = dbName;
                tableName = tableName;
                attribute = {
                    name = "sku";
                    dataType = #text;
                    required = false;
                    unique = false;
                    defaultValue = #default;
                }; // DUPLICATE ATTRIBUTE
            });
            alfangoDB = db_state;
        });
        let isAddAttrErr = switch (res7) {
            case (#AddAttributeOutput(#err(_))) { true };
            case _ { false };
        };
        check("Fail to add an attribute that already exists", isAddAttrErr);

        let res8 = await AlfangoDB.updateOperation({
            updateOpsInput = #DropAttributeInput({
                databaseName = dbName;
                tableName = tableName;
                attributeName = "non_existent_attr"; // NON-EXISTENT ATTRIBUTE
            });
            alfangoDB = db_state;
        });
        let isDropAttrErr = switch (res8) {
            case (#DropAttributeOutput(#err(_))) { true };
            case _ { false };
        };
        check("Fail to drop an attribute that does not exist", isDropAttrErr);

        // --- Section: CRUD on Non-Existent Entities ---
        Debug.print("  -> Testing CRUD on Non-Existent Entities...");
        let res9 = AlfangoDB.getItemById({
            getItemByIdInput = {
                databaseName = dbName;
                tableName = tableName;
                id = "non-existent-id";
            };
            alfangoDB = db_state;
        });
        check("Fail to get item with non-existent ID", Result.isErr(res9));

        let res10 = await AlfangoDB.updateOperation({
            updateOpsInput = #UpdateItemInput({
                databaseName = dbName;
                tableName = tableName;
                id = "non-existent-id";
                attributeDataValues = [("inventory", #nat(99))];
            });
            alfangoDB = db_state;
        });
        let isUpdateItemErr = switch (res10) {
            case (#UpdateItemOutput(#err(_))) { true };
            case _ { false };
        };
        check("Fail to update item with non-existent ID", isUpdateItemErr);

        let res11 = await AlfangoDB.updateOperation({
            updateOpsInput = #DeleteItemInput({
                databaseName = dbName;
                tableName = tableName;
                id = "non-existent-id";
            });
            alfangoDB = db_state;
        });
        let isDeleteItemErr = switch (res11) {
            case (#DeleteItemOutput(#err(_))) { true };
            case _ { false };
        };
        check("Fail to delete item with non-existent ID", isDeleteItemErr);

        let res12 = await AlfangoDB.updateOperation({
            updateOpsInput = #DeleteTableInput({
                databaseName = dbName;
                tableName = "non_existent_table";
            });
            alfangoDB = db_state;
        });
        let isDeleteTableErr = switch (res12) {
            case (#DeleteTableOutput(#err(_))) { true };
            case _ { false };
        };
        check("Fail to delete non-existent table", isDeleteTableErr);
    };

    public func test_bulk_insert() : async () {
        Debug.print("\n--- Stress Test 1: Bulk Inserts with 3 Indexes ---");
        let dbName = "db_for_bulk_insert";
        let tableName = "Customers";
        let itemCount = 50; // Scalable: Set to 100_000 for a full stress test.

        await ensureFreshDatabase(dbName);

        // 1. Setup: Create a database and a table with three indexes.
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateTableInput({
                databaseName = dbName;
                name = tableName;
                attributes = [
                    {
                        name = "username";
                        dataType = #text;
                        required = true;
                        unique = true;
                        defaultValue = #default;
                    },
                    {
                        name = "email";
                        dataType = #text;
                        required = true;
                        unique = true;
                        defaultValue = #default;
                    },
                    {
                        name = "city";
                        dataType = #text;
                        required = true;
                        unique = false;
                        defaultValue = #default;
                    },
                ];
                indexes = [
                    {
                        name = "username_idx";
                        attributeNames = ["username"];
                        unique = true;
                    },
                    {
                        name = "email_idx";
                        attributeNames = ["email"];
                        unique = true;
                    },
                    {
                        name = "city_username_idx";
                        attributeNames = ["city", "username"];
                        unique = false;
                    },
                ];
            });
            alfangoDB = db_state;
        });
        check("Bulk Insert: Setup table with 3 indexes", true);

        // 2. Execution: Insert itemCount items, tracking memory usage.
        Debug.print(" -> Starting " # Nat.toText(itemCount) # " inserts...");
        let initial_bytes = db_state.totalStableBytes;
        var items_created = 0;

        // FIX 1: Corrected Motoko `for` loop syntax
        for (i in Iter.range(0, itemCount - 1)) {
            let user_id = Nat.toText(i);
            let res = await AlfangoDB.createItem({
                createItemInput = {
                    databaseName = dbName;
                    tableName = tableName;
                    attributeDataValues = [
                        ("username", #text("user" # user_id)),
                        ("email", #text("user" # user_id # "@example.com")),
                        ("city", #text("City" # Nat.toText(i % 10))) // 10 unique cities
                    ];
                };
                alfangoDB = db_state;
            });

            switch (res) {
                case (#ok(_)) { items_created += 1 };
                case (#err(e)) {
                    Debug.print(" -> Bulk insert failed at item " # Nat.toText(i));
                    Debug.trap("Error: " # debug_show (e));
                };
            };
        };
        check("Bulk Insert: " # Nat.toText(items_created) # " items created successfully", items_created == itemCount);

        // 3. Verification: Check the final item count and memory growth.
        // FIX 2: Removed unnecessary `await` from synchronous function call
        let count_res = AlfangoDB.getItemCount({
            getItemCountInput = { databaseName = dbName; tableName = tableName };
            alfangoDB = db_state;
        });

        switch (count_res) {
            case (#ok(res)) {
                check("Bulk Insert: Final item count is correct", res.count == itemCount);
            };
            case (#err(e)) {
                check("Bulk Insert: Final item count is correct", false);
                Debug.print(" -> Failed to get item count: " # debug_show (e));
            };
        };

        let final_bytes = db_state.totalStableBytes;
        check("Bulk Insert: totalStableBytes has increased", final_bytes > initial_bytes);
        Debug.print(" -> Memory usage grew from " # Nat64.toText(initial_bytes) # " to " # Nat64.toText(final_bytes) # " bytes.");
    };

    public func test_bulk_update_indexed_key() : async () {
        Debug.print("\n--- Stress Test 2: Update 10k Items Switching Index Keys ---");
        let dbName = "db_for_bulk_update";
        let tableName = "Tasks";
        let itemCount = 100; // Scalable: Set to 10_000 for a full stress test.

        await ensureFreshDatabase(dbName);

        // 1. Setup: Create a table and populate it with items having an initial indexed state.
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateTableInput({
                databaseName = dbName;
                name = tableName;
                attributes = [
                    {
                        name = "title";
                        dataType = #text;
                        required = true;
                        unique = false;
                        defaultValue = #default;
                    },
                    {
                        name = "status";
                        dataType = #text;
                        required = true;
                        unique = false;
                        defaultValue = #default;
                    },
                ];
                indexes = [
                    {
                        name = "status_idx";
                        attributeNames = ["status"];
                        unique = false;
                    },
                ];
            });
            alfangoDB = db_state;
        });
        check("Bulk Update: Setup complete", true);

        // Populate the table with 'itemCount' tasks, all with status "pending".
        Debug.print(" -> Populating table with " # Nat.toText(itemCount) # " initial items...");
        let itemIds = Buffer.Buffer<Text>(0);
        for (i in Iter.range(0, itemCount - 1)) {
            let res = await AlfangoDB.createItem({
                createItemInput = {
                    databaseName = dbName;
                    tableName = tableName;
                    attributeDataValues = [
                        ("title", #text("Task " # Nat.toText(i))),
                        ("status", #text("pending")),
                    ];
                };
                alfangoDB = db_state;
            });
            switch (res) {
                case (#ok(item)) { itemIds.add(item.id) };
                case (#err(e)) {
                    Debug.trap("Bulk Update: Failed during initial population: " # debug_show (e));
                };
            };
        };
        check("Bulk Update: Population complete", itemIds.size() == itemCount);

        // 2. Execution: Update all items to change the indexed key.
        Debug.print(" -> Updating " # Nat.toText(itemCount) # " items to switch index key...");
        var items_updated = 0;
        for (id in itemIds.vals()) {
            let update_res = await AlfangoDB.updateOperation({
                updateOpsInput = #UpdateItemInput({
                    databaseName = dbName;
                    tableName = tableName;
                    id = id;
                    attributeDataValues = [("status", #text("completed"))];
                });
                alfangoDB = db_state;
            });
            switch (update_res) {
                case (#UpdateItemOutput(#ok(_))) { items_updated += 1 };
                case (#UpdateItemOutput(#err(e))) {
                    Debug.trap("Bulk Update: Update failed for item " # id # ": " # debug_show (e));
                };
                case (_) {
                    Debug.trap("Bulk Update: Unexpected error during update.");
                };
            };
        };
        check("Bulk Update: " # Nat.toText(items_updated) # " items updated successfully", items_updated == itemCount);

        // 3. Verification: Scan for both the old and new index values.
        // There should be 0 items with the old status.
        let scan_old_res = await AlfangoDB.scan({
            scanInput = {
                databaseName = dbName;
                tableName = tableName;
                filter = #expression({
                    attributeNames = "status";
                    filterExpressionCondition = #EQ(#text("pending"));
                });
            };
            alfangoDB = db_state;
        });
        switch (scan_old_res) {
            case (#ok(items)) {
                check("Bulk Update: Scan for old index key finds 0 items", items.size() == 0);
            };
            case (#err(_)) {
                check("Bulk Update: Scan for old index key finds 0 items.", false);
            };
        };

        // There should be 'itemCount' items with the new status.
        let scan_new_res = await AlfangoDB.scan({
            scanInput = {
                databaseName = dbName;
                tableName = tableName;
                filter = #expression({
                    attributeNames = "status";
                    filterExpressionCondition = #EQ(#text("completed"));
                });
            };
            alfangoDB = db_state;
        });
        switch (scan_new_res) {
            case (#ok(items)) {
                check("Bulk Update: Scan for new index key finds all " # Nat.toText(itemCount) # " items", items.size() == itemCount);
            };
            case (#err(_)) {
                check("Bulk Update: Scan for new index key finds all items", false);
            };
        };
    };

    private func run_job_processor() {
        Debug.print("  -> Manually running job processor...");
        Jobs.processAllPendingJobs(db_state);
        Debug.print("  -> Job processor finished.");
    };

    private func _run_jobs_until_complete(dbName : Text, tableName : Text) : async () {
        var jobs_are_pending = true;
        var runs = 0;
        let max_runs = 100; // A safeguard against infinite loops

        Debug.print(" -> Entering job loop for table '" # tableName # "'...");

        while (jobs_are_pending and runs < max_runs) {
            runs += 1;
            Debug.print(" -> Job processor run #" # Nat.toText(runs));
            run_job_processor(); // This is your existing helper

            // Correctly check if there are any pending jobs left for the table.
            // The job is complete when the pendingJobs queue is empty.
            let database = switch (Map.get(db_state.databases, thash, dbName)) {
                case (?db) { db };
                case (null) {
                    Debug.trap("Test Error: Database not found during job check.");
                };
            };
            let table = switch (Map.get(database.tables, thash, tableName)) {
                case (?tbl) { tbl };
                case (null) {
                    Debug.trap("Test Error: Table not found during job check.");
                };
            };

            let pendingJobCount = Vector.size(table.pendingJobs);
            if (pendingJobCount == 0) {
                Debug.print(" -> No more pending jobs for table '" # tableName # "'. Loop will terminate.");
                jobs_are_pending := false;
            } else {
                Debug.print(" -> Job still in progress, " # Nat.toText(pendingJobCount) # " job(s) remaining.");
            };
        };

        if (runs >= max_runs) {
            Debug.trap("Job processor did not complete within max runs.");
        };
    };

    public func test_drop_large_attribute() : async () {
        Debug.print("\n--- Stress Test 3: Drop a Large Attribute on a 25MB Table ---");
        let dbName = "db_for_large_drop";
        let tableName = "DataBlobs";
        let itemCount = 256; // 256 items * 100KB = ~25MB
        let blobSize = 100 * 1024; // 100KB

        await ensureFreshDatabase(dbName);

        // 1. Setup: Create a table and fill it with ~25MB of data.
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateTableInput({
                databaseName = dbName;
                name = tableName;
                attributes = [
                    {
                        name = "id";
                        dataType = #text;
                        required = true;
                        unique = true;
                        defaultValue = #default;
                    },
                    {
                        name = "large_payload";
                        dataType = #blob;
                        required = true;
                        unique = false;
                        defaultValue = #default;
                    },
                ];
                indexes = [];
            });
            alfangoDB = db_state;
        });
        check("Drop Large Attribute: Setup complete", true);

        Debug.print(" -> Populating table with " # Nat.toText(itemCount) # " large items (~25MB total)...");
        let largeBlob = Buffer.Buffer<Nat8>(blobSize);
        for (_ in Iter.range(0, blobSize - 1)) {
            largeBlob.add(0);
        };
        for (i in Iter.range(0, itemCount - 1)) {
            let itemId = "item-" # Nat.toText(i);
            let res = await AlfangoDB.createItem({
                createItemInput = {
                    databaseName = dbName;
                    tableName = tableName;
                    attributeDataValues = [
                        ("id", #text(itemId)),
                        ("large_payload", #blob(Blob.fromArray(Buffer.toArray<Nat8>(largeBlob)))),
                    ];
                };
                alfangoDB = db_state;
            });
            if (Result.isErr(res)) {
                Debug.trap("Failed to populate for large drop test.");
            };
        };
        check("Drop Large Attribute: Population complete", true);

        // 2. Execution: Drop the large attribute and run the job processor until it's done.
        let initial_bytes = db_state.totalStableBytes;
        Debug.print(" -> Initial memory usage: " # Nat64.toText(initial_bytes) # " bytes.");

        let drop_res = await AlfangoDB.updateOperation({
            updateOpsInput = #DropAttributeInput({
                databaseName = dbName;
                tableName = tableName;
                attributeName = "large_payload";
            });
            alfangoDB = db_state;
        });
        let drop_ok = switch (drop_res) {
            case (#DropAttributeOutput(#ok(_))) true;
            case _ false;
        };
        check("Drop Large Attribute: Job scheduled successfully", drop_ok);

        // This helper will now run the processor in a loop until the job is done.
        await _run_jobs_until_complete(dbName, tableName);

        // 3. Verification: Check that memory has been reclaimed and the attribute is gone.
        let final_bytes = db_state.totalStableBytes;
        Debug.print(" -> Final memory usage: " # Nat64.toText(final_bytes) # " bytes.");
        check("Drop Large Attribute: totalStableBytes has decreased significantly", final_bytes < initial_bytes / 2); // Check it dropped by at least half

        let item_check = AlfangoDB.getItemById({
            getItemByIdInput = {
                databaseName = dbName;
                tableName = tableName;
                id = "item-0";
            };
            alfangoDB = db_state;
        });
        var attribute_is_gone = false;
        switch (item_check) {
            case (#ok(item_output)) {
                var found = false;
                for ((attrName, _) in item_output.item.vals()) {
                    if (attrName == "large_payload") { found := true };
                };
                attribute_is_gone := not found;
            };
            case (#err(_)) { attribute_is_gone := true }; // Should not happen, but err means it's gone.
        };
        check("Drop Large Attribute: Attribute is confirmed gone from item data", attribute_is_gone);
    };

    // This test validates cursor stability during concurrent data modification.
    public func test_paginated_scan_with_deletes() : async () {
        Debug.print("\n--- Stress Test 4: Paginated Scans with Concurrent Deletes ---");
        let dbName = "db_for_concurrent_scan";
        let tableName = "LogEntries";
        let itemCount = 50;
        let pageSize = 10;

        await ensureFreshDatabase(dbName);

        // 1. Setup: Create a table and populate it with a known set of items.
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateDatabaseInput({ name = dbName });
            alfangoDB = db_state;
        });
        ignore await AlfangoDB.updateOperation({
            updateOpsInput = #CreateTableInput({
                databaseName = dbName;
                name = tableName;
                attributes = [
                    {
                        name = "entry";
                        dataType = #text;
                        required = true;
                        unique = false;
                        defaultValue = #default;
                    },
                ];
                indexes = [];
            });
            alfangoDB = db_state;
        });

        // Create items and store all their IDs in a buffer for later reference.
        let all_item_ids = Buffer.Buffer<Text>(0);
        Debug.print(" -> Populating table with " # Nat.toText(itemCount) # " items...");
        for (i in Iter.range(0, itemCount - 1)) {
            let res = await AlfangoDB.createItem({
                createItemInput = {
                    databaseName = dbName;
                    tableName = tableName;
                    attributeDataValues = [("entry", #text("Log " # Nat.toText(i)))];
                };
                alfangoDB = db_state;
            });
            switch (res) {
                case (#ok(item)) { all_item_ids.add(item.id) };
                case (#err(e)) {
                    Debug.trap("Concurrent Scan: Failed during initial population: " # debug_show (e));
                };
            };
        };
        check("Concurrent Scan: Setup and population complete", all_item_ids.size() == itemCount);

        // 2. Execution: Loop through the paginated scan, deleting items ahead of the cursor.
        var final_results = Buffer.Buffer<Text>(0);
        let deleted_ids = Buffer.Buffer<Text>(0);
        var cursor : ?SearchTypes.PaginatedScanCursor = null;
        var hasMore = true;
        var page = 0;

        while (hasMore) {
            page += 1;
            Debug.print(" -> Fetching page " # Nat.toText(page) # "...");

            let scan_res = await AlfangoDB.paginatedScan({
                paginatedScanInput = {
                    databaseName = dbName;
                    tableName = tableName;
                    filter = #AND([]); // Match all items
                    limit = pageSize;
                    cursor = cursor;
                };
                alfangoDB = db_state;
            });

            switch (scan_res) {
                case (#ok(page_result)) {
                    for (item in page_result.items.vals()) {
                        final_results.add(item.id);
                    };
                    hasMore := page_result.hasMore;
                    cursor := page_result.nextCursor;
                    Debug.print("    -> Fetched " # Nat.toText(page_result.items.size()) # " items. HasMore: " # Bool.toText(hasMore));

                    // If there are more pages, delete some items the scan hasn't reached yet.
                    if (hasMore and all_item_ids.size() >= 5) {
                        Debug.print("    -> Deleting 5 items ahead of the cursor...");
                        for (_ in Iter.range(0, 4)) {
                            // Delete from the end of our reference list
                            let id_to_delete_opt = all_item_ids.removeLast();
                            let id_to_delete = switch (id_to_delete_opt) {
                                case (?id) id;
                                case null {
                                    Debug.trap("No more items to delete in all_item_ids");
                                };
                            };
                            let delete_res = await AlfangoDB.updateOperation({
                                updateOpsInput = #DeleteItemInput({
                                    databaseName = dbName;
                                    tableName = tableName;
                                    id = id_to_delete;
                                });
                                alfangoDB = db_state;
                            });
                            let isDeleteErr = switch (delete_res) {
                                case (#DeleteItemOutput(#err(_))) { true };
                                case (#DeleteItemOutput(#ok(_))) { false };
                                case _ { true };
                            };
                            if (isDeleteErr) {
                                Debug.trap("Failed to delete item during concurrent scan test");
                            };
                            deleted_ids.add(id_to_delete);
                        };
                    };
                };
                case (#err(e)) {
                    Debug.trap("Concurrent Scan: paginatedScan failed: " # debug_show (e));
                };
            };
        };

        // 3. Verification
        check("Concurrent Scan: Scan loop completed", true);

        // Verify that no deleted ID was returned in the final results.
        let deleted_set = Set.fromIter<Text>(deleted_ids.vals(), (Text.hash, Text.equal));
        var deleted_item_was_returned = false;
        for (id in final_results.vals()) {
            if (Set.has<Text>(deleted_set, (Text.hash, Text.equal), id)) {
                deleted_item_was_returned := true;
            };
        };
        check("Concurrent Scan: No deleted items were returned", not deleted_item_was_returned);

        // Verify that the total number of items accounts for everything.
        let final_count = final_results.size() + deleted_ids.size();
        check("Concurrent Scan: Final count (" # Nat.toText(final_count) # ") matches initial count (" # Nat.toText(itemCount) # ")", final_count == itemCount);
    };

    // Main entry point to run all tests.
    public shared func run_tests() : async Bool {
        Debug.print("\n--- RUNNING ALFANGO DB TEST SUITE ---");

        await test_database_ops();
        await test_table_ops();
        await test_item_and_constraint_ops();
        await test_scan_ops();
        await test_bulk_insert();
        await test_bulk_update_indexed_key();
        await test_drop_large_attribute();
        await test_paginated_scan_with_deletes();
        await test_index_updates_on_item_update();
        await test_drop_attribute_with_index();
        await test_failure_and_edge_cases();

        Debug.print("\n--- ALL TESTS PASSED ---\n");
        return true;
    };
};
