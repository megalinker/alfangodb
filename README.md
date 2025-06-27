# AlfangoDB 📦

**AlfangoDB** is a pure‑Motoko, *stable‑memory‑friendly* document store with secondary indexes, batched background jobs and Dynamo‑style query operators.  It is designed to be embedded as a **library** inside your existing Internet Computer canisters or as a standalone actor (pre‑built class included).

---

## ✨ Key features

| Feature                                                                                            | What it means                                   | IC‑specific benefit                       |
| -------------------------------------------------------------------------------------------------- | ----------------------------------------------- | ----------------------------------------- |
| **Fully stable** data‑structures (`BTree`, `Map`, `Set`, `Vector`)                                 | Survives canister upgrades without copy‑out     | Zero downtimes for schema updates         |
| **Secondary indexes** (unique/non‑unique)                                                          | Query by arbitrary attribute prefixes or ranges | Sub‑millisecond indexed look‑ups          |
| **Declarative filters** (`=`, `≠`, `<`, `≤`, `between`, `begins_with`, `contains`, `in`, `exists`) | Expressive queries without hand‑coding scans    | Syntax parallels DynamoDB / MongoDB       |
| **Background jobs** (`BuildIndex`, `DropAttribute`)                                                | Heavy tasks run incrementally every 5 min       | No blocking of user writes                |
| **Strict memory accounting**                                                                       | Per‑item byte estimate + global limit           | Prevents trap on `stableMemory.grow`      |
| **Single‑lock serialisation**                                                                      | One global lock + timer                         | Simplicity & safety on a replicated state |

---

## 📦 Installation

```bash
mops install alfangodb   # Motoko Package Manager
```

or add to your `dfx.json`:

```json
"canisters": {
  "my_db": {
    "type": "motoko",
    "package": "alfangodb",
    "main": "index.mo"
  }
}
```

> 🛈 **ICRC‑7** compliance: AlfangoDB keeps all data inside a single canister.  If you expect >4 GiB you must shard manually or use multiple actors.

---

## 🚀 Quick start

```motoko
import AlfangoDB "mo:alfangodb";

// ➊ Spin up the actor (or embed the struct inside your own).
actor db : AlfangoDB.AlfangoDBActor {};

// ➋ Create a database
let _ = await db.updateOperation(#CreateDatabaseInput({ name = "demo" }));

// ➌ Create a table with two attributes and one unique composite index
let tblInput : InputTypes.CreateTableInputType = {
  databaseName = "demo";
  name = "users";
  attributes = [
    { name = "email";  dataType = #text;  unique = true;  required = true;  defaultValue = #default },
    { name = "age";    dataType = #nat8;  unique = false; required = false; defaultValue = #default },
  ];
  indexes = [
    { name = "by_email"; attributeNames = ["email"]; unique = true },
  ];
};
let _ = await db.updateOperation(#CreateTableInput(tblInput));

// ➍ Insert an item
let itemRes = await db.updateOperation(#CreateItemInput({
  databaseName = "demo";
  tableName    = "users";
  attributeDataValues = [ ("email", #text "alice@example.com"), ("age", #nat8 30) ];
}));
```

---

## 🛠 API guide

For **every** operation below you may either:

1. Call the low‑level helper (e.g. `Create.createItem({ …; alfangoDB })`) **inside** your own actor if you manage `AlfangoDB` storage yourself; **or**
2. Use the high‑level multiplexed endpoint of `AlfangoDBActor` (`updateOperation` / `queryOperation`).

### 1 · Schema operations

| Operation               | Input variant          | Example                                                                                      |
| ----------------------- | ---------------------- | -------------------------------------------------------------------------------------------- |
| Create DB               | `#CreateDatabaseInput` | `#CreateDatabaseInput({ name = "blog" })`                                                    |
| Create table            | `#CreateTableInput`    | See *Quick start* above                                                                      |
| Add attribute           | `#AddAttributeInput`   | `{ attribute = { name="title"; dataType=#text; … } }`                                        |
| Drop attribute (*lazy*) | `#DropAttributeInput`  | Attribute disappears instantly; heavy data cleanup runs in background                        |
| Create index            | `#CreateIndexInput`    | `{ index = { name="by_status_date"; attributeNames=["status","createdAt"]; unique=false } }` |

