# AlfangoDB · Complexity Reference

> A condensed cheat‑sheet of the asymptotic runtimes & space costs for the Motoko collections AlfangoDB relies on.  All values are taken from the Motoko base‑library docs (May 2025) or from the Stable Heap B‑Tree Map README.

---

## 1  Stable `Vector`

| Operation                        | Time         | Space  |
| -------------------------------- | ------------ | ------ |
| `size` / `get` / `put`           | **O(1)**     | O(1)   |
| `add` (amortised) / `removeLast` | **O(1)**     | O(1)   |
| `addMany`                        | O(*k*)       | O(*k*) |
| `sort`                           | O(*n log n*) | O(*n*) |
| `clone`, `map`, `toArray`        | O(*n*)       | O(*n*) |

## 2  Non‑stable `Buffer`

| Operation                        | Time         | Space  |
| -------------------------------- | ------------ | ------ |
| `size`, `get`, `put`, `capacity` | **O(1)**     | O(1)   |
| `add` / `removeLast` (amortised) | **O(1)**     | O(1)   |
| `insert`, `remove`               | O(*n*)       | O(*n*) |
| `sort`                           | O(*n log n*) | O(*n*) |
| `vals`, `toArray`, `clone`       | O(*n*)       | O(*n*) |

## 3  Stable Heap `BTree`

Assume order *b* (default 64).

| Operation                 | Time              | Space       |
| ------------------------- | ----------------- | ----------- |
| `get`, `insert`, `delete` | **O(log\_b n)**   | O(log\_b n) |
| `scanLimit(k)`            | O(log\_b n + *k*) | O(*k*)      |
| `size`                    | **O(1)**          | O(1)        |

## 4  Stable `Map` / `Set`

(Balanced red‑black tree.)

| Operation                    | Time         | Space                              |
| ---------------------------- | ------------ | ---------------------------------- |
| `put`, `get`, `delete`       | **O(log n)** | O(log n)                           |
| `entries`, `vals` (iterator) | O(*n*)       | O(log n) retained + O(*n*) garbage |
| `fromIter`                   | O(*n log n*) | O(*n*)                             |

## 5  Non‑stable `HashMap`

| Operation              | Average‑case | Worst‑case |
| ---------------------- | ------------ | ---------- |
| `get`, `put`, `delete` | **O(1)**     | O(*n*)     |
| `entries`, `vals`      | O(*n*)       | O(*n*)     |

## 6  Why it matters in AlfangoDB

| AlfangoDB hot‑path | Dominant collection                 | Complexity derived          |
| ------------------ | ----------------------------------- | --------------------------- |
| Primary key lookup | **Stable BTree.get**                | O(log *n*)                  |
| Index insertion    | **Stable BTree.insert** + `Set.put` | O(log *n*<sub>i</sub>)      |
| Batch job scanning | **BTree.scanLimit** (k = 100)       | O(log *n* + 100) ≈ O(log n) |
| Patch‑map replay   | `HashMap.get/put`                   | Amortised O(*k*)            |

> **Tip:** Because every per‑item operation touches only *O(log n)* stable nodes, AlfangoDB remains snappy even when the table has millions of rows, as long as the WASM heap (<4 GiB) is within IC limits.

---

### Source links

* Motoko Base Library – [Vector](https://mops.one/vector/docs/lib), [Buffer](https://internetcomputer.org/docs/motoko/base/Buffer), etc.
* [stableheapbtreemap](https://canscale.github.io/StableHeapBTreeMap/BTree.html) README.
* IC Team tech‑talk “Data‑structures on stable memory”, Feb 2025.
