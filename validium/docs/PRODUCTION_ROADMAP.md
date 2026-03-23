# Validium: Complete Production Roadmap

## Current State: ~90%

The core pipeline is verified on-chain (Fuji): 8 txs -> Groth16 proof (10s) -> L1 verification -> state root updated. What follows is every remaining item to reach 100% production readiness for critical enterprise operations.

---

## Phase 1: Immediate Fixes (1-2 days)

### 1.1 BN128 Field Validation on API Input

**Problem:** The REST API accepts transaction keys outside the BN128 scalar field (> 21888242871839275222246405745257275088548364400416034343698204186575808495617). This causes the SMT to crash during batch processing.

**Solution:**
- File: `validium/node/src/api/server.ts`
- Add validation: parse key as BigInt, reject if >= BN128_FIELD_PRIME
- Add constant: `const BN128_FIELD_PRIME = 21888242871839275222246405745257275088548364400416034343698204186575808495617n`
- Return HTTP 400 with error message "key exceeds BN128 field prime"
- Apply same validation to `oldValue` and `newValue`

**Verification:** Send key = BN128_FIELD_PRIME + 1, expect HTTP 400. Send key = BN128_FIELD_PRIME - 1, expect HTTP 202.

### 1.2 Reconcile Circuit v1/v2

**Problem:** Two circuit versions coexist. Production artifacts use v2 (with EMPTY leaf handling) but the canonical file (`circuits/circuits/state_transition.circom`) is still v1.

**Solution:**
- Replace `state_transition.circom` content with `state_transition_v2.circom` content
- Update the production circuit instantiation comment
- Delete `state_transition_v2.circom` (merged into main)
- Update `circuits/README.md` to document the EMPTY leaf handling
- Regenerate Groth16Verifier.sol from the v2 zkey and place in `circuits/build/production/`

**Verification:** `npm test` passes 289 tests. Circuit artifacts match.

### 1.3 Update Dashboard Contract Addresses

**Problem:** Dashboard `.env.local` points to old StateCommitment (0x0FD387...) and old Groth16Verifier. New deployments: StateCommitment v2 (0xD40dAd...), Groth16Verifier v2 (0x054045...).

**Solution:**
- Update `l1/dashboard/.env.local` with new addresses
- Add new Groth16Verifier v2 address to dashboard Modules page
- Verify dashboard displays correct batch count and state root from new contract

### 1.4 Redeploy Groth16Verifier on Old StateCommitment

**Problem:** The original StateCommitment (0x0FD387...) still has the v1 verifier. If we want both to work, need to update it too. Alternatively, migrate fully to the v2 StateCommitment.

**Decision needed:** Full migration to v2 or maintain both. Recommendation: full migration to v2.

---

## Phase 2: Distributed DAC (2-4 weeks)

### 2.1 DAC Node as Standalone Service

**Problem:** DAC nodes are in-process JavaScript objects. No network communication.

**Solution:**
- Create `validium/dac-node/` -- standalone Node.js service
- Transport: gRPC (protobuf) for inter-node communication
  - Service: `DACService { StoreShare, Attest, GetShare, RecoverData }`
  - Proto file: `validium/dac-node/proto/dac.proto`
- Each DAC node runs as a separate process with its own:
  - Private key for ECDSA attestation signing
  - Persistent share storage (LevelDB)
  - Health endpoint
  - Prometheus metrics
- Configuration: committee member list, threshold, enterprise ID

**Files to create:**
- `validium/dac-node/src/server.ts` -- gRPC server
- `validium/dac-node/src/storage.ts` -- LevelDB share storage
- `validium/dac-node/src/attestation.ts` -- ECDSA signing
- `validium/dac-node/proto/dac.proto` -- protobuf definitions
- `validium/dac-node/Dockerfile` -- containerized deployment

### 2.2 Orchestrator DAC Client

