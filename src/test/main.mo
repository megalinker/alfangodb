import AlfangoDB "../AlfangoDB";
import Database "../AlfangoDB/types/database";
import Map "mo:map/Map";

actor {

    stable var databases : Map.Map<Text, Database.Database> = Map.new<Text, Database.Database>();

    private func getDBContainer() : {
        databases : Map.Map<Text, Database.Database>;
    } {
        return { databases = databases };
    };

    public shared (_msg) func updateOperation({
        updateOpsInput : AlfangoDB.UpdateOpsInputType;
    }) : async AlfangoDB.UpdateOpsOutputType {

        return await AlfangoDB.updateOperation({
            updateOpsInput;
            alfangoDB = getDBContainer();
        });
    };

    public query (_msg) func queryOperation({
        queryOpsInput : AlfangoDB.QueryOpsInputType;
    }) : async AlfangoDB.QueryOpsOutputType {

        return AlfangoDB.queryOperation({
            queryOpsInput;
            alfangoDB = getDBContainer();
        });
    };
};
