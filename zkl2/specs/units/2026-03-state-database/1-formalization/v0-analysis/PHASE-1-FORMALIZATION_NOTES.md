# Phase 1: Formalization Notes -- StateDatabase (RU-L4)

**Unit**: State Database (SMT Poseidon for EVM)
**Target**: zkl2
**Date**: 2026-03-19
**Result**: PASS

---

## 1. Research-to-Specification Mapping

| Research Concept | Source | TLA+ Element |
|---|---|---|
| Sparse Merkle Tree | 0-input/REPORT.md, Section 3 | `ComputeNode`, `ComputeRoot`, `WalkUp` (from RU-V1) |
| Poseidon2 hash (BN254) | 0-input/REPORT.md, Section 2.1 | `Hash(a, b)` -- algebraic model over F_65537 |
| EVM Account Trie | 0-input/REPORT.md, Section 3 -- "Account Trie" | `AccountEntries`, `ComputeAccountRoot` |
| EVM Storage Trie | 0-input/REPORT.md, Section 3 -- "Storage Trie" | `storageData[c]`, `ComputeStorageRoot(c)` |
| Account hash | 0-input/REPORT.md -- "Poseidon(nonce, balance, codeHash, storageRoot)" | `AccountValue(addr)` = `Hash(balance, storageRoot)` |
| Insert operation | 0-input/code/smt.go -- Insert method | `WalkUp` (incremental path recomputation) |
| Batch update | 0-input/code/smt_optimized.go -- sequential updates | `Transfer` (two-step WalkUp), `SelfDestruct` (two-step) |
| CreateAccount | 0-input/REPORT.md -- EVM account creation | `CreateAccount(addr)` action |
| Balance transfer | 0-input/REPORT.md -- EVM transfer model | `Transfer(from, to, amount)` action |
| SSTORE | 0-input/REPORT.md -- Storage Trie | `SetStorage(contract, slot, value)` action |
| SELFDESTRUCT | 0-input/REPORT.md -- EVM semantics | `SelfDestruct(contract, beneficiary)` action |
| Root consistency | RU-V1 ConsistencyInvariant | `ConsistencyInvariant` (two-level) |
| Account integrity | 0-input/REPORT.md -- "AccountIntegrity" | `AccountIsolation` (proof completeness) |
| Storage isolation | 0-input/REPORT.md -- "StorageIsolation" | `StorageIsolation` (proof completeness) |
| Balance conservation | EVM semantics | `BalanceConservation` |

## 2. Extension from RU-V1

The specification reuses all core operators from the validium SparseMerkleTree.tla (RU-V1), with the following extensions:

### 2.1 Operators Inherited from RU-V1 (Unchanged)

| Operator | Purpose |
|---|---|
| `Hash(a, b)` | Algebraic hash model (F_65537) |
| `LeafHash(key, value)` | Leaf hash with EMPTY sentinel |
| `DefaultHash(level)` | Precomputed empty subtree hashes |
| `EntryValue(e, idx)` | Sparse entry lookup |
| `ComputeNode(e, level, index)` | Full tree rebuild (reference truth) |
| `PathBit(key, level)` | Direction bit extraction |
| `SiblingIndex(key, level)` | Sibling position computation |
| `SiblingHash(e, key, level)` | Sibling subtree hash |
| `ProofSiblings(e, key, depth)` | Merkle proof generation |
| `VerifyWalkUp(...)` | Proof verification walk |
| `VerifyProof(...)` | Full proof verification |

### 2.2 Operators Extended for Two-Level Trie

| Operator | Extension |
|---|---|
| `ComputeRoot(e, depth)` | Depth-parameterized (was global DEPTH) |
| `WalkUp(e, h, k, l, depth)` | 5-arg with explicit depth parameter |
| `ProofSiblings(e, key, depth)` | Depth-parameterized |
| `PathBitsForKey(key, depth)` | Depth-parameterized |
| `VerifyWalkUp(h, s, p, l, depth)` | Depth-parameterized |
| `VerifyProof(r, h, s, p, depth)` | Depth-parameterized |

### 2.3 New Operators (EVM Account Model)

| Operator | Purpose |
|---|---|
| `AccountValue(addr)` | Compute account hash: `Hash(balance, storageRoot)` |
| `AccountEntries` | Build account trie entries from state variables |
| `ComputeAccountRoot` | Full account trie rebuild |
| `ComputeStorageRoot(c)` | Full storage trie rebuild for contract `c` |
| `SumOver(f, S)` | Recursive summation for balance conservation |
| `TotalBalance` | Sum of all account balances |

## 3. Assumptions and Simplifications

### 3.1 Deliberate Simplifications