**Solution:**
- Replace in-process DAC calls in `orchestrator.ts` with gRPC client calls
- New file: `validium/node/src/da/dac-client.ts` -- gRPC client
- Timeout handling per-node (don't block on slow nodes)
- Fallback: if < threshold nodes respond, trigger on-chain DA fallback

### 2.3 DACAttestation L1 Integration

**Problem:** DAC attestations are collected locally but never submitted to the DACAttestation contract on L1.

**Solution:**
- After collecting threshold attestations, submit aggregate to DACAttestation.sol
- Wire in `orchestrator.ts` after proof generation, before L1 state submission
- Use the deployed DACAttestation contract (0xBa485D9b8b8b132E5eC4d7Bcf5F0B18aD10fCB22)

### 2.4 DAC E2E Test

**Solution:**
- Docker Compose with 3 DAC nodes + 1 validium node
- Send transactions, verify shares are distributed to all 3 nodes
- Kill 1 node, verify recovery from remaining 2 (threshold=2)
- Verify attestation on L1

---

## Phase 3: Security Hardening (1-2 weeks)

### 3.1 Rate Limiting per Enterprise

**Problem:** Current rate limiting is per-IP. Should be per enterprise API key.

**Solution:**
- Modify `api/rate-limiter.ts` to key on enterprise ID (from API key lookup)
- Configurable per-enterprise limits

### 3.2 API Key Rotation

**Solution:**
- Add `POST /v1/admin/rotate-key` endpoint
- Generate new API key, invalidate old one after grace period
- Audit log of key rotations

### 3.3 WAL Encryption at Rest

**Problem:** WAL stores enterprise transaction data in plaintext JSON.

**Solution:**
- Add AES-256-GCM encryption for WAL entries
- Key derived from `WAL_ENCRYPTION_KEY` env var
- Transparent encryption/decryption in WAL read/write paths

### 3.4 TLS for API Server

**Solution:**
- Add TLS certificate configuration to Fastify
- Environment variables: `API_TLS_CERT`, `API_TLS_KEY`
- Redirect HTTP to HTTPS

---

## Phase 4: Operational Readiness (1-2 weeks)

### 4.1 Execute Load Test

- Run `scripts/load-test.ts` against running node
- Scenarios: sustained 10 tx/s for 5 min, burst 100 tx/1s
- Document results: throughput, latency, memory

### 4.2 Execute Crash Recovery Test

- Run `scripts/crash-recovery-test.ts`
- Verify all 3 scenarios pass
- Document results

### 4.3 Cross-Enterprise E2E Test

- Run 2 validium node instances with different enterprise IDs
- Exchange cross-references via CrossEnterpriseVerifier contract
- Verify isolation: enterprise A cannot read enterprise B data

### 4.4 Monitoring Stack

- Docker Compose: Prometheus + Grafana
- Pre-built dashboard for validium metrics
- Alert rules for: queue depth > 100, error state, proof duration > 20s, L1 submission failures

### 4.5 Backup and Restore Procedure

- Automated WAL backup (cron job)
- SMT checkpoint export/import
- Tested restore from backup

---

## Phase 5: Mainnet Preparation (2-4 weeks)

### 5.1 Security Audit

- Third-party audit of StateCommitment.sol, Groth16Verifier.sol
- Third-party audit of validium node (WAL, SMT, prover, submitter)
- Fix all findings

### 5.2 Multi-Validator Setup

- Deploy 3+ validators for Basis Network L1
- Test consensus with validator failures
- Document validator operations

### 5.3 Mainnet Genesis

- Migrate from Fuji testnet to Avalanche mainnet
- Deploy all contracts to mainnet
- Configure production DNS, SSL, monitoring

### 5.4 Enterprise Onboarding Automation

- KYC/KYB verification workflow
- Automated enterprise registration in EnterpriseRegistry
- API key generation and distribution
- Enterprise-specific validium node provisioning

---

## Phase 6: Scale (ongoing)

### 6.1 Persistent SMT (LevelDB/RocksDB)

**Problem:** In-memory SMT caps at ~1M entries (2GB RAM).

**Solution:**
- Replace in-memory Map with LevelDB-backed storage
- Lazy loading of tree nodes
- Cache hot nodes in memory (LRU)

### 6.2 Proof Parallelization

- Multiple batch proving in parallel (current: sequential)
- Worker pool for snarkjs instances
- GPU acceleration (rapidsnark for Groth16)

### 6.3 Binary WAL Format

- Replace JSON-lines with protobuf or MessagePack
- Reduce WAL entry overhead from ~300B to ~50B
- Required for > 10K tx/min throughput

---

## Success Criteria

The validium is 100% production-ready when:
1. E2E pipeline verified on mainnet (not just Fuji)
2. Distributed DAC with 3+ real nodes on separate machines
3. Security audit completed with zero high-severity findings
4. Load tested at 100+ tx/sec sustained for 1 hour
5. Crash recovery verified under realistic conditions
6. Cross-enterprise verification tested with 2+ enterprises
7. Monitoring stack operational with alerting
8. Backup/restore tested and documented
9. 3+ validators operational on mainnet
10. First enterprise onboarded and running production workload
