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
import Order "mo:base/Order";
import Buffer "mo:base/Buffer";
import Iter "mo:base/Iter";
import Database "types/database";

module {

    type AttributeDataType = Datatypes.AttributeDataType;
    type AttributeDataValue = Datatypes.AttributeDataValue;
    type MapKVPair = (Text, AttributeDataValue);

    public let COMPOUND_KEY_SEPARATOR : Text = "||";

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    let hexChars : [Char] = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'];

    private func byteToHex(b : Nat8) : Text {
        let high = Nat.div(Nat8.toNat(b), 16);
        let low = Nat.rem(Nat8.toNat(b), 16);
        let highChar = Text.fromChar(hexChars[high]);
        let lowChar = Text.fromChar(hexChars[low]);
        return highChar # lowChar;
    };

    public func serializeValue(val : AttributeDataValue) : Text {
        switch (val) {
            // Primitive types are fine as they are, no loops.
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
            case (#float(v)) {
                return "f:" # normalizeFloatText(Float.toText(v));
            };
            case (#text(v)) { return "t:" # v };
            case (#char(v)) { return "c:" # Char.toText(v) };
            case (#bool(v)) { return "b:" # Bool.toText(v) };
            case (#principal(v)) { return "p:" # Principal.toText(v) };

            // Blob serialization can also be optimized slightly
            case (#blob(v)) {
                let buffer = Buffer.Buffer<Text>(Array.size(Blob.toArray(v)) * 2 + 2);
                buffer.add("B:");
                for (byte in Blob.toArray(v).vals()) {
                    buffer.add(byteToHex(byte));
                };
                return Text.join("", buffer.vals());
            };

            // --- OPTIMIZED LIST SERIALIZATION ---
            case (#list(vs)) {
                if (vs.size() == 0) { return "L:[]" };

                // Use a Buffer to avoid repeated concatenation
                let buffer = Buffer.Buffer<Text>(vs.size() * 2 + 1);
                buffer.add("L:[");
                let arr = Iter.toArray(vs.vals());
                for (i in Iter.range(0, arr.size() - 1)) {
                    buffer.add(serializeValue(arr[i]));
                    if (i < arr.size() - 1) {
                        buffer.add(",");
                    };
                };
                buffer.add("]");

                // Join all the parts into a single Text object at the end
                return Text.join("", buffer.vals());
            };

            // --- OPTIMIZED MAP SERIALIZATION ---
            case (#map(kvs)) {
                if (kvs.size() == 0) { return "M:{}" };

                let keys = Array.map<MapKVPair, Text>(kvs, func(kv) { kv.0 });
                let sortedKeys = Array.sort<Text>(keys, Text.compare);
                let kvMap = HashMap.fromIter<Text, AttributeDataValue>(kvs.vals(), 0, Text.equal, Text.hash);

                // Use a Buffer to avoid repeated concatenation
                let buffer = Buffer.Buffer<Text>(kvs.size() * 4 + 1);
                buffer.add("M:{");
                for (i in Iter.range(0, sortedKeys.size() - 1)) {
                    let key = sortedKeys[i];
                    let value = switch (kvMap.get(key)) {
                        case (null) { Prelude.unreachable() };
                        case (?val) { val };
                    };

                    buffer.add("t:" # key);
                    buffer.add(":");
                    buffer.add(serializeValue(value));

                    if (i < sortedKeys.size() - 1) {
                        buffer.add(",");
                    };
                };
                buffer.add("}");

                // Join all the parts into a single Text object at the end
                return Text.join("", buffer.vals());
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

            case (#list(_)) hash := thash.0 (serializeValue(attributeDataValue));
            case (#map(_)) hash := thash.0 (serializeValue(attributeDataValue));
            case (#default) hash := 0;
        };

        return hash;
    };

    public func areEqual(v1 : AttributeDataValue, v2 : AttributeDataValue) : Bool {
        return serializeValue(v1) == serializeValue(v2);
    };

    private func normalizeFloatText(t : Text) : Text {
        // If there's no decimal point, the text is already canonical.
        if (not Text.contains(t, #char '.')) {
            return t;
        };

        // Use a buffer for efficient character removal.
        let buffer = Buffer.fromArray<Char>(Text.toArray(t));

        // Remove trailing '0's as long as they exist and the buffer isn't empty.
        while (buffer.size() > 0 and buffer.get(buffer.size() - 1) == '0') {
            ignore buffer.removeLast();
        };

        // If the last character is now a '.', remove it as well.
        if (buffer.size() > 0 and buffer.get(buffer.size() - 1) == '.') {
            ignore buffer.removeLast();
        };

        // If the buffer is empty (e.g., input was "0.0"), return "0"
        if (buffer.size() == 0) {
            return "0";
        };

        return Text.fromIter(Buffer.toArray(buffer).vals());
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

    private func getDataTypeOrder(v : AttributeDataValue) : Nat {
        switch (v) {
            case (#default) { 0 };
            // Numbers
            case (#int(_)) { 10 };
            case (#int8(_)) { 11 };
            case (#int16(_)) { 12 };
            case (#int32(_)) { 13 };
            case (#int64(_)) { 14 };
            case (#nat(_)) { 20 };
            case (#nat8(_)) { 21 };
            case (#nat16(_)) { 22 };
            case (#nat32(_)) { 23 };
            case (#nat64(_)) { 24 };
            case (#float(_)) { 30 };
            // Strings
            case (#text(_)) { 40 };
            case (#char(_)) { 41 };
            // Other primitives
            case (#bool(_)) { 50 };
            case (#principal(_)) { 60 };
            case (#blob(_)) { 70 };
            // Complex types
            case (#list(_)) { 80 };
            case (#map(_)) { 90 };
        };
    };

    public func compareAttributeDataValues(v1 : AttributeDataValue, v2 : AttributeDataValue) : Order.Order {
        let typeOrder1 = getDataTypeOrder(v1);
        let typeOrder2 = getDataTypeOrder(v2);
        if (typeOrder1 != typeOrder2) {
            return Nat.compare(typeOrder1, typeOrder2);
        };

        switch (v1) {
            case (#int(val1)) {
                switch v2 {
                    case (#int(val2)) { return Int.compare(val1, val2) };
                    case (_) { Prelude.unreachable() };
                };
            };
            case (#int8(val1)) {
                switch v2 {
                    case (#int8(val2)) { return Int8.compare(val1, val2) };
                    case (_) { Prelude.unreachable() };
                };
            };
            case (#int16(val1)) {
                switch v2 {
                    case (#int16(val2)) { return Int16.compare(val1, val2) };
                    case (_) { Prelude.unreachable() };
                };
            };
            case (#int32(val1)) {
                switch v2 {
                    case (#int32(val2)) { return Int32.compare(val1, val2) };
                    case (_) { Prelude.unreachable() };
                };
            };
            case (#int64(val1)) {
                switch v2 {
                    case (#int64(val2)) { return Int64.compare(val1, val2) };
                    case (_) { Prelude.unreachable() };
                };
            };
            case (#nat(val1)) {
                switch v2 {
                    case (#nat(val2)) { return Nat.compare(val1, val2) };
                    case (_) { Prelude.unreachable() };
                };
            };
            case (#nat8(val1)) {
                switch v2 {
                    case (#nat8(val2)) { return Nat8.compare(val1, val2) };
                    case (_) { Prelude.unreachable() };
                };
            };
            case (#nat16(val1)) {
                switch v2 {
                    case (#nat16(val2)) { return Nat16.compare(val1, val2) };
                    case (_) { Prelude.unreachable() };
                };
            };
            case (#nat32(val1)) {
                switch v2 {
                    case (#nat32(val2)) { return Nat32.compare(val1, val2) };
                    case (_) { Prelude.unreachable() };
                };
            };
            case (#nat64(val1)) {
                switch v2 {
                    case (#nat64(val2)) { return Nat64.compare(val1, val2) };
                    case (_) { Prelude.unreachable() };
                };
            };
            case (#text(val1)) {
                switch v2 {
                    case (#text(val2)) { return Text.compare(val1, val2) };
                    case (_) { Prelude.unreachable() };
                };
            };

            case (_) {
                return Text.compare(serializeValue(v1), serializeValue(v2));
            };
        };
    };

    public func generateCompoundKey(
        itemData : Map.Map<Database.AttributeName, AttributeDataValue>,
        attributeNames : [Database.AttributeName],
    ) : ?Text {
        let keyParts = Buffer.Buffer<Text>(attributeNames.size());

        for (attrName in attributeNames.vals()) {
            switch (Map.get(itemData, thash, attrName)) {
                case (null) {
                    return null;
                };
                case (?attrValue) {
                    keyParts.add(serializeValue(attrValue));
                };
            };
        };

        return ?Text.join(COMPOUND_KEY_SEPARATOR, Array.vals(Buffer.toArray(keyParts)));
    };

    // A helper function to estimate the size of any given value.
    public func calculateAttributeDataValueSize(val : AttributeDataValue) : Nat64 {
        // Base overhead for any value (e.g., pointers, tags)
        var size : Nat64 = 8;

        switch (val) {
            case (#default) {};
            case (#int(_)) { size += 8 }; // Approximate Int as 8 bytes
            case (#int8(_)) { size += 1 };
            case (#int16(_)) { size += 2 };
            case (#int32(_)) { size += 4 };
            case (#int64(_)) { size += 8 };
            case (#nat(_)) { size += 8 }; // Approximate Nat as 8 bytes
            case (#nat8(_)) { size += 1 };
            case (#nat16(_)) { size += 2 };
            case (#nat32(_)) { size += 4 };
            case (#nat64(_)) { size += 8 };
            case (#float(_)) { size += 8 };
            case (#text(v)) { size += Nat64.fromNat(Text.size(v)) };
            case (#char(_)) { size += 4 }; // Char is a Nat32
            case (#bool(_)) { size += 1 };
            case (#principal(_)) { size += 29 }; // Approximate size of a principal
            case (#blob(v)) {
                size += Nat64.fromNat(Array.size(Blob.toArray(v)));
            };
            case (#list(vs)) {
                for (v in vs.vals()) {
                    size += calculateAttributeDataValueSize(v);
                };
            };
            case (#map(kvs)) {
                for ((key, val) in kvs.vals()) {
                    size += Nat64.fromNat(Text.size(key));
                    size += calculateAttributeDataValueSize(val);
                };
            };
        };
        return size;
    };

    // Function to calculate the total estimated size of a database Item.
    public func calculateItemSize(
        itemDataMap : Map.Map<Database.AttributeName, AttributeDataValue>
    ) : Nat64 {
        // Start with an estimate for the Item record overhead itself.
        var totalSize : Nat64 = 64;

        for ((attrName, attrValue) in Map.entries(itemDataMap)) {
            // Add size of the attribute name (key) in the map
            totalSize += Nat64.fromNat(Text.size(attrName));
            // Add size of the attribute value
            totalSize += calculateAttributeDataValueSize(attrValue);
        };

        return totalSize;
    };
};