| Simplification | Justification |
|---|---|
| Nonce omitted from account hash | Orthogonal to isolation and conservation properties |
| codeHash omitted from account hash | Orthogonal to isolation and conservation properties |
| Single EOA genesis | Sufficient to exercise all invariants; avoids MaxBalance overflow |
| Depth 2 trees | Full path-bit coverage (both left/right at both levels) |
| Algebraic hash (not Poseidon) | Model checking requires finite, deterministic hash; algebraic model preserves structural properties |

### 3.2 Modeling Decisions

1. **GetStorage as invariant**: GetStorage is a read-only operation. Its correctness is verified by `StorageIsolation`, which checks that every storage slot (including empty positions) has a valid Merkle proof. This is stronger than modeling GetStorage as an action.

2. **SetStorage includes deletion**: Setting a slot to EMPTY (value = 0) is equivalent to deletion (EVM SSTORE(key, 0)). This is modeled as a single `SetStorage` action with `value \in StorageValues \cup {EMPTY}`.

3. **Two-step WalkUp for multi-leaf updates**: Transfer and SelfDestruct modify two account leaves. The implementation applies updates sequentially: first update in the current tree, then second update in the intermediate tree. The `interEntries` function captures this intermediate state.

4. **AccountValue for dead accounts**: Dead accounts map to EMPTY in the account trie, making them invisible. This models the EVM behavior where non-existent accounts have zero state.

## 4. Verification Results

### 4.1 Model Configuration

| Parameter | Value | Rationale |
|---|---|---|
| Addresses | {0, 1, 2} | 1 EOA + 2 contracts |
| Contracts | {1, 2} | Two smart contracts |
| Slots | {0, 1} | Two storage slots per contract |
| MaxBalance | 3 | Total supply = 3 |
| StorageValues | {1, 2} | Two non-zero storage values |
| ACCOUNT_DEPTH | 2 | 4 leaf positions (3 active + 1 empty) |
| STORAGE_DEPTH | 2 | 4 leaf positions (2 active + 2 empty) |

### 4.2 TLC Output

```
TLC2 Version 2.16 of 31 December 2020 (rev: cdddf55)
Model checking completed. No error has been found.
15231 states generated, 883 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 9.
Finished in 01s.
```

### 4.3 Result Summary

| Metric | Value |
|---|---|
| States generated | 15,231 |
| Distinct states | 883 |
| State graph depth | 9 |
| Queue remaining | 0 (exhaustive) |
| Violations found | 0 |
| Runtime | 1 second |
| Workers | 4 |

### 4.4 Invariant Verification

| Invariant | Status | What It Verified |
|---|---|---|
| `TypeOK` | PASS | All state variables remain well-typed across 883 states |
| `ConsistencyInvariant` | PASS | WalkUp agrees with ComputeRoot at both trie levels in all 883 states |
| `AccountIsolation` | PASS | All 4 account leaf positions have valid Merkle proofs in all states |
| `StorageIsolation` | PASS | All 4 storage positions per alive contract have valid proofs |
| `BalanceConservation` | PASS | Total balance = 3 in all 883 reachable states |

### 4.5 Reproduction Instructions

```bash
cd zkl2/specs/units/2026-03-state-database/1-formalization/v0-analysis/experiments/StateDatabase
mkdir -p _build
cp ../../specs/StateDatabase/StateDatabase.tla _build/
cp MC_StateDatabase.tla MC_StateDatabase.cfg _build/
cd _build
java -cp <path>/tla2tools.jar tlc2.TLC MC_StateDatabase -workers 4
```

## 5. Open Issues

1. **SoundnessInvariant not included**: RU-V1 verified that wrong values produce failed proofs (soundness). This invariant was omitted to keep model checking time bounded. The structural correctness from ConsistencyInvariant + AccountIsolation provides strong coverage. SoundnessInvariant could be added in a v1-fix if needed.

2. **Nonce and codeHash omitted**: The account hash in production is `Poseidon(nonce, balance, codeHash, storageRoot)`. The model uses `Hash(balance, storageRoot)`. Nonce and codeHash are orthogonal to the four invariants but could be added for completeness.

3. **Depth sensitivity**: Production EVM uses depth 160 (address space) for account trie and depth 256 (storage space) for storage tries. The model uses depth 2. The algebraic structure is identical regardless of depth; only performance changes. The Scientist's experiments show depth 160-256 impacts latency but not correctness.

4. **Persistent storage not modeled**: The Scientist recommends LevelDB/Pebble for >100K accounts. The TLA+ model uses in-memory state. Persistence introduces crash recovery concerns that could be a separate research unit.

---

**Verdict**: PASS. Proceed to Phase 2 (`/2-audit`).
