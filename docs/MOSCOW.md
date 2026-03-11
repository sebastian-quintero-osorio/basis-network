# MoSCoW Prioritization Framework

## Must Have (MVP fails without these)

| ID | Feature | Component | Status |
|---|---|---|---|
| M1 | Avalanche L1 deployed on Fuji with zero-fee transactions | l1-config | Deployed |
| M2 | EnterpriseRegistry contract with role-based access | contracts | Deployed |
| M3 | TraceabilityRegistry contract for immutable event recording | contracts | Deployed |
| M4 | PLASMAConnector contract for maintenance data | contracts | Deployed |
| M5 | At least one product (PLASMA) writing data on-chain | adapter | Working |
| M6 | Unit tests for all contracts (>85% coverage) | contracts/test | Passing |
| M7 | Demo video showing end-to-end pipeline | submission | Recorded |
| M8 | GitHub repository with source code and README | repo | Complete |

## Should Have (significantly strengthens submission)

| ID | Feature | Component | Status |
|---|---|---|---|
| S1 | TraceConnector contract for commercial data | contracts | Deployed |
| S2 | Trace integration writing sales data on-chain | adapter | Working |
| S3 | ZKVerifier contract with Groth16 proof verification | contracts | Deployed |
| S4 | ZK proof generation PoC (Circom circuit + SnarkJS) | prover | Working |
| S5 | Network dashboard with real-time activity | dashboard | Live |
| S6 | Comprehensive technical documentation | docs | Complete |
| S7 | Deployment scripts for reproducible setup | contracts/scripts | Complete |

## Could Have (differentiators if time permits)

| ID | Feature | Component | Status |
|---|---|---|---|
| C1 | AWM cross-chain communication demo | contracts | Planned |
| C2 | Stress test results (1000+ transactions) | docs | Planned |
| C3 | CI/CD pipeline with GitHub Actions | .github | Complete |
| C4 | Block explorer (Blockscout) | infra | Live |
| C5 | Network monitoring dashboard with real-time data | dashboard | Live |

## Will Not Have (post-competition roadmap)

| ID | Feature | Rationale |
|---|---|---|
| W1 | Mainnet deployment | Requires security audit and production validators |
| W2 | Full ZK rollup (sequencer + prover) | R&D pipeline deliverable, months of work |
| W3 | Chainlink oracle integration | Depends on Chainlink L1 support timeline |
| W4 | Tether WDK stablecoin layer | Requires partnership agreement finalization |
| W5 | HyperSDK custom VM | Long-term evolution, not MVP scope |
| W6 | Multi-language UI (Spanish, Portuguese) | Post-MVP localization |
