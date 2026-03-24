# Basis Network -- Contract Deployments

All contracts are deployed on the **Basis Network L1**, an Avalanche Subnet on Fuji testnet.

| Parameter | Value |
|-----------|-------|
| Network | Avalanche Fuji Testnet |
| Chain ID | 43199 |
| RPC | https://rpc.basisnetwork.com.co |
| Token | LITHOS (1 LITHOS = 10^18 Tomos) |
| VM | Subnet-EVM v0.8.0 |
| EVM Target | Cancun |
| Fee Model | Near-zero (minBaseFee: 1 wei) |

---

## L1 Core Contracts

Settlement layer contracts for enterprise registration, traceability, and ZK verification.

| Contract | Address | Description |
|----------|---------|-------------|
| EnterpriseRegistry | `0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5` | Enterprise registration with role-based access control |
| TraceabilityRegistry | `0x0a84C68Fe45d3036Fe66ad219f37963c79140fcb` | Generic event recording for industrial traceability |
| StateCommitment | `0x0FD3874008ed7C1184798Dd555B3D9695771fb5b` | ZK state root management (Groth16 delegated verification) |
| Groth16Verifier | `0xDb1a72Ee390D8d990A267fA85357F78C2b74F2F1` | On-chain Groth16 proof verification (BN254 pairing) |
| ZKVerifier | `0x51B072d47f40ab7aaeD2D7744a17Bf5b53fC916D` | ZK proof routing and verification facade |
| DACAttestation | `0xBa485D9b8b8b132E5eC4d7Bcf5F0B18aD10fCB22` | Data Availability Committee threshold attestations |
| CrossEnterpriseVerifier | `0x188125658E9Bd8D7a026A52052dB9B970d6441A9` | Cross-enterprise zero-knowledge reference verification |

---

## zkEVM L2 Contracts

Enterprise zkEVM Layer 2 settlement contracts with real PLONK-KZG proof verification.

### Proof Verification Stack (Active)

Full E2E pipeline verified on-chain: commit (149K gas) + prove (515K gas) + execute (70K gas) = 735K total.

| Contract | Address | Description |
|----------|---------|-------------|
| Halo2Verifier | `0x53C42dC2E9459CE21A1A321cC51ba92D28E4FAE7` | Generated PLONK-KZG verifier (halo2-solidity-verifier, Keccak256 transcript) |
| Halo2PlonkVerifier | `0x361CBD8714180acF6d2230837893CED779045Db6` | Interface adapter for BasisRollupV2 integration |
| BasisRollupV2 | `0xE5D257e10616B30282b67e0D2367216aC89623B4` | Batch lifecycle: commit, prove (real ZK), execute |

### Supporting Contracts

| Contract | Address | Description |
|----------|---------|-------------|
| BasisVerifier | `0x9393099EbCA963388B73b34f71DAB31fec7E8e49` | Dual verification (Groth16/PLONK) with migration state machine |
| BasisRollup | `0xEb2dc9D540eE016CBF85d3D84b97B756d7a86850` | Groth16 batch lifecycle (legacy) |
| BasisBridge | `0xd0B4BeB95De33d6F49Bcc08fE5ce3b923e263a5b` | L1-L2 asset transfers with escape hatch (24h timeout) |
| BasisDAC | `0x1E0c7C220c75E530E22BC066F8B5a98DeB6dfe9B` | Data availability committee certificate management |
| BasisAggregator | `0xddfe844E347470F45D53bA6FFBA95034F45670a2` | Multi-enterprise proof aggregation (ProtoGalaxy) |
| BasisHub | `0x6Faf689a6Dcb67a633b437774388F0358D882f0B` | Cross-enterprise hub-and-spoke settlement (4-phase protocol) |

---

## Verification

All contract addresses can be verified on-chain via the RPC endpoint:

```bash
# Check contract code exists
curl -s https://rpc.basisnetwork.com.co -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getCode","params":["CONTRACT_ADDRESS","latest"],"id":1}'

# Query BasisRollupV2 state (E2E verified)
curl -s https://rpc.basisnetwork.com.co -X POST \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0xE5D257e10616B30282b67e0D2367216aC89623B4","data":"0x07dbb394"},"latest"],"id":1}'
```
