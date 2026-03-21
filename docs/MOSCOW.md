# MoSCoW Prioritization Framework

## Must Have (MVP fails without these)

| ID | Feature | Component | Status |
|---|---|---|---|
| M1 | Avalanche L1 deployed on Fuji with near-zero-fee transactions | l1/config | Deployed |
| M2 | EnterpriseRegistry contract with role-based access | l1/contracts | Deployed |
| M3 | TraceabilityRegistry contract for immutable event recording | l1/contracts | Deployed |
| M4 | Generic event recording for maintenance data (via TraceabilityRegistry) | l1/contracts | Deployed |
| M5 | At least one product (PLASMA) writing data on-chain | validium/adapters | Working |
| M6 | Unit tests for all contracts (>85% coverage) | l1/contracts/test | 154 tests passing |
| M7 | Demo video showing end-to-end pipeline | submission | Recorded |
| M8 | GitHub repository with source code and README | repo | Complete |

## Should Have (significantly strengthens submission)

| ID | Feature | Component | Status |
|---|---|---|---|
| S1 | Generic event recording for commercial data (via TraceabilityRegistry) | l1/contracts | Deployed |
| S2 | Trace integration writing sales data on-chain | validium/adapters | Working |
| S3 | ZKVerifier contract with Groth16 proof verification | l1/contracts | Deployed |
| S4 | ZK proof generation PoC (Circom circuit + SnarkJS) | validium/circuits | Working |
| S5 | Network dashboard with real-time activity | l1/dashboard | Live (6 pages) |
| S6 | Comprehensive technical documentation | docs | Complete |
| S7 | Deployment scripts for reproducible setup | l1/contracts/scripts | Complete |

## Could Have (differentiators if time permits)

| ID | Feature | Component | Status |
|---|---|---|---|
| C1 | Enterprise ZK Validium Node with E2E pipeline | validium/node | Complete (316 tests) |
| C2 | TLA+ formal specifications (model-checked) | validium/specs | Complete (10.7M states) |
| C3 | Coq formal verification proofs | validium/proofs | Complete (125+ theorems, 0 Admitted) |
| C4 | CI/CD pipeline with GitHub Actions | .github | Complete |
| C5 | Block explorer (Blockscout) | infra | Live |
| C6 | Network monitoring dashboard with Validium page | l1/dashboard | Live |
| C7 | Data Availability Committee with Shamir SSS | validium/node | Complete |
| C8 | Cross-enterprise ZKP verification | validium/node + l1/contracts | Complete |
| C9 | AI-driven R&D pipeline (4 agents) | lab | Operational (28/28 sessions) |
| C10 | zkEVM L2 architecture and contracts | zkl2 | 80% complete (386 tests) |

## Will Not Have (post-competition roadmap)

| ID | Feature | Rationale |
|---|---|---|
| W1 | Mainnet deployment | Requires security audit and production validators |
| W2 | C-Chain bridge (AVAX utility) | Requires mainnet and bridge audit |
| W3 | PLONK migration | Universal setup needed for multi-circuit production |
| W4 | Multi-language UI (Spanish, Portuguese) | Post-MVP localization |
| W5 | Open validator program | Requires token economics finalization |
