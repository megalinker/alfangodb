import Datatypes "datatype";
import Database "database";
import Result "mo:base/Result";
import SearchTypes "search";

module {

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public type CreateDatabaseOutputType = Result.Result<{}, [Text]>;

    public type CreateTableOutputType = Result.Result<{}, [Text]>;

    public type CreateItemOutputType = Result.Result<{ id : Text; item : [(Text, Datatypes.AttributeDataValue)] }, [Text]>;

    public type CreateIndexOutputType = Result.Result<{ databaseName : Text; tableName : Text; indexName : Text }, [Text]>;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public type TableMetadataOutputType = {
        attributes : [Database.AttributeMetadata];
        indexes : [Database.TableIndexMetadata];
    };

    public type GetTableMetadataOutputType = ?{
        databaseName : Text;
        tableName : Text;
        metadata : TableMetadataOutputType;
    };

    public type ItemOutputType = {
        id : Text;
        item : [(Text, Datatypes.AttributeDataValue)];
    };

    public type GetItemByIdOutputType = Result.Result<ItemOutputType, [Text]>;

    public type BatchGetItemByIdOutputType = Result.Result<{ items : [ItemOutputType]; notFoundIds : [Text] }, [Text]>;

    public type GetItemCountOutputType = Result.Result<{ count : Nat }, [Text]>;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public type ScanOutputType = Result.Result<[{ id : Text; item : [(Text, Datatypes.AttributeDataValue)] }], [Text]>;

    public type ScanAndGetIdsOutputType = Result.Result<{ ids : [Text] }, [Text]>;

    public type PaginatedScanOutputType = Result.Result<{ items : [ItemOutputType]; limit : Nat; hasMore : Bool; nextCursor : ?SearchTypes.PaginatedScanCursor }, [Text]>;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public type AddAttributeOutputType = Result.Result<{ databaseName : Text; tableName : Text; attributeNames : Text }, [Text]>;

    public type DropAttributeOutputType = Result.Result<{ databaseName : Text; tableName : Text; attributeNames : Text }, [Text]>;

    public type UpdateItemOutputType = Result.Result<{ id : Text; item : [(Text, Datatypes.AttributeDataValue)] }, [Text]>;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public type DeleteDatabaseOutputType = Result.Result<{}, [Text]>;

    public type DeleteTableOutputType = Result.Result<{}, [Text]>;

    public type DeleteItemOutputType = Result.Result<{}, [Text]>;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public type GetDatabasesOutputType = {
        databases : [{
            name : Text;
            tables : [Text];
        }];
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public type UpdateOpsOutputType = {
        #CreateDatabaseOutput : CreateDatabaseOutputType;
        #CreateTableOutput : CreateTableOutputType;
        #AddAttributeOutput : AddAttributeOutputType;
        #DropAttributeOutput : DropAttributeOutputType;
        #CreateItemOutput : CreateItemOutputType;
        #CreateIndexOutput : CreateIndexOutputType;
        #UpdateItemOutput : UpdateItemOutputType;
        #DeleteDatabaseOutput : DeleteDatabaseOutputType;
        #DeleteTableOutput : DeleteTableOutputType;
        #DeleteItemOutput : DeleteItemOutputType;
    };

    public type QueryOpsOutputType = {
        #GetTableMetadataOutput : GetTableMetadataOutputType;
        #GetItemByIdOutput : GetItemByIdOutputType;
        #BatchGetItemByIdOutput : BatchGetItemByIdOutputType;
        #GetItemCountOutput : GetItemCountOutputType;
        #ScanOutput : ScanOutputType;
        #ScanAndGetIdsOutput : ScanAndGetIdsOutputType;
        #PaginatedScanOutput : PaginatedScanOutputType;
        #GetDatabasesOutput : GetDatabasesOutputType;
    };

};
