# Session: State Transition Circuit Implementation

**Date**: 2026-03-18
**Agent**: Prime Architect
**Target**: validium (MVP Enterprise ZK Validium Node)
**Unit**: RU-V2 (State Transition Circuit)
**Specification**: validium/specs/units/2026-03-state-transition-circuit/

---

## What Was Implemented

Production-grade Circom circuit that proves a batch of sequential state transitions
in an enterprise's Sparse Merkle Tree, translating the TLA+ verified specification
into a Groth16 ZK proof system.

The circuit verifies that applying a batch of key-value updates transitions the
enterprise state root from `prevStateRoot` to `newStateRoot`, with each individual
transition backed by a valid Merkle inclusion proof.

---

## Files Created

### Circuit Files
- `validium/circuits/circuits/merkle_proof_verifier.circom` -- Merkle inclusion proof
  verifier using Poseidon 2-to-1 hash. Models TLA+ WalkUp operator.
- `validium/circuits/circuits/state_transition.circom` -- Main StateTransition template.
  Chained batch processing with root verification. Models TLA+ ApplyBatch + StateTransition.

### Script Files
- `validium/circuits/scripts/setup_state_transition.js` -- Groth16 trusted setup
  (Powers of Tau + circuit-specific zkey generation).
- `validium/circuits/scripts/generate_state_transition_input.js` -- Witness input
  generator using circomlibjs Poseidon and an in-memory SMT.

### Adversarial Testing
- `validium/tests/adversarial/state-transition-circuit/ADVERSARIAL-REPORT.md` -- Full
  adversarial report with 6 test scenarios (1 valid, 5 adversarial).

### Build Artifacts (generated, not committed)
- `validium/circuits/build/state_transition/state_transition.r1cs` -- R1CS constraints
- `validium/circuits/build/state_transition/state_transition.sym` -- Symbol table
- `validium/circuits/build/state_transition/state_transition_js/` -- WASM witness generator
- `validium/circuits/build/state_transition/input.json` -- Valid test input
- `validium/circuits/build/state_transition/witness.wtns` -- Valid witness
- `validium/circuits/build/state_transition/input_tampered_*.json` -- Adversarial inputs

---

## Quality Gate Results

### Compilation (depth=10, batch=4)
- R1CS constraints: 45,715
- Non-linear constraints: 21,589
- Linear constraints: 24,126
- Template instances: 78
- Wires: 45,763
- Public inputs: 4
- Private inputs: 52
- Compilation: SUCCESS

### Witness Generation
- Valid input: ACCEPTED (witness generated)
- 5 adversarial inputs: All REJECTED at correct constraint points

### Adversarial Testing
- Verdict: NO SECURITY VIOLATIONS FOUND
- All 3 TLA+ invariants enforced by circuit constraints
- Additional security: Num2Bits key range enforcement

---

## Design Decisions

### 1. Path Bits Derived from Keys (Not Provided as Inputs)

The research prototype accepts `pathBits[batchSize][depth]` as prover inputs.
The production circuit derives them via `Num2Bits(depth)` decomposition of keys.

**Rationale**: Prevents the prover from supplying inconsistent path directions,
adds key range enforcement (key < 2^depth), and reduces witness size by
depth * batchSize field elements. Cost: depth additional constraints per
transaction (negligible).

### 2. Signal Naming Convention

Private inputs use `tx` prefix (`txKeys`, `txOldValues`, `txNewValues`, `txSiblings`)
to distinguish from public inputs and align with the TLA+ `Tx` record type.

### 3. Public Input: batchNum (Not batchSize)

The public signal is named `batchNum` (batch sequence number for on-chain
identification) rather than `batchSize` (which is a template parameter). This
avoids name collision and matches the reference circuit's convention.

---

## Specification Traceability

| Circuit Element | TLA+ Source |
|----------------|-------------|
| `MerkleProofVerifier(depth)` | `WalkUp(treeEntries, currentHash, key, level)` |
| `Poseidon(2)` leaf hashing | `LeafHash(key, value) == Hash(key, value)` |
| `chainedRoots[i+1]` chaining | `ApplyBatch` recursive root chaining |
| `oldRootChecks[i].out === 1` | `ApplyTx` validity check: `treeEntries[tx.key] = tx.oldValue` |
| `finalCheck.out === 1` | `StateRootChain` invariant |
| `Num2Bits(depth)` path derivation | `PathBit(key, level) == (key \div Pow2(level)) % 2` |

---

## Constraint Analysis

| Configuration | Constraints | Per-Tx | Proving Time (est.) |
|--------------|-------------|--------|---------------------|
| depth=10, batch=4 | 45,715 | 11,429 | ~3.4s (snarkjs) |
| depth=10, batch=8 | ~91,430 | 11,429 | ~5s (snarkjs) |
| depth=20, batch=4 | ~87,235 | 21,809 | ~8.7s (snarkjs) |
| depth=32, batch=4 | ~137,103 | 34,276 | ~6.9s (snarkjs) |
| depth=32, batch=16 | ~548,413 | 34,276 | ~25-30s (snarkjs) |

Formula: `~1,038 * (depth+1) * batchSize + depth * batchSize + 3`

---

## Next Steps

1. **Trusted Setup**: Run `node scripts/setup_state_transition.js 16` to generate
   Powers of Tau (pot16) and proving/verification keys for depth=10, batch=4.
2. **End-to-End Proof**: Generate and verify a Groth16 proof with the valid witness.
3. **Solidity Verifier**: Export and integrate with ZKVerifier.sol on the L1.
4. **Production Parameters**: Compile with depth=32 for production capacity
   (requires pot18+, ~137K constraints at batch=4).
5. **Node Integration**: Wire the circuit into the validium node's prover module
   (validium/node/src/prover/).
