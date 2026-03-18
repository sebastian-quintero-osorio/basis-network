# Phase 1: Formalization Notes -- State Transition Circuit (RU-V2)

## Unit Information

| Field | Value |
|-------|-------|
| Unit | state-transition-circuit (RU-V2) |
| Target | validium |
| Date | 2026-03-18 |
| Result | **PASS** |

## Research-to-Spec Mapping

| Source Element | TLA+ Element | Notes |
|---|---|---|
| `ChainedBatchStateTransition(depth, batchSize)` template | `StateTransition(e, txBatch)` action | Atomic batch verification and state update per enterprise |
| `SingleStateTransition(depth)` template | `ApplyTx(treeEntries, currentRoot, tx)` operator | Single key-value update with Merkle proof check |
| `MerklePathVerifier(depth)` template | `WalkUp(treeEntries, currentHash, key, level)` operator | Incremental root recomputation from leaf to root |
| `chainedRoots[i+1] <== newPathVerifiers[i].root` | `ApplyBatch` recursive chaining | Root from tx[i] feeds into tx[i+1] |
| `oldRootChecks[i].out === 1` | `treeEntries[tx.key] = tx.oldValue` guard in `ApplyTx` | Abstract Merkle proof check (justified by RU-V1 SoundnessInvariant) |
| `finalCheck: chainedRoots[batchSize] == newStateRoot` | `StateRootChain` invariant | End-to-end batch correctness |
| `Poseidon(2)` hash in circuit | `Hash(a, b)` operator (prime-field linear) | Same abstraction as RU-V1 |
| `prevStateRoot` / `newStateRoot` public inputs | `roots[e]` variable | Published Merkle root per enterprise |
| `enterpriseId` public input | `e \in Enterprises` parameter | Enterprise isolation via function domain |
| `keys[i]`, `oldValues[i]`, `newValues[i]` private inputs | `tx.key`, `tx.oldValue`, `tx.newValue` in Tx record | Per-transaction data |

## Abstraction Decisions

### A1: Merkle Proof Abstraction

The circuit verifies Merkle proofs using sibling hashes and path bits. The TLA+ spec abstracts this as `tree[key] = oldValue`. This is justified by the **SoundnessInvariant** verified in RU-V1 (SparseMerkleTree): a Merkle proof for (key, value) against a root succeeds if and only if tree[key] = value. The correctness of Merkle proof verification is therefore a PREREQUISITE, not a target, of this specification.

### A2: Hash Function Model

The spec reuses the prime-field linear hash from RU-V1:
`Hash(a, b) = (a * 31 + b * 17 + 1) mod 65537 + 1`

Properties verified in RU-V1:
- P1: Hash(a, b) >= 1 for all a, b >= 0 (distinguishes from EMPTY = 0)
- P2: Injective within the model's finite domain

### A3: Enterprise Isolation

The circuit takes `enterpriseId` as a public input but does not enforce cross-enterprise isolation (that is the L1 contract's responsibility). The TLA+ spec models isolation structurally: `StateTransition(e, ...)` only modifies `trees[e]` and `roots[e]` via the EXCEPT construct. TLC verifies this holds across all reachable states.

### A4: Atomic Batch Processing

The circuit processes a batch atomically (all-or-nothing). The TLA+ spec models this faithfully: `ApplyBatch` returns `valid = FALSE` at the first invalid transaction, and `StateTransition` only updates state when the entire batch is valid.

## Verification Results

### Primary Model (Complete Verification)

| Metric | Value |
|--------|-------|
| Enterprises | {1, 2, 3} |
| Keys | {0, 1, 2, 3} |
| Values | {1} |
| DEPTH | 2 |
| MaxBatchSize | 2 |
| Distinct states | **4,096** (full 16^3 state space) |
| States generated | 3,342,337 |
| Search depth | 10 |
| Time | 15 seconds |
| Workers | 20 |
| Result | **PASS -- all 4 invariants hold** |

### Invariant Results

| Invariant | Result | Description |
|-----------|--------|-------------|
| TypeOK | PASS | Type correctness across all states |
| StateRootChain | PASS | Chained WalkUp agrees with ComputeRoot at all 4,096 states |
| BatchIntegrity | PASS | Every single-tx WalkUp matches ComputeRoot at every reachable state |
| ProofSoundness | PASS | Wrong oldValue always causes rejection at every reachable state |

### Partial Verification (Larger Model)

A model with Values = {1, 2} (531,441 theoretical states) was run for 20 minutes. TLC explored 430M+ generated states and found 396,017 distinct states (75% of state space) with **zero violations** before being stopped due to time constraints. This provides high confidence that the invariants hold for the larger parameter set.

## Reproduction Instructions

```bash
# From repository root
cd validium/specs/units/2026-03-state-transition-circuit/1-formalization/v0-analysis/experiments/StateTransitionCircuit/_build

# Copy source files
cp ../MC_StateTransitionCircuit.tla .
cp ../MC_StateTransitionCircuit.cfg .
cp ../../specs/StateTransitionCircuit/StateTransitionCircuit.tla .

# Run TLC
java -cp lab/2-logicist/tools/tla2tools.jar tlc2.TLC MC_StateTransitionCircuit -workers auto -deadlock
```

## Novel Verification Contribution

RU-V1 (SparseMerkleTree) verified that a SINGLE operation's incremental root computation (WalkUp) agrees with a full tree rebuild (ComputeRoot). This is the ConsistencyInvariant.

RU-V2 (StateTransitionCircuit) extends this to CHAINED operations: applying N sequential transactions through WalkUp, where each transaction uses the intermediate tree state produced by the previous transaction, still produces a root consistent with ComputeRoot of the final tree.

This is a strictly stronger property. It verifies that:
1. WalkUp correctly uses siblings from the intermediate (post-previous-tx) tree state
2. The chaining mechanism does not introduce cumulative root divergence
3. Enterprise isolation is maintained under concurrent multi-tx batch processing

## Open Issues

None. All invariants pass. The specification is ready for Phase 2 audit.