### 2 · CRUD

```motoko
// Create (returns ulid id)
let createOut = await db.updateOperation(#CreateItemInput({ … }));

// Read by id
let readOut = await db.queryOperation(#GetItemByIdInput({ … }));

// Update (partial patch)
let upd = #UpdateItemInput({
  databaseName = "demo";
  tableName    = "users";
  id           = "01HF…";
  attributeDataValues = [ ("age", #nat8 31) ];
});
let _ = await db.updateOperation(upd);

// Delete
let _ = await db.updateOperation(#DeleteItemInput({ … }));
```

### 3 · Query / Scan

```motoko
// Full predicate – uses best index automatically
let filter : QueryFilter = #AND([
  #expression({ attributeNames="status"; filterExpressionCondition=#EQ(#text "active") }),
  #expression({ attributeNames="age";    filterExpressionCondition=#BETWEEN(#nat8 18, #nat8 35) })
]);

let out = await db.queryOperation(#ScanInput({
  databaseName = "demo";
  tableName    = "users";
  filter       = filter;
}));
```

### 4 · Paginated scan

```motoko
var cursor : ?SearchTypes.PaginatedScanCursor = null;
label paged loop {
  let page = await db.queryOperation(#PaginatedScanInput({
    databaseName = "demo";
    tableName    = "users";
    filter       = filter;
    limit        = 50;
    cursor       = cursor;
  }));
  switch(page) { case (#ok({ items; nextCursor; hasMore; … })) {
    // … process items …
    if (hasMore) { cursor := nextCursor; continue paged } else { break paged };
  } case (#err(e)) Debug.trap(debug_show e) };
};
```

---

## 🏎️ Runtime complexity cheatsheet

| Path                          | Typical case         | Notes                                               |
| ----------------------------- | -------------------- | --------------------------------------------------- |
| **createItem**                | `O(a + i·log n)`     | `a`=attribute count, `i`=indexes touched, `n`=items |
| **getItemById**               | `O(log n)`           | B‑tree lookup                                       |
| **updateItem**                | `O(k + i·log n)`     | `k`=attributes patched                              |
| **scan (index)**              | `O(log n + r)`       | `r`=results returned                                |
| **paginatedScan (full)**      | `O(log n + k·batch)` | Batched 100 rows at a time                          |
| **createIndex (empty table)** | `O(1)`               | Immediate                                           |
| **createIndex (populated)**   | `O(n)` *background*  | Done in 100‑row batches                             |
| **dropAttribute**             | `O(n)` *background*  | Also batched                                        |

> All collection operations rely on the complexity guarantees of Motoko’s `StableBTree`, `Map`, `Vector`, `Set`, and `Buffer`.  See */docs/complexity\_reference.md* for the full table reproduced from the Motoko base‑library docs.

---

## 🔧 Internal architecture (skip if you only need the API)

* **Item storage** – stable `BTree<Id, Item>`; each `Item` holds a stable `Map` of `StoredAttribute`s (value + cached byte‑size).
* **Index** – per‑table mutable `Map<IndexName, IndexTable>`; each `IndexTable` is a stable `BTree<CompoundKey, Set<Id>>`.
* **Compound keys** – deterministic `serializeValue()` + `"||"` separator ⇒ lexical order == semantic order for primitive types.
* **Memory budgeting** – running counter `totalStableBytes`; every create/update/delete adjusts it; checked against `STABLE_MEMORY_LIMIT` (default ≈ 3 GiB).
* **Jobs** – `Vector<PendingJob>` per table. Timer fires every 300 s, processes at most 100 items per job, then reschedules.

---

## 🧪 Testing

```bash
dfx start --background
moc -r src/tests/test.mo
```

Unit tests cover uniqueness, pagination edges, schema drift and memory overflow traps.

---

## 🤝 Contributing

1. Fork ➜ feature branch ➜ PR.
2. Ensure `mops test` & `ic-cdk-verify` pass.
3. Document public functions and add complexity notes.

---

## 🪪 License

MIT © 2025 Ztudio.  See `LICENSE` file for details.