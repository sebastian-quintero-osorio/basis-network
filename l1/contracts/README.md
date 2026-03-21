# Basis Network Smart Contracts

[![CI](https://github.com/sebastian-quintero-osorio/basis-network/actions/workflows/ci.yml/badge.svg)](https://github.com/sebastian-quintero-osorio/basis-network/actions/workflows/ci.yml)

Solidity smart contracts for the Basis Network L1 settlement layer. Built with Hardhat and deployed on Avalanche Subnet-EVM (Fuji Testnet).

## Contracts

| Contract | Location | Tests | Purpose |
|----------|----------|-------|---------|
| EnterpriseRegistry | `contracts/core/` | 13 | Enterprise onboarding and permissions |
| TraceabilityRegistry | `contracts/core/` | 16 | Application-agnostic event recording |
| StateCommitment | `contracts/core/` | 38 | Per-enterprise state root tracking |
| ZKVerifier | `contracts/verification/` | 11 | Groth16 ZK proof verification interface |
| Groth16Verifier | `contracts/test/` | -- | snarkjs-generated verifier (VK baked in) |
| DACAttestation | `contracts/verification/` | 22 | Data Availability Committee attestation |
| CrossEnterpriseVerifier | `contracts/verification/` | 18 | Inter-enterprise cross-reference verification |
| **Total** | | **154** | |

## Setup

```bash
npm install
npx hardhat compile    # Compiles all contracts (EVM target: cancun)
npx hardhat test       # Runs 154 tests
npx hardhat coverage   # Generates coverage report
```

## Deployment

```bash
cp .env.example .env   # Configure RPC URL, private key, chain ID
npx hardhat run scripts/deploy.ts --network basisFuji
```

See [Deployment Guide](../../docs/DEPLOYMENT_GUIDE.md) for complete instructions.

## Deployed Addresses (Fuji)

| Contract | Address |
|----------|---------|
| EnterpriseRegistry | `0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5` |
| TraceabilityRegistry | `0x0a84C68Fe45d3036Fe66ad219f37963c79140fcb` |
| ZKVerifier | `0x51B072d47f40ab7aaeD2D7744a17Bf5b53fC916D` |
| Groth16Verifier | `0xEe0149b9E547cfD7e31274EE3DA25DCEd48703a6` |
| StateCommitment | `0x0FD3874008ed7C1184798Dd555B3D9695771fb5b` |
| DACAttestation | `0xBa485D9b8b8b132E5eC4d7Bcf5F0B18aD10fCB22` |
| CrossEnterpriseVerifier | `0x188125658E9Bd8D7a026A52052dB9B970d6441A9` |

## Architecture

All contracts use custom errors for gas-efficient reverts, NatSpec documentation for every public function, and role-based access control tied to `EnterpriseRegistry`. The L1 functions as a **generic settlement layer** -- no application-specific logic exists on-chain.

```
EnterpriseRegistry
    |-- isAuthorized() --> TraceabilityRegistry
    |-- isAuthorized() --> ZKVerifier
    |-- isAuthorized() --> StateCommitment
    |-- isAuthorized() --> DACAttestation
    +-- isAuthorized() --> CrossEnterpriseVerifier
```

## Technical Constraints

- **EVM version must be `cancun`** -- Avalanche does not support Pectra opcodes.
- **Solidity 0.8.24** -- versions >= 0.8.30 default to Pectra.
- **Near-zero gas** -- minBaseFee is 1 wei (never 0; Subnet-EVM rejects baseFee == 0).
