# Phase 2: Audit Report -- State Transition Circuit (RU-V2)

## Unit Information

| Field | Value |
|-------|-------|
| Unit | state-transition-circuit (RU-V2) |
| Target | validium |
| Date | 2026-03-18 |
| Auditor Role | The Auditor |
| Verdict | **PASS** |

## 1. Structural Mapping

Side-by-side comparison of source materials (0-input/) against the TLA+ specification.

### 1.1 Circuit Templates to TLA+ Actions

| Circom Template | Location | TLA+ Operator | Faithful? |
|---|---|---|---|
| `MerklePathVerifier(depth)` | circom lines 13-47 | `WalkUp(treeEntries, currentHash, key, level)` | YES -- walks from leaf to root using sibling hashes, conditional on path bit direction |
| `SingleStateTransition(depth)` | circom lines 59-105 | `ApplyTx(treeEntries, currentRoot, tx)` | YES -- computes old leaf hash, verifies against root, computes new leaf hash, produces new root |
| `ChainedBatchStateTransition(depth, batchSize)` | circom lines 185-251 | `StateTransition(e, txBatch)` + `ApplyBatch(...)` | YES -- chains intermediate roots, first invalid tx stops processing |
| `component main` | circom line 256 | `Spec == Init /\ [][Next]_vars` | YES -- specification of the overall system behavior |

### 1.2 Circuit Signals to TLA+ Variables/Constants

| Circom Signal | Type | TLA+ Element | Faithful? |
|---|---|---|---|
| `prevStateRoot` | public input | `roots[e]` (pre-transition) | YES |
| `newStateRoot` | public input | `roots[e]` (post-transition via `result.root`) | YES |
| `batchNum` | public input | Not modeled | INTENTIONAL OMISSION -- batch numbering is metadata, not a safety-relevant state variable |
| `enterpriseId` | public input | `e \in Enterprises` | YES -- modeled as the enterprise parameter to `StateTransition` |
| `keys[batchSize]` | private input | `tx.key` in Tx record | YES |
| `oldValues[batchSize]` | private input | `tx.oldValue` in Tx record | YES |
| `newValues[batchSize]` | private input | `tx.newValue` in Tx record | YES |
| `siblings[batchSize][depth]` | private input | `SiblingHash(treeEntries, key, level)` | YES -- computed from tree state rather than provided as input (justified by RU-V1) |
| `pathBits[batchSize][depth]` | private input | `PathBit(key, level)` | YES -- computed from key rather than provided as input |
| `chainedRoots[batchSize + 1]` | internal signal | Implicit in `ApplyBatch` recursion | YES -- each recursive call passes `result.root` as `currentRoot` |

### 1.3 Circuit Constraints to TLA+ Invariants

| Circom Constraint | Location | TLA+ Invariant | Faithful? |
|---|---|---|---|
| `oldRootChecks[i].out === 1` | line 232 | `treeEntries[tx.key] = tx.oldValue` in `ApplyTx` | YES -- abstract equivalent (justified by RU-V1 SoundnessInvariant) |
| `finalCheck.out === 1` | line 250 | `StateRootChain` invariant | YES -- final root matches expected |
| Proof soundness (circuit unsatisfiable for wrong witness) | structural | `ProofSoundness` invariant | YES -- wrong oldValue always causes rejection |

## 2. Hallucination Detection

### 2.1 Mechanisms Present in Spec but NOT in Source

| TLA+ Element | In Source? | Assessment |
|---|---|---|
| `Hash(a, b)` prime-field model | No -- source uses Poseidon(2) | ACCEPTABLE: abstract model of Poseidon. Properties (injectivity, non-zero output) are weaker than Poseidon's collision resistance. The abstraction is conservative. |
| `DefaultHash(level)` | Yes -- in `generate_input.js` lines 28-35 | MATCH |
| `ComputeRoot(e)` full rebuild | No -- circuit uses incremental path only | ACCEPTABLE: ComputeRoot serves as the REFERENCE TRUTH for invariant checking. It is not used in state transitions. This is the standard TLA+ technique: actions use the efficient algorithm, invariants use the naive-but-obviously-correct algorithm. |
| `RejectInvalid(e, txBatch)` stutter action | Not explicit in circuit | ACCEPTABLE: models the circuit's rejection path (unsatisfiable constraints). Included for specification completeness. Does not change state. |
| Enterprise isolation via `EXCEPT` | Implicit in circuit (separate `enterpriseId`) | ACCEPTABLE: the TLA+ model makes explicit what the circuit achieves implicitly through separate proof generation per enterprise. |

