import InputTypes "types/input";
import OutputTypes "types/output";
import Create "modules/create";
import Read "modules/read";
import Update "modules/update";
import Delete "modules/delete";
import Search "modules/search";
import Database "types/database";

module {

    public func updateOperation({
        updateOpsInput : InputTypes.UpdateOpsInputType;
        alfangoDB : Database.AlfangoDB;
    }) : async OutputTypes.UpdateOpsOutputType {

        switch (updateOpsInput) {
            case (#CreateDatabaseInput(createDatabaseInput)) {
                return #CreateDatabaseOutput(Create.createDatabase({ createDatabaseInput; alfangoDB }));
            };
            case (#CreateTableInput(createTableInput)) {
                return #CreateTableOutput(Create.createTable({ createTableInput; alfangoDB }));
            };
            case (#AddAttributeInput(addAttributeInput)) {
                return #AddAttributeOutput(Update.addAttribute({ addAttributeInput; alfangoDB }));
            };
            case (#DropAttributeInput(dropAttributeInput)) {
                return #DropAttributeOutput(Update.dropAttribute({ dropAttributeInput; alfangoDB }));
            };
            case (#CreateItemInput(createItemInput)) {
                return #CreateItemOutput(await Create.createItem({ createItemInput; alfangoDB }));
            };
            case (#CreateIndexInput(createIndexInput)) {
                return #CreateIndexOutput(Update.createIndex({ createIndexInput; alfangoDB }));
            };
            case (#UpdateItemInput(updateItemInput)) {
                let updateResult = Update.updateItem({ updateItemInput; alfangoDB });
                switch (updateResult) {
                    case (#ok(res)) {
                        return #UpdateItemOutput(#ok({
                            id = updateItemInput.id;
                            item = res.item;
                        }));
                    };
                    case (#err(errs)) {
                        return #UpdateItemOutput(#err(errs));
                    };
                };
            };
            case (#DeleteDatabaseInput(deleteDatabaseInput)) {
                return #DeleteDatabaseOutput(Delete.deleteDatabase({ deleteDatabaseInput; alfangoDB }));
            };
            case (#DeleteTableInput(deleteTableInput)) {
                return #DeleteTableOutput(Delete.deleteTable({ deleteTableInput; alfangoDB }));
            };
            case (#DeleteItemInput(deleteItemInput)) {
                return #DeleteItemOutput(Delete.deleteItem({ deleteItemInput; alfangoDB }));
            };
        };
    };

    public func queryOperation({
        queryOpsInput : InputTypes.QueryOpsInputType;
        alfangoDB : Database.AlfangoDB;
    }) : async OutputTypes.QueryOpsOutputType {

        switch (queryOpsInput) {
            case (#GetTableMetadataInput(getTableMetadataInput)) {
                return #GetTableMetadataOutput(Read.getTableMetadata({ getTableMetadataInput; alfangoDB }));
            };
            case (#GetItemByIdInput(getItemByIdInput)) {
                return #GetItemByIdOutput(Read.getItemById({ getItemByIdInput; alfangoDB }));
            };
            case (#BatchGetItemByIdInput(batchGetItemByIdInput)) {
                return #BatchGetItemByIdOutput(Read.batchGetItemById({ batchGetItemByIdInput; alfangoDB }));
            };
            case (#GetItemCountInput(getItemCountInput)) {
                return #GetItemCountOutput(Read.getItemCount({ getItemCountInput; alfangoDB }));
            };
            case (#ScanInput(scanInput)) {
                return #ScanOutput(await Search.scan({ scanInput; alfangoDB }));
            };
            case (#ScanAndGetIdsInput(scanAndGetIdsInput)) {
                return #ScanAndGetIdsOutput(await Search.scanAndGetIds({ scanAndGetIdsInput; alfangoDB }));
            };
            case (#PaginatedScanInput(paginatedScanInput)) {
                return #PaginatedScanOutput(await Search.paginatedScan({ paginatedScanInput; alfangoDB }));
            };
            case (#GetDatabasesInput(_getDatabasesInput)) {
                return #GetDatabasesOutput(Read.getDatabases(alfangoDB));
            };
        };
    };
};
