# Basis Network L1

The foundational layer of Basis Network -- a permissioned, near-zero-fee Avalanche L1 (Subnet-EVM) for enterprise blockchain infrastructure in Latin America.

## Components

| Directory | Description | Status |
|-----------|-------------|--------|
| [contracts/](./contracts/) | 7 Solidity smart contracts (Hardhat + TypeScript) | Deployed on Fuji |
| [config/](./config/) | Avalanche L1 genesis and node configuration | Production |
| [dashboard/](./dashboard/) | Network dashboard (Next.js + Tailwind CSS) | [Live](https://dashboard.basisnetwork.com.co) |

## Network Details

| Parameter | Value |
|-----------|-------|
| Chain ID | 43199 |
| EVM Version | Cancun |
| Consensus | Snowman (sub-second finality) |
| Gas Model | Near-zero-fee (minBaseFee: 1 wei) |
| Native Currency | Lithos (LITHOS) / Tomo |
| RPC | `https://rpc.basisnetwork.com.co` |
| Explorer | [explorer.basisnetwork.com.co](https://explorer.basisnetwork.com.co) |

## Smart Contracts

Seven contracts form the on-chain settlement protocol:

**Core:**
- `EnterpriseRegistry.sol` -- Enterprise onboarding, role-based access control
- `TraceabilityRegistry.sol` -- Generic, application-agnostic event recording
- `StateCommitment.sol` -- Per-enterprise state root tracking with delegated ZK verification

**Verification:**
- `ZKVerifier.sol` -- Groth16 zero-knowledge proof verification interface
- `Groth16Verifier.sol` -- snarkjs-generated verifier with verification key baked as constants
- `DACAttestation.sol` -- Data Availability Committee attestation and certification
- `CrossEnterpriseVerifier.sol` -- Inter-enterprise cross-reference verification

## Quick Start

```bash
# Smart contracts
cd contracts && npm install && npx hardhat test

# Dashboard
cd dashboard && npm install && npm run dev
```

See [Deployment Guide](../docs/DEPLOYMENT_GUIDE.md) for full setup instructions.
