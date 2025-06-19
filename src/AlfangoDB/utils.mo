import {
    thash;
    ihash;
    i8hash;
    i16hash;
    i32hash;
    i64hash;
    nhash;
    n8hash;
    n16hash;
    n32hash;
    n64hash;
    bhash;
    lhash;
    phash;
} "mo:map/Map";
import Map "mo:map/Map";
import XorShift "mo:rand/XorShift";
import ULIDAsyncSource "mo:ulid/async/Source";
import ULIDSource "mo:ulid/Source";
import ULID "mo:ulid/ULID";
import Datatypes "types/datatype";
import Text "mo:base/Text";
import Char "mo:base/Char";
import Float "mo:base/Float";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Array "mo:base/Array";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Bool "mo:base/Bool";
import Int8 "mo:base/Int8";
import Int16 "mo:base/Int16";
import Int32 "mo:base/Int32";
import Int64 "mo:base/Int64";
import Nat8 "mo:base/Nat8";
import Nat16 "mo:base/Nat16";
import Nat32 "mo:base/Nat32";
import Nat64 "mo:base/Nat64";
import HashMap "mo:base/HashMap";
import Prelude "mo:base/Prelude";

module {

    type AttributeDataType = Datatypes.AttributeDataType;
    type AttributeDataValue = Datatypes.AttributeDataValue;
    type MapKVPair = (Text, AttributeDataValue);

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    let hexChars : [Char] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];

    private func byteToHex(b : Nat8) : Text {
        let high = Nat.div(Nat8.toNat(b), 16);
        let low = Nat.rem(Nat8.toNat(b), 16);
        let highChar = Text.fromChar(hexChars[high]);
        let lowChar = Text.fromChar(hexChars[low]);
        return highChar # lowChar;
    };

    private func serializeValue(val : AttributeDataValue) : Text {
        switch (val) {
            case (#default) { return "default" };
            case (#int(v)) { return "i:" # Int.toText(v) };
            case (#int8(v)) { return "i8:" # Int8.toText(v) };
            case (#int16(v)) { return "i16:" # Int16.toText(v) };
            case (#int32(v)) { return "i32:" # Int32.toText(v) };
            case (#int64(v)) { return "i64:" # Int64.toText(v) };
            case (#nat(v)) { return "n:" # Nat.toText(v) };
            case (#nat8(v)) { return "n8:" # Nat8.toText(v) };
            case (#nat16(v)) { return "n16:" # Nat16.toText(v) };
            case (#nat32(v)) { return "n32:" # Nat32.toText(v) };
            case (#nat64(v)) { return "n64:" # Nat64.toText(v) };
            case (#float(v)) { return "f:" # Float.toText(v) };
            case (#text(v)) { return "t:" # v };
            case (#char(v)) { return "c:" # Char.toText(v) };
            case (#bool(v)) { return "b:" # Bool.toText(v) };
            case (#principal(v)) { return "p:" # Principal.toText(v) };
            case (#blob(v)) {
                var result = "B:";
                for (byte in Blob.toArray(v).vals()) {
                    result := result # byteToHex(byte);
                };
                return result;
            };
            case (#list(vs)) {
                if (vs.size() == 0) { return "L:[]" };
                var result = "L:[";
                var i = 0;
                while (i < vs.size()) {
                    let item = vs[i];
                    result := result # serializeValue(item);
                    if (i < vs.size() - 1) {
                        result := result # ",";
                    };
                    i += 1;
                };
                result := result # "]";
                return result;
            };
            case (#map(kvs)) {
                if (kvs.size() == 0) { return "M:{}" };

                let keys = Array.map<MapKVPair, Text>(kvs, func(kv : MapKVPair) : Text { return kv.0 });
                let sortedKeys = Array.sort<Text>(keys, Text.compare);

                let kvMap = HashMap.fromIter<Text, AttributeDataValue>(kvs.vals(), 0, Text.equal, Text.hash);
                var result = "M:{";
                var i = 0;
                while (i < sortedKeys.size()) {
                    let key = sortedKeys[i];

                    let value = switch (kvMap.get(key)) {
                        case (null) { Prelude.unreachable() };
                        case (?val) { val };
                    };

                    let serializedKey = "t:" # key;
                    let serializedVal = serializeValue(value);
                    result := result # serializedKey # ":" # serializedVal;
                    if (i < sortedKeys.size() - 1) {
                        result := result # ",";
                    };
                    i += 1;
                };
                result := result # "}";
                return result;
            };
        };
    };

    private func getHash(attributeDataValue : AttributeDataValue) : Nat32 {
        var hash : Nat32 = 0;

        switch (attributeDataValue) {
            case (#text(value)) hash := thash.0 (value);
            case (#int(value)) hash := ihash.0 (value);
            case (#int8(value)) hash := i8hash.0 (value);
            case (#int16(value)) hash := i16hash.0 (value);
            case (#int32(value)) hash := i32hash.0 (value);
            case (#int64(value)) hash := i64hash.0 (value);
            case (#nat(value)) hash := nhash.0 (value);
            case (#nat8(value)) hash := n8hash.0 (value);
            case (#nat16(value)) hash := n16hash.0 (value);
            case (#nat32(value)) hash := n32hash.0 (value);
            case (#nat64(value)) hash := n64hash.0 (value);
            case (#blob(value)) hash := bhash.0 (value);
            case (#bool(value)) hash := lhash.0 (value);
            case (#principal(value)) hash := phash.0 (value);

            case (#float(value)) {
                hash := thash.0 (Float.toText(value));
            };
            case (#char(value)) {
                hash := thash.0 (Char.toText(value));
            };

            // FIXED: Use the stable serializer instead of debug_show
            case (#list(_)) hash := thash.0 (serializeValue(attributeDataValue));
            case (#map(_)) hash := thash.0 (serializeValue(attributeDataValue));
            case (#default) hash := 0;
        };

        return hash;
    };

    public func areEqual(v1 : AttributeDataValue, v2 : AttributeDataValue) : Bool {
        return serializeValue(v1) == serializeValue(v2);
    };

    public let DataTypeValueHashUtils : Map.HashUtils<AttributeDataValue> = (getHash, areEqual);

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    public func generateULIDSync() : Text {
        ULID.toText(ULIDSource.Source(XorShift.toReader(XorShift.XorShift64(null)), 123).new());
    };

    public func generateULIDAsync() : async Text {
        ULID.toText(await ULIDAsyncSource.Source(0).new());
    };

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
};
