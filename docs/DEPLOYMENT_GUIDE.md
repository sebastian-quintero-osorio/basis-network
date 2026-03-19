# Deployment Guide

Step-by-step guide for deploying Basis Network on Avalanche Fuji Testnet.

## Current Deployment

Basis Network is live on Avalanche Fuji Testnet with the following infrastructure:

| Resource | Value |
|---|---|
| Subnet ID | `csFDHeZGWt36nqx3UuLeG6cs6daNUVrFEVGQ2tgoQfKPqPskx` |
| Blockchain ID | `qTRKhytrdbPMCNSVf6Sr5kRxRCyqwLKQCibDzAYLqhKKUvPJX` |
| Chain ID | `43199` |
| RPC | [rpc.basisnetwork.com.co](https://rpc.basisnetwork.com.co) |
| Validator | DigitalOcean droplet (`144.126.220.103`) |
| Node ID | `NodeID-CVmwsLFTjkAzmWp3DJW74z8VYnfqamWsx` |
| Dashboard | [dashboard.basisnetwork.com.co](https://dashboard.basisnetwork.com.co) |
| Explorer | [explorer.basisnetwork.com.co](https://explorer.basisnetwork.com.co) |

The RPC endpoint is proxied via Nginx with SSL (Let's Encrypt) and CORS headers for browser access.

---

## Prerequisites

- Node.js >= 18
- npm >= 9
- Git
- Avalanche CLI ([install instructions below](#1-install-avalanche-cli))
- MetaMask browser extension
- Fuji testnet AVAX (from faucet)

---

## 1. Install Avalanche CLI

```bash
curl -sSfL https://raw.githubusercontent.com/ava-labs/avalanche-cli/main/scripts/install.sh | sh -s
```

Verify installation:
```bash
avalanche --version
```

## 2. Get Fuji Testnet AVAX

1. Go to https://core.app/tools/testnet-faucet
2. Enter your wallet address.
3. Request AVAX on the Fuji C-Chain.
4. You will also need AVAX on the P-Chain for validator staking. Use the Avalanche CLI or Core wallet to transfer from C-Chain to P-Chain.

## 3. Create the Basis Network L1

```bash
avalanche blockchain create basisNetwork
```

When prompted:
- **VM:** Select `Subnet-EVM`
- **Chain ID:** Enter your chosen chain ID (e.g., `43199`)
- **Token Symbol:** `LITHOS`
- **Gas configuration:** Choose custom and set:
  - Gas limit: `15000000`
  - Min base fee: `0`
  - Target gas: `15000000`
  - Base fee change denominator: `48`
  - Min block gas cost: `0`
  - Max block gas cost: `0`
  - Target block rate: `2`
  - Block gas cost step: `50000`
- **Allowlists:** Enable both transaction allowlist and contract deployer allowlist.
- **Admin address:** Enter your admin wallet address.

## 4. Deploy Locally (Test First)

```bash
avalanche blockchain deploy basisNetwork --local
```

The CLI will print the RPC URL. Save it for Hardhat configuration.

Test basic functionality:
```bash
# Check chain ID
curl -X POST --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' \
  -H "Content-Type: application/json" \
  http://127.0.0.1:9650/ext/bc/<BLOCKCHAIN_ID>/rpc
```

## 5. Deploy to Fuji Testnet

```bash
avalanche blockchain deploy basisNetwork --fuji
```

Requirements:
- Your node must be a validator on the Avalanche Primary Network (Fuji).
- You need AVAX on the P-Chain for the validator staking fee.

The CLI will output:
- Blockchain ID
- RPC URL
- Chain ID

Save all of these values.

## 6. Configure MetaMask

Add a custom network in MetaMask:
- **Network Name:** Basis Network (Fuji)
- **RPC URL:** `https://rpc.basisnetwork.com.co`
- **Chain ID:** `43199`
- **Currency Symbol:** LITHOS
- **Block Explorer URL:** `https://explorer.basisnetwork.com.co`

## 7. Deploy Smart Contracts

```bash
cd l1/contracts
cp .env.example .env
# Edit .env with your RPC URL, chain ID, and private key
npm install
npx hardhat compile
npx hardhat run scripts/deploy.ts --network basisFuji
```

The deployment script will output all contract addresses. Save them.

## 8. Configure Dashboard

```bash
cd l1/dashboard
cp .env.example .env.local
# Edit .env.local with RPC URL and contract addresses
npm install
npm run build
npm run start
```

For production deployment on Vercel:
```bash
npx vercel --prod
```

All `NEXT_PUBLIC_*` variables must also be set in the Vercel project settings under Environment Variables (Production scope). Use `printf` when adding values via CLI to avoid trailing newlines:
```bash
printf '<value>' | npx vercel env add NEXT_PUBLIC_RPC_URL production
```

## 9. Run the Adapter

```bash
cd validium/adapters
cp .env.example .env
# Edit .env with RPC URL, contract addresses, and private key
npm install
npm run start
```

## 10. Generate and Verify a ZK Proof

```bash
cd validium/circuits
npm install
npm run setup     # One-time trusted setup (generates proving/verification keys)
npm run prove     # Generate a Groth16 proof for a sample batch
npm run verify    # Verify the proof locally before on-chain submission
```

---

## Environment Variables Reference

### l1/contracts/.env

```
PRIVATE_KEY=<admin wallet private key>
RPC_URL=<Basis Network RPC URL>
CHAIN_ID=<chain ID>
```

### validium/adapters/.env

```
PRIVATE_KEY=<adapter wallet private key>
RPC_URL=<Basis Network RPC URL>
ENTERPRISE_REGISTRY_ADDRESS=<deployed address>
TRACEABILITY_REGISTRY_ADDRESS=<deployed address>
ZK_VERIFIER_ADDRESS=<deployed address>
```

### l1/dashboard/.env.local

```
NEXT_PUBLIC_RPC_URL=https://rpc.basisnetwork.com.co
NEXT_PUBLIC_CHAIN_ID=43199
NEXT_PUBLIC_ENTERPRISE_REGISTRY_ADDRESS=<deployed address>
NEXT_PUBLIC_TRACEABILITY_REGISTRY_ADDRESS=<deployed address>
NEXT_PUBLIC_ZK_VERIFIER_ADDRESS=<deployed address>
NEXT_PUBLIC_STATE_COMMITMENT_ADDRESS=<deployed address>
NEXT_PUBLIC_DAC_ATTESTATION_ADDRESS=<deployed address>
NEXT_PUBLIC_CROSS_ENTERPRISE_VERIFIER_ADDRESS=<deployed address>
```

---

## Troubleshooting

### "Transaction reverted: not allowlisted"

The sending address is not on the transaction allowlist. The admin must add it via the Subnet-EVM precompile.

### "Contract deployment failed"

Ensure the deploying address is on the contract deployer allowlist.

### Hardhat compilation errors with "invalid opcode"

Ensure `evmVersion: "cancun"` is set in `hardhat.config.ts`. Avalanche does not support Pectra opcodes.
