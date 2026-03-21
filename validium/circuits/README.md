# ZK Circuits

Circom circuits for the Basis Network ZK validium pipeline. The main circuit (`state_transition.circom`) proves that a batch of sequential state transitions in a Sparse Merkle Tree is valid, without revealing any transaction data.

## Production Circuit

| Parameter | Value |
|-----------|-------|
| Circuit | `state_transition.circom` |
| Template | `StateTransition(depth, batchSize)` |
| Production instance | depth=32, batchSize=8 |
| Constraints | 274,291 |
| Proof system | Groth16 (BN128) |
| Trusted setup | Powers of Tau 2^19 (524K max constraints) |
| Proving key | `state_transition_final.zkey` (127 MB) |
| Proof generation time | 12.9 seconds |
| On-chain verification | 306K gas |

## Public Inputs

- `prevStateRoot` -- Merkle root before the batch
- `newStateRoot` -- Merkle root after the batch
- `batchNum` -- Sequential batch number
- `enterpriseId` -- Enterprise identifier

## Private Inputs (never revealed)

- `txKeys[batchSize]` -- Keys being modified
- `txOldValues[batchSize]` -- Previous values
- `txNewValues[batchSize]` -- New values
- `txSiblings[batchSize][depth]` -- Merkle proof siblings

## Circuit Files

| File | Description |
|------|-------------|
| `circuits/state_transition.circom` | Main circuit (production) |
| `circuits/merkle_proof_verifier.circom` | Merkle path verification template |
| `circuits/batch_verifier.circom` | Legacy circuit (batch=4, 742 constraints) |

## Setup

Requires [Circom](https://github.com/iden3/circom) installed (`cargo install` from source).

```bash
npm install
npm run setup    # Powers of Tau ceremony + Groth16 key generation
npm run prove    # Generate proof for sample batch
npm run verify   # Verify proof locally
```

## Build Artifacts

The `build/` directory contains compiled circuit artifacts:

- `state_transition/` -- R1CS, WASM witness calculator, proving key
- `Groth16Verifier.sol` -- snarkjs-generated Solidity verifier (deployed on L1)
- `production/` -- Verified proof artifacts (proof.json, verification_key.json)
- `calldata.txt` -- Formatted for on-chain submission

## Verified Invariants

- **StateRootChain:** final root equals ComputeRoot of resulting tree
- **BatchIntegrity:** each per-transaction verification agrees with ComputeRoot
- **ProofSoundness:** wrong oldValue always causes circuit unsatisfiability