**Verdict: No hallucinated mechanisms.** Every TLA+ element either directly maps to a source element or serves as a verification oracle (ComputeRoot) or specification completeness aid (RejectInvalid).

### 2.2 Assumptions Not Present in Source

| Assumption | Justification |
|---|---|
| Merkle proof validity = tree[key] = value | Justified by RU-V1 SoundnessInvariant (verified across 65,536 states). This is a proven property, not an assumption. |
| Hash function injectivity | Conservative abstraction of Poseidon's collision resistance. The linear hash model is strictly weaker than Poseidon (which is cryptographically collision-resistant). |
| Atomic batch processing | Matches circuit behavior: the entire batch is proved in a single ZK proof. There is no partial verification. |

## 3. Omission Detection

### 3.1 Source Elements NOT in Spec

| Source Element | Omitted? | Assessment |
|---|---|---|
| `batchNum` public input | YES | SAFE: batch numbering is metadata used for L1 contract sequencing, not a safety property of the state transition. It does not affect the correctness of root chaining. |
| `enterpriseId` public input (as value) | PARTIALLY | The spec models enterprises as distinct entities but does not track the enterprise ID as a value. SAFE: the ID is used by the L1 contract for routing, not by the circuit for verification. |
| Poseidon(2) constraint count (240 R1CS) | YES | OUT OF SCOPE: constraint counts are implementation metrics, not protocol properties. |
| Powers of Tau trusted setup | YES | OUT OF SCOPE: the trusted setup is a one-time ceremony, not a state transition property. |
| `Mux1` selector in MerklePathVerifier | YES | ABSTRACTED: the Mux1 (multiplexer) selects left/right child based on path bit. The TLA+ spec models this directly with `IF bit = 0 THEN Hash(current, sibling) ELSE Hash(sibling, current)`. Functionally equivalent. |
| Proof size (804 bytes) | YES | OUT OF SCOPE: proof size is an implementation metric. |
| Witness generation (`generate_input.js`) | YES | OUT OF SCOPE: witness generation is a prover-side concern. The spec models the verifier's perspective. |

### 3.2 State Transitions NOT in Spec

| Potential Transition | In Spec? | Assessment |
|---|---|---|
| Valid batch updates state | YES | `StateTransition` action |
| Invalid batch rejected | YES | `RejectInvalid` action (stutter step) |
| Concurrent enterprise batches | YES | `\E e \in Enterprises` in `Next` allows any enterprise to transition |
| Empty batch (0 transactions) | NO (guard: `Len >= 1`) | CORRECT: the circuit requires `batchSize >= 1` as a template parameter |
| Batch exceeding max size | NO (guard: `Len <= MaxBatchSize`) | CORRECT: the circuit has a fixed `batchSize` parameter |

**Verdict: No critical omissions.** All safety-relevant state transitions are modeled. Omitted elements are either out of scope (implementation metrics) or correctly excluded (empty batches).

## 4. Protocol Flaw Assessment

No protocol flaws were detected. The model checker exhaustively verified all 4,096 reachable states with zero violations across 4 invariants.

The state transition protocol, as specified in the Circom circuit and formalized in TLA+, is **structurally sound**:
- Chained multi-transaction WalkUp produces roots consistent with full tree rebuilds.
- Invalid Merkle proofs are always rejected.
- Enterprise state is isolated.

## 5. Verdict

**PASS.** The TLA+ specification faithfully represents the ChainedBatchStateTransition circuit from the source materials. No hallucinated mechanisms, no critical omissions, no protocol flaws detected.

The specification is ready for downstream consumption by the Prime Architect (Phase 3 is NOT triggered -- no protocol flaws).
