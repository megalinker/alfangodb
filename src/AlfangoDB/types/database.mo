import Datatypes "datatype";
import Map "mo:map/Map";
import Set "mo:map/Set";
import Time "mo:base/Time";
import Vector "mo:vector";
import BTree "mo:stableheapbtreemap/BTree";

module {

    type AttributeDataType = Datatypes.AttributeDataType;
    type AttributeDataValue = Datatypes.AttributeDataValue;

    public type Id = Text;
    public type DatabaseName = Text;
    public type TableName = Text;
    public type AttributeName = Text;
    public type IndexName = Text;

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public type AttributeMetadata = {
        name : AttributeName;
        dataType : AttributeDataType;
        unique : Bool;
        required : Bool;
        defaultValue : AttributeDataValue;
    };

    public type TableIndexMetadata = {
        name : IndexName;
        attributeNames : [AttributeName];
        unique : Bool;
    };

    public type TableMetadata = {
        attributesMap : Map.Map<AttributeName, AttributeMetadata>;
        var indexes : Vector.Vector<TableIndexMetadata>;
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public type Item = {
        id : Id;
        var attributeDataValueMap : Map.Map<AttributeName, AttributeDataValue>;
        createdAt : Time.Time;
        var updatedAt : Time.Time;
    };

    public type IndexTable = {
        attributeNames : [AttributeName];
        items : BTree.BTree<Text, Set.Set<Id>>;
    };

    public type Table = {
        name : Text;
        metadata : TableMetadata;
        items : Map.Map<Id, Item>;
        indexes : Map.Map<IndexName, IndexTable>;
        var pendingJobs : Vector.Vector<PendingJob>;
    };

    public type Database = {
        name : DatabaseName;
        tables : Map.Map<TableName, Table>;
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public type AlfangoDB = {
        databases : Map.Map<DatabaseName, Database>;
        STABLE_MEMORY_LIMIT : Nat64;
        var totalStableBytes : Nat64;
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public type DropAttributeJob = {
        attributeNames : AttributeName;
        var lastProcessedId : ?Id;
        var isComplete : Bool;
    };

    public type BuildIndexJob = {
        indexName : IndexName;
        var lastProcessedId : ?Id;
        var isComplete : Bool;
    };

    public type IndexOp = {
        #Del : (indexName : IndexName, compoundKey : Text);
        #Add : (indexName : IndexName, compoundKey : Text);
    };

    public type PendingJob = {
        #DropAttribute : DropAttributeJob;
        #BuildIndex : BuildIndexJob;
        // This can be extended in the future with other job types,
        // e.g., #BuildIndex, #RevalidateData, etc.
    };

};
