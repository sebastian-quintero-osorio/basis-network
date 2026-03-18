# zkEVM L2 Architecture

## Overview

The Basis Network zkEVM L2 is a per-enterprise blockchain that provides full EVM compatibility with ZK validity proofs settled on the Basis Network L1 (Avalanche Subnet-EVM).

## System Layers

### Layer 3: Enterprise Applications
- Solidity smart contracts deployed by enterprises on their L2
- Custom business logic (traceability, maintenance, commerce)
- Standard EVM tooling (Hardhat, ethers.js, MetaMask)

### Layer 2: Enterprise Chain (per enterprise)
- Go-based node running modified Geth EVM executor
- Sequencer orders and executes transactions
- Rust prover generates ZK validity proofs
- DAC stores transaction data off-chain

### Layer 1: Basis Network (shared)
- Avalanche Subnet-EVM (Chain ID 43199)
- BasisRollup.sol: state root management and proof verification
- BasisBridge.sol: L1<->L2 asset transfers
- EnterpriseRegistry.sol: enterprise permissions

### Layer 0: Avalanche Primary Network
- Snowman consensus (sub-second finality)
- P-Chain for validator management
- ICM for potential cross-subnet communication

## Component Interaction

```
Enterprise DApp (Solidity on L2)
        |
        | eth_sendTransaction (JSON-RPC)
        v
L2 Sequencer (Go)
        |
        | Execute in EVM, produce state diff
        v
L2 State Database
        |
        | Execution trace + state diff
        v
ZK Prover (Rust)
        |
        | Validity proof (PLONK/Groth16)
        v
L1 BasisRollup.sol (Solidity)
        |
        | Proof verified, state root updated
        v
Avalanche Consensus (Snowman)
```

## Data Flow: Transaction Lifecycle

1. Enterprise user submits tx to L2 JSON-RPC endpoint.
2. L2 sequencer adds tx to mempool, includes in next block.
3. EVM executor processes the block, produces execution trace and state diff.
4. Batch builder aggregates multiple blocks into a provable batch.
5. Witness generator extracts the witness from the execution trace.
6. ZK prover generates a validity proof from the witness.
7. Proof submitter calls BasisRollup.sol on L1 with proof + new state root.
8. L1 verifier contract checks the proof and updates the state root.
9. Transaction is finalized on L1 (sub-second finality on Avalanche).

## Security Model

### Trust Assumptions

| Component | Trust Level | Justification |
|-----------|------------|---------------|
| Avalanche L1 | Trustless | Snowman consensus, decentralized validators |
| ZK Proof | Trustless | Mathematical soundness (cryptographic assumption) |
| Sequencer | Trusted (mitigated) | Enterprise-operated; forced inclusion via L1 |
| Data Availability | Semi-trusted | DAC with honest minority assumption |
| EVM Execution | Trustless | Proved by ZK circuit |

### Escape Hatch

If the L2 sequencer is offline or censoring:
1. User posts forced-inclusion transaction to L1.
2. Sequencer MUST include it in next batch or face penalty.
3. If sequencer remains unresponsive, user can withdraw via Merkle proof of their L2 state.

## Scalability

| Metric | Target |
|--------|--------|
| L2 Block Time | 1-2 seconds |
| L2 TPS | 100-500 (per enterprise chain) |
| Proof Generation | < 5 minutes per batch |
| L1 Verification | ~300K gas (zero-fee on Basis Network) |
| Batch Size | 100-1000 transactions |
