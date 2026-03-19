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

### Deployed Contracts

| Contract | Address | Category |
|---|---|---|
| EnterpriseRegistry | 0xd0D04E29F6E3219fD7169e6aF65c1eeaf287ecd0 | Core |
| TraceabilityRegistry | 0x1FD683eb4661A9828aa205E250FC1528dF45e037 | Core |
| ZKVerifier | 0xAa4A7231c94D66FD338b96192556Cd454Cf015D4 | Verification |
| StateCommitment | 0xe10CCf26c7Cb6CB81b47C8Da72E427628c8a5E09 | Core |
| DACAttestation | 0xAC00F4920665b1eA43F4F7Da7ef3714DE7acf6Fc | Verification |
| CrossEnterpriseVerifier | 0xF486547C8bF764eA4E53a05D745543f8a6973133 | Verification |

### ValidatorManager (Pre-deployed in Genesis)
- Proxy: 0x0Feedc0de0000000000000000000000000000000
- PoA Implementation: 0x0C0DEbA5E0000000000000000000000000000000
- Proxy Admin: 0xa0AffE1234567890ABcDef1234567890ABCdEF34

### Deployer Account
- Address: 0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD
- Initial Balance: 1,000,000 LITHOS

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
