import Timer "mo:base/Timer";
import Debug "mo:base/Debug";
import Nat "mo:base/Nat";
import Time "mo:base/Time";
import Int "mo:base/Int";
import Error "mo:base/Error";
import Database "types/database";
import InputTypes "types/input";
import OutputTypes "types/output";
import Jobs "modules/jobs";
import Service "service";
import Map "mo:map/Map";

/**
* This is the main stateful actor class for the AlfangoDB service.
* To create a database canister, you would deploy an actor of this class.
*
* It is responsible for:
* 1. Holding the database state in a stable variable for persistence across upgrades.
* 2. Exposing the public `queryOperation` and `updateOperation` methods.
* 3. Managing a recurring background timer to process jobs like index building.
*/
actor class AlfangoDBActor() {

    stable var db_instance : Database.AlfangoDB = {
        databases = Map.new<Database.DatabaseName, Database.Database>();
        STABLE_MEMORY_LIMIT = 3_221_225_472;
        var totalStableBytes : Nat64 = 0;
    };

    var jobTimerId : ?Timer.TimerId = null;
    var isProcessingJobs : Bool = false;

    system func postupgrade() {
        Debug.print("Restarting job processor after upgrade...");
        let interval : Timer.Duration = #seconds 300;

        jobTimerId := ?Timer.recurringTimer<system>(
            interval,
            func() : async () {
                // 1. CHECK THE GUARD
                if (isProcessingJobs) {
                    Debug.print("--- Job processor is already running. Skipping this cycle. ---");
                    return;
                };

                try {
                    // 2. ACQUIRE THE LOCK
                    isProcessingJobs := true;

                    Debug.print("Timer fired at: " # Int.toText((Time.now())));
                    Jobs.processAllPendingJobs(db_instance);

                } catch (e) {
                    Debug.print("CRITICAL: Job processor trapped with error: " # Error.message(e));
                };

                // 3. RELEASE THE LOCK
                isProcessingJobs := false;
            },
        );

        Debug.print(
            "DB Job Processor started with interval: " #
            (
                switch interval {
                    case (#seconds s) { Nat.toText(s) };
                    case (#nanoseconds _n) { Nat.toText(0) };
                }
            ) # "s " #
            (
                switch interval {
                    case (#nanoseconds n) { Nat.toText(n) };
                    case (#seconds _s) { Nat.toText(0) };
                }
            ) # "ns."
        );
    };

    // System lifecycle hook: called on initial installation of the canister.
    // This starts the job processor for the first time.
    public func init() : async () {
        Debug.print("Initializing canister and starting job processor...");
        let interval : Timer.Duration = #seconds 300;

        jobTimerId := ?Timer.recurringTimer<system>(
            interval,
            func() : async () {
                // 1. CHECK THE GUARD
                if (isProcessingJobs) {
                    Debug.print("--- Job processor is already running. Skipping this cycle. ---");
                    return;
                };

                try {
                    // 2. ACQUIRE THE LOCK
                    isProcessingJobs := true;

                    Debug.print("Timer fired at: " # Int.toText((Time.now())));
                    Jobs.processAllPendingJobs(db_instance);

                } catch (e) {
                    Debug.print("CRITICAL: Job processor trapped with error: " # Error.message(e));
                };

                // 3. RELEASE THE LOCK
                isProcessingJobs := false;
            },
        );

        Debug.print(
            "DB Job Processor started with interval: " #
            (
                switch interval {
                    case (#seconds s) { Nat.toText(s) };
                    case (#nanoseconds _n) { Nat.toText(0) };
                }
            ) # "s " #
            (
                switch interval {
                    case (#nanoseconds n) { Nat.toText(n) };
                    case (#seconds _s) { Nat.toText(0) };
                }
            ) # "ns."
        );
    };

    /**
    * Public endpoint for all data modification operations (create, update, delete).
    * It delegates the call to the central service dispatcher.
    */
    public shared func updateOperation(updateOpsInput : InputTypes.UpdateOpsInputType) : async OutputTypes.UpdateOpsOutputType {

        // 1. ACQUIRE GLOBAL LOCK
        if (isProcessingJobs) {
            Debug.trap("Concurrency Conflict: The database is currently busy with a background job or another write operation. Please try again shortly.");
        };
        isProcessingJobs := true;

        // 2. EXECUTE THE OPERATION
        // Initialize `result` with a default error value to satisfy Motoko's variable declaration rules.
        // This value will be overwritten in the `try` block on success.
        var result : OutputTypes.UpdateOpsOutputType = #CreateDatabaseOutput(#err(["Operation did not complete."]));

        try {
            result := await Service.updateOperation({
                updateOpsInput;
                alfangoDB = db_instance;
            });
        } catch (e) {
            Debug.print("CRITICAL: updateOperation trapped with error: " # Error.message(e));
            result := #CreateDatabaseOutput(#err(["An unexpected internal error occurred during the update operation."]));
        };

        // 3. RELEASE GLOBAL LOCK
        isProcessingJobs := false;

        return result;
    };

    /**
    * Public endpoint for all data query operations (read, scan, etc.).
    * It delegates the call to the central service dispatcher.
    */
    public shared func queryOperation(queryOpsInput : InputTypes.QueryOpsInputType) : async OutputTypes.QueryOpsOutputType {
        return await Service.queryOperation({
            queryOpsInput;
            alfangoDB = db_instance;
        });
    };
};
