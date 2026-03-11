# Deployment Guide

Step-by-step guide for deploying Basis Network on Avalanche Fuji Testnet.

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
- **RPC URL:** The URL from step 5
- **Chain ID:** Your chosen chain ID
- **Currency Symbol:** LITHOS
- **Block Explorer URL:** (leave blank or add if configured)

## 7. Deploy Smart Contracts

```bash
cd contracts
cp .env.example .env
# Edit .env with your RPC URL, chain ID, and private key
npm install
npx hardhat compile
npx hardhat run scripts/deploy.ts --network basisFuji
```

The deployment script will output all contract addresses. Save them.

## 8. Configure Dashboard

```bash
cd dashboard
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

## 9. Run the Adapter

```bash
cd adapter
cp .env.example .env
# Edit .env with RPC URL, contract addresses, and private key
npm install
npm run start
```

## 10. Generate and Verify a ZK Proof

```bash
cd prover
npm install
npm run setup     # One-time trusted setup (generates proving/verification keys)
npm run prove     # Generate a Groth16 proof for a sample batch
npm run verify    # Verify the proof locally before on-chain submission
```

---

## Environment Variables Reference

### contracts/.env

```
PRIVATE_KEY=<admin wallet private key>
RPC_URL=<Basis Network RPC URL>
CHAIN_ID=<chain ID>
```

### adapter/.env

```
PRIVATE_KEY=<adapter wallet private key>
RPC_URL=<Basis Network RPC URL>
ENTERPRISE_REGISTRY_ADDRESS=<deployed address>
TRACEABILITY_REGISTRY_ADDRESS=<deployed address>
PLASMA_CONNECTOR_ADDRESS=<deployed address>
TRACE_CONNECTOR_ADDRESS=<deployed address>
PLASMA_API_URL=<PLASMA backend URL>
TRACE_API_URL=<Trace backend URL>
```

### dashboard/.env.local

```
NEXT_PUBLIC_RPC_URL=https://rpc.basisnetwork.com.co
NEXT_PUBLIC_CHAIN_ID=<chain ID>
NEXT_PUBLIC_ENTERPRISE_REGISTRY_ADDRESS=<deployed address>
NEXT_PUBLIC_TRACEABILITY_REGISTRY_ADDRESS=<deployed address>
NEXT_PUBLIC_PLASMA_CONNECTOR_ADDRESS=<deployed address>
NEXT_PUBLIC_TRACE_CONNECTOR_ADDRESS=<deployed address>
NEXT_PUBLIC_ZK_VERIFIER_ADDRESS=<deployed address>
```

---

## Troubleshooting

### "Transaction reverted: not allowlisted"

The sending address is not on the transaction allowlist. The admin must add it via the Subnet-EVM precompile.

### "Contract deployment failed"

Ensure the deploying address is on the contract deployer allowlist.

### Hardhat compilation errors with "invalid opcode"

Ensure `evmVersion: "cancun"` is set in `hardhat.config.ts`. Avalanche does not support Pectra opcodes.
