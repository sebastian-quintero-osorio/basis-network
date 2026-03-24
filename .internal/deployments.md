# Basis Network Deployments

## Fuji Deployment v2 (Avalanche Fuji Testnet)

**Subnet ID:** AYdFRP6MsbHq51MnUqmg5o4Eb92jPTgyPvq92dDQULVo9pwAk
**Blockchain ID:** 2VtYqDeZ5RabHM8zA4x94T6DMdzs3svkfcpF7TLEmTpETUTufR
**RPC Endpoint:** https://rpc.basisnetwork.com.co
**Chain ID:** 43199
**Token:** LITHOS (smallest unit: Tomo, 1 LITHOS = 10^18 Tomos)
**VM:** Subnet-EVM v0.8.0
**Validation:** Proof of Authority (ACP-77 continuous fee)
**Fee Config:** minBaseFee: 1 (near-zero fee, effectively free)

### Validator Node
- **Node:** DigitalOcean Droplet (144.126.220.103)
- **NodeID:** NodeID-CVmwsLFTjkAzmWp3DJW74z8VYnfqamWsx
- **Type:** Sovereign (PoA ValidatorManager)

### RPC Proxy (Nginx)
- **Public URL:** https://rpc.basisnetwork.com.co
- Routes to AvalancheGo JSON-RPC on the droplet
- CORS: `Access-Control-Allow-Origin: *`
- SSL via Let's Encrypt

### Deployed L1 Contracts (v3 -- Active)

| Contract | Address | Category |
|---|---|---|
| EnterpriseRegistry | 0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5 | Core |
| TraceabilityRegistry | 0x0a84C68Fe45d3036Fe66ad219f37963c79140fcb | Core |
| ZKVerifier | 0x51B072d47f40ab7aaeD2D7744a17Bf5b53fC916D | Verification |
| Groth16Verifier | 0xEe0149b9E547cfD7e31274EE3DA25DCEd48703a6 | Verification |
| StateCommitment | 0x0FD3874008ed7C1184798Dd555B3D9695771fb5b | Core |
| DACAttestation | 0xBa485D9b8b8b132E5eC4d7Bcf5F0B18aD10fCB22 | Verification |
| CrossEnterpriseVerifier | 0x188125658E9Bd8D7a026A52052dB9B970d6441A9 | Verification |

### ValidatorManager (Pre-deployed in Genesis)
- Proxy: 0x0Feedc0de0000000000000000000000000000000
- PoA Implementation: 0x0C0DEbA5E0000000000000000000000000000000
- Proxy Admin: 0xa0AffE1234567890ABcDef1234567890ABCdEF34

### Deployer Account
- Address: 0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD
- Initial Balance: 1,000,000 LITHOS

### zkEVM L2 Settlement Contracts

#### Active (BasisRollupV2 + PlonkVerifier -- Deployed 2026-03-24)

| Contract | Address | Purpose |
|---|---|---|
| PlonkVerifier | 0xD2F07E9bC02d96C53Da47D166eEAa0d850212F23 | PLONK-KZG proof verification (real SRS from srs_k8.bin) |
| BasisRollupV2 | 0x9DDE6f93182d660c9f18734De29254D811ae859f | State root management + PlonkVerifier integration |

commitBatch verified on-chain (149K gas). proveBatchV2 requires Halo2-generated
Solidity verifier (snark-verifier) to match full PLONK proof format.

#### Supporting Contracts (Deployed 2026-03-24)

| Contract | Address | Purpose |
|---|---|---|
| BasisVerifier | 0x9393099EbCA963388B73b34f71DAB31fec7E8e49 | PLONK/Groth16 dual verification + migration |
| BasisRollup | 0xEb2dc9D540eE016CBF85d3D84b97B756d7a86850 | Groth16 state root management (legacy) |
| BasisBridge | 0xd0B4BeB95De33d6F49Bcc08fE5ce3b923e263a5b | L1-L2 asset transfers + escape hatch |
| BasisDAC | 0x1E0c7C220c75E530E22BC066F8B5a98DeB6dfe9B | Data availability committee attestations |
| BasisAggregator | 0xddfe844E347470F45D53bA6FFBA95034F45670a2 | Multi-enterprise proof aggregation |
| BasisHub | 0x6Faf689a6Dcb67a633b437774388F0358D882f0B | Cross-enterprise hub-and-spoke settlement |

#### Previous (Deprecated)

| Contract | Address | Purpose |
|---|---|---|
| BasisRollupHarness | 0x79279EDe17c8026412cD093876e8871352f18546 | Test harness with mock _verifyProof (2026-03-23) |

### Architecture Notes
- L1 is a generic settlement layer (no application-specific logic)
- PLASMAConnector and TraceConnector were removed (belong in L2)
- TraceabilityRegistry is generic (application-defined event types)
- DACAttestation uses threshold k=2 (matches Shamir (2,3)-SS)

---

## Previous Deployment (DEPRECATED -- chain irrecoverable)

The previous L1 (Subnet ID: csFDHeZGWt36nqx3UuLeG6cs6daNUVrFEVGQ2tgoQfKPqPskx)
was decommissioned on 2026-03-19 due to an irrecoverable baseFee bug.
Root cause: feeManager precompile set minBaseFee to 0, causing Subnet-EVM to
reject all block proposals with "invalid base fee: 0" after the dynamic base fee
decayed to exactly zero during a validator downtime period.
