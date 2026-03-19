# Phase 2: Audit Report -- Cross-Enterprise Verification

## Unit Information

- **Unit**: RU-V7 Cross-Enterprise Verification
- **Target**: validium
- **Date**: 2026-03-18
- **Phase**: 2 -- Verify Formalization Integrity
- **Role**: The Auditor
- **Verdict**: **TRUE TO SOURCE**

---

## 1. Audit Scope

### 1.1 Source Materials (0-input/)

| Artifact | Path | Role |
|----------|------|------|
| Research Report | `0-input/REPORT.md` | Primary source: hub-and-spoke model, 3 verification approaches, gas analysis, privacy analysis, circuit design |
| Hypothesis | `0-input/hypothesis.json` | RU-V7 hypothesis: < 2x overhead for cross-enterprise verification, no privacy leakage |
| Benchmark Code | `0-input/code/cross-enterprise-benchmark.ts` | Gas cost models, SMT implementation, cross-reference proof simulation, privacy tests |
| Benchmark Results | `0-input/code/results/benchmark-results.json` | Measured results: 806,737 gas (sequential), 365,042 gas (batched), 663,540 gas (hub) |

### 1.2 Formalization Artifacts (v0-analysis/)

| Artifact | Path | Role |
|----------|------|------|
| TLA+ Specification | `specs/CrossEnterprise/CrossEnterprise.tla` | 251-line specification, 4 variables, 6 actions, 4 invariants, 1 liveness property |
| Model Instance | `experiments/CrossEnterprise/MC_CrossEnterprise.tla` | 2 enterprises, 2 batches, 3 state roots, 1-active-cross-ref constraint |
| TLC Configuration | `experiments/CrossEnterprise/MC_CrossEnterprise.cfg` | 4 invariants (TypeOK, Isolation, Consistency, NoCrossRefSelfLoop) |
| TLC Log | `experiments/CrossEnterprise/MC_CrossEnterprise.log` | PASS: 461,529 states, 54,009 distinct, depth 11, 2s |
| Phase 1 Notes | `PHASE-1-FORMALIZATION_NOTES.md` | Mapping tables, assumptions, open issues |

---

## 2. Structural Mapping Analysis

### 2.1 State Variable Mapping

| Source (0-input) | Source Location | TLA+ Variable | TLA+ Type | Match? |
|-----------------|-----------------|---------------|-----------|--------|
| Enterprise state root (per-enterprise Merkle root) | REPORT.md "Cross-Reference Circuit Design": `stateRootA`, `stateRootB`; benchmark.ts: `EnterpriseState.stateRoot` | `currentRoot` | `[Enterprises -> StateRoots]` | EXACT |
| Batch lifecycle (submit -> verify) | REPORT.md "Sequential Verification" baseline; "Groth16 Individual Verification Cost" (205,600 gas) | `batchStatus` | `[Enterprises -> [BatchIds -> {"idle","submitted","verified"}]]` | DERIVED |
| State root claimed by batch | REPORT.md "Groth16 Individual Verification Cost": batch root on L1; benchmark.ts: `enterpriseSubmissionGas()` models root storage | `batchNewRoot` | `[Enterprises -> [BatchIds -> StateRoots]]` | DERIVED |
| Cross-reference lifecycle | REPORT.md "Cross-Reference Circuit Design": cross-ref proof is generated and verified; benchmark.ts: `CrossReferenceProof` interface | `crossRefStatus` | `[CrossRefIds -> {"none","pending","verified","rejected"}]` | ENRICHED |
| Interaction commitment (Poseidon hash) | REPORT.md "Public Inputs": `interactionCommitment = Poseidon(keyA, valueA_field, keyB, valueB_field)`; benchmark.ts: `generateCrossReferenceWitness()` line 354 | Not modeled | N/A | ABSTRACTED |
| Merkle proofs (siblings, pathBits, key, value) | REPORT.md "Private Inputs": keyA, valueA, siblingsA[32], pathBitsA[32]; benchmark.ts: `MerkleProof` interface | Not modeled | N/A | ABSTRACTED |
| Gas cost per approach | REPORT.md gas tables throughout; benchmark.ts: `sequentialVerificationGas()`, `batchedPairingGas()`, `hubAggregationGas()` | Not modeled | N/A | ABSTRACTED |
| Constraint count (68,868) | REPORT.md "Constraint Analysis"; benchmark.ts: `analyzeConstraints()` | Not modeled | N/A | ABSTRACTED |

**Variable Count**: 4 TLA+ variables. All map to protocol-level state concepts from the source.
No specification-level tracking variables were needed (unlike RU-V5, which required `dataExposed`,
`pending`, and `crashCount`). The simpler variable set reflects the protocol's narrower scope:
cross-enterprise verification is a coordination protocol, not a full node lifecycle.

**Abstraction Assessment**:

- `StateRoots` as opaque finite domain: Sound. Each state root in the source is a Poseidon-based
  Merkle root (256-bit hash). The TLA+ abstracts this as a finite set `{R0, R1, R2}`. Preserves
  the protocol property that state roots are distinct identifiers. Collision-freeness of Poseidon
  (128-bit security) is a cryptographic assumption outside TLA+ scope.

- `crossRefStatus` lifecycle (`none -> pending -> verified|rejected`): Sound enrichment. The source
  describes a two-phase process (request cross-reference proof, verify it on L1) without explicitly
  naming lifecycle states. The TLA+ derives a lifecycle state machine that captures the source's
  workflow. The `rejected` state is an adversarial addition for protocol completeness.

- Cryptographic abstractions (commitment, Merkle proofs, gas): Sound omissions. The TLA+ verifies
  protocol-level coordination properties (Isolation, Consistency). Cryptographic soundness (Groth16
  ZK property, Poseidon collision resistance) and economic properties (gas costs) are orthogonal
  concerns. The Prover formalizes cryptographic guarantees in Coq; gas analysis is complete in the
  benchmark results.

### 2.2 State Transition Mapping

| # | Source Function/Concept | Source Location | Guards (Source) | TLA+ Action | Guards (TLA+) | Match? |
|---|------------------------|-----------------|-----------------|-------------|---------------|--------|
| 1 | Enterprise batch submission | REPORT.md "Sequential Verification": enterprise submits batch with new state root; "Groth16 Individual Verification Cost": 285,756 gas per submission | Enterprise registered, batch is new | `SubmitBatch(e, b, r)` | `batchStatus[e][b] = "idle"`, `r # currentRoot[e]` | EXACT |
| 2 | Groth16 proof verification (success) | REPORT.md "Groth16 Individual Verification Cost": 205,600 gas; benchmark.ts `groth16VerificationGas()` | Proof submitted on L1 | `VerifyBatch(e, b)` | `batchStatus[e][b] = "submitted"` | EXACT |
| 3 | Groth16 proof failure | Implicit in adversarial model; proofs can be invalid | Proof submitted on L1 | `FailBatch(e, b)` | `batchStatus[e][b] = "submitted"` | ADDED |
| 4 | Cross-reference request | REPORT.md "Cross-Reference Circuit Design": cross-ref proof requires state from both enterprises; benchmark.ts `generateCrossReferenceWitness()` | Both enterprises have committed state | `RequestCrossRef(s, d, sb, db)` | `crossRefStatus = "none"`, both batches in `{"submitted","verified"}` | ENRICHED |
| 5 | Cross-reference verification | REPORT.md "Cross-Reference Circuit Design" + "Privacy Analysis": verifies Merkle inclusion in both trees + interaction commitment; public inputs = stateRootA, stateRootB, commitment | Both individual proofs verified on L1 | `VerifyCrossRef(s, d, sb, db)` | `crossRefStatus = "pending"`, both batches `"verified"` | EXACT |
| 6 | Cross-reference rejection | Implicit in adversarial model; pending cross-ref must resolve when constituent proof fails | At least one constituent proof not verified | `RejectCrossRef(s, d, sb, db)` | `crossRefStatus = "pending"`, at least one batch not `"verified"` | ADDED |

**Transition Count**: Source describes 2 explicit transitions (batch submission, cross-reference
verification) and 1 implicit transition (batch verification as prerequisite). TLA+ defines 6
actions: 3 for the individual enterprise batch lifecycle (SubmitBatch, VerifyBatch, FailBatch)
and 3 for the cross-enterprise lifecycle (RequestCrossRef, VerifyCrossRef, RejectCrossRef).

**Match Summary**:
- **EXACT**: 3 actions map directly to source concepts with equivalent guards and effects.
- **ENRICHED**: 1 action (RequestCrossRef) refines the source by introducing a staging step
  before verification, allowing the protocol to accept cross-reference requests before both
  proofs are verified.
- **ADDED**: 2 actions (FailBatch, RejectCrossRef) model adversarial failure paths not
  explicitly described in the source but necessary for protocol completeness. Phase 1 notes
  correctly document these as "Derived from adversarial model" and "Derived from failure path."

### 2.3 Control Flow Mapping

The source (REPORT.md + benchmark.ts) describes the following workflow:

```
Enterprise A: insert into SMT -> batch -> generate Groth16 proof -> submit to L1 -> verify
Enterprise B: insert into SMT -> batch -> generate Groth16 proof -> submit to L1 -> verify
Cross-Reference: generate Merkle proofs from both trees -> compute commitment ->
                  generate cross-ref Groth16 proof -> submit to L1 -> verify
```

**TLA+ action correspondence**:

| Source Step | TLA+ Action(s) | Notes |
|-----------|----------------|-------|
| Enterprise inserts into SMT + batches | `SubmitBatch` (claims new root) | SMT operations abstracted; TLA+ models the root claim directly |
| Enterprise proof verified on L1 | `VerifyBatch` | State root advances to claimed root |
| Enterprise proof rejected | `FailBatch` | Batch reverts to idle (adversarial path) |
| Cross-reference proof requested | `RequestCrossRef` | Staging step; requires both batches active |
| Cross-reference proof verified on L1 | `VerifyCrossRef` | Consistency gate: both individual proofs must be verified |
| Cross-reference proof rejected | `RejectCrossRef` | Resolution when constituent proof fails |

**Critical atomicity observation**: Each TLA+ action is atomic. In the production system, each
action corresponds to an EVM transaction (also atomic). The atomicity model is EXACT -- no
over-approximation or under-approximation of interleaving.

---

## 3. Discrepancy Detection

### 3.1 Hallucination Check

**Question**: Did the specification introduce mechanisms, transitions, or state not present
in the source materials?

| TLA+ Element | Present in Source? | Justification |
|-------------|-------------------|---------------|
| `FailBatch` action | No explicit description. REPORT.md focuses on successful verification. | NOT A HALLUCINATION. Standard adversarial modeling. ZK proofs CAN fail verification (invalid witness, corrupted proof, circuit mismatch). Modeling failure paths is required for a complete formal specification. The absence of explicit failure handling in the source is a documentation gap, not an intent to exclude failures. Phase 1 notes correctly tag this as "Derived from adversarial model." |
| `RejectCrossRef` action | No explicit description. Source assumes cross-references succeed when both proofs are valid. | NOT A HALLUCINATION. Necessary protocol completion. If a constituent batch proof fails (via FailBatch), pending cross-references against it must be resolved. Without RejectCrossRef, pending cross-references would remain in "pending" state indefinitely -- a liveness violation. Phase 1 notes correctly tag this as "Derived from failure path." |
| `crossRefStatus` "rejected" state | Not in source. Source describes only successful cross-reference verification. | NOT A HALLUCINATION. Direct consequence of RejectCrossRef action. The "rejected" terminal state allows the protocol to distinguish between unresolved ("pending") and resolved-negatively ("rejected") cross-references. |
| `CrossRefIds` as set of records | Source describes ordered pairs (Enterprise A, Enterprise B). | NOT A HALLUCINATION. Direct formalization. The record structure `[src, dst, srcBatch, dstBatch]` captures the source's concept of cross-enterprise interactions with structural self-loop exclusion (`src # dst`). The inclusion of batch identifiers is correct: the source's cross-reference circuit binds to specific state roots, which are batch-specific. |
| Batch slot reuse (idle -> submitted cycle after failure) | Source uses unique monotonic batch IDs. | NOT A HALLUCINATION but a DOCUMENTED MODELING ABSTRACTION. Phase 1 notes Section 3 (Assumption 3) explicitly documents this: "Batch identifiers are modeled as reusable slots [...] for state space tractability." Production uniqueness is preserved by the Architect's implementation. The TLA+ model is correct under the assumption that slots represent unique submissions within a protocol epoch. |
| `newRoot # currentRoot[enterprise]` guard on SubmitBatch | Not explicitly stated in source. | NOT A HALLUCINATION. Sound restriction. A batch claiming the SAME state root as the current root is a no-op (trivial transition). Excluding it prevents TLC from exploring meaningless states. In the production system, batch roots are computed from transaction application on the SMT, which produces a different root whenever transactions are applied. |

**Result**: **ZERO hallucinations detected.** All TLA+ elements trace to source materials or
are justified adversarial extensions with documented rationale.

### 3.2 Omission Check

**Question**: Did the specification miss critical behavior, state transitions, or failure
modes present in the source materials?

| Source Element | Modeled? | Assessment |
|---------------|----------|------------|
| Three verification approaches (Sequential, Batched Pairing, Hub Aggregation) | No | **JUSTIFIED OMISSION.** REPORT.md evaluates three gas-cost models for cross-enterprise verification. These are IMPLEMENTATION STRATEGIES, not protocol-level state transitions. All three approaches must satisfy the same correctness properties (Isolation, Consistency). The TLA+ specification verifies these properties independent of the gas model. The Architect selects the implementation approach; the Logicist verifies the protocol contract. |
| Gas cost analysis (205,600, 285,756, 806,737 gas) | No | **JUSTIFIED OMISSION.** Gas costs are economic/performance metrics measured by the benchmark. TLA+ verifies logical correctness, not resource consumption. Phase 1 notes Section 3 (Assumption 5) documents this. |
| Interaction commitment (Poseidon hash of keyA, leafHashA, keyB, leafHashB) | No | **JUSTIFIED ABSTRACTION.** The interaction commitment is a cryptographic binding inside the ZK circuit. Its correctness depends on Poseidon collision resistance (128-bit) and Groth16 soundness -- cryptographic assumptions outside TLA+ scope. The TLA+ models the protocol-level property: a verified cross-reference implies both constituent proofs are verified (Consistency invariant). The commitment's role as a binding mechanism is captured by this implication. |
| Privacy leakage (1 bit per interaction: existence only) | No | **JUSTIFIED OMISSION.** Information-theoretic privacy is a property of the ZK proof system, not the coordination protocol. The TLA+ verifies Isolation (no state contamination between enterprises). The information-theoretic guarantee (no private data leakage via ZK proofs) is a Groth16/Poseidon property formalized by the Prover in Coq. |
| Merkle proof structure (siblings, pathBits, depth 32) | No | **JUSTIFIED ABSTRACTION.** Merkle proofs are internal circuit witnesses. The TLA+ abstracts the Merkle tree as a state root (opaque value). This is consistent with RU-V1 (sparse-merkle-tree specification), which separately formalizes Merkle tree correctness. |
| Hub coordinator role | No | **JUSTIFIED OMISSION.** REPORT.md mentions "a hub coordinator that collects proofs from multiple enterprises and submits them together" for the Batched Pairing approach. This is an operational role in the implementation architecture, not a protocol-level state variable. The coordinator's behavior is subsumed by the SubmitBatch + VerifyCrossRef action sequence. |
| Constraint count (68,868) and proving time (4,476ms snarkjs, 448ms rapidsnark) | No | **JUSTIFIED OMISSION.** Circuit complexity and proving time are performance metrics. TLA+ verifies protocol correctness independent of circuit size. |
| Dense interaction graphs (interactions >> enterprises) | Partially | **JUSTIFIED SIMPLIFICATION.** REPORT.md identifies that sequential verification exceeds 2x overhead when interactions vastly exceed enterprise count. The TLA+ `MC_Constraint` limits exploration to 1 active cross-reference. The Consistency invariant holds regardless of interaction density -- it is a per-cross-reference property, not an aggregate property. Dense interaction performance is an Architect concern. |
| Groth16 vs PLONK evaluation | No | **JUSTIFIED OMISSION.** Proof system selection is a technology decision, not a protocol state machine. The TLA+ is proof-system-agnostic: it models "proof verified" and "proof failed" without binding to Groth16 or PLONK semantics. |
| Scaling analysis (2-50 enterprises) | No | **JUSTIFIED OMISSION.** The model checks with 2 enterprises, which exercises the fundamental protocol mechanics (bilateral cross-reference). Scaling to N enterprises does not introduce new STATE TRANSITIONS -- the same 6 actions apply. It introduces new CONCURRENT COMBINATIONS, but the invariants (Isolation, Consistency) are per-entity/per-cross-ref properties that compose linearly. |

**Result**: **No harmful omissions detected.** All omissions are justified by scope boundaries
(protocol correctness vs cryptographic soundness vs economic analysis) or conservative abstraction
choices. The specification models the complete cross-enterprise coordination protocol: batch
lifecycle, cross-reference lifecycle, and their interaction constraints.

### 3.3 Semantic Drift Check

**Question**: Does the specification subtly differ in semantics from the source, even where
the structure appears to match?

| Area | Source Semantics | TLA+ Semantics | Drift? | Assessment |
|------|-----------------|----------------|--------|------------|
| **RequestCrossRef allows "submitted" batches** | REPORT.md "Cross-Reference Circuit Design" states public inputs are `stateRootA` and `stateRootB` which are "already public on L1" -- implying roots must be verified (published on L1) before cross-referencing. | `RequestCrossRef` guard allows `batchStatus[src][srcBatch] \in {"submitted", "verified"}`. A cross-reference can be REQUESTED before both proofs are verified. | YES (conservative) | **SOUND OVER-APPROXIMATION.** The TLA+ separates REQUEST (staging) from VERIFICATION (execution). The critical gate is `VerifyCrossRef`, which requires `batchStatus = "verified"` for BOTH enterprises. Allowing early requests explores more states (a request can be made and then rejected if a constituent proof fails). This is strictly more permissive than the source, which implies a tighter request-time guard. The Consistency invariant is unaffected: it constrains the VERIFIED state, not the PENDING state. The Architect may choose to enforce a tighter guard at request time as an optimization. |
| **SubmitBatch newRoot guard** | Source does not explicitly require `newRoot # currentRoot[enterprise]`. Benchmark.ts `enterpriseSubmissionGas()` does not check root distinctness. | TLA+ enforces `newRoot # currentRoot[enterprise]`. | YES (restrictive) | **SOUND RESTRICTION.** In the production system, applying transactions to an SMT always produces a distinct root (collision-freeness of Poseidon). The TLA+ guard reflects this physical reality. The restriction reduces the state space without excluding reachable states. If an enterprise could submit a batch with the same root (a no-op), it would be a degenerate case with no protocol impact. |
| **CrossRefIds directionality** | REPORT.md example: "Enterprise A sells to Enterprise B" -- directional. Benchmark: `enterpriseA -> enterpriseB` in `generateCrossReferenceWitness()`. | `CrossRefIds` includes both `[src=E1, dst=E2, ...]` and `[src=E2, dst=E1, ...]`. | NO | **CORRECT.** The source's circuit design has asymmetric private inputs (keyA, valueA vs keyB, valueB). A cross-reference from A to B is cryptographically distinct from B to A (different commitment values). The bidirectional CrossRefIds is faithful. |
| **Batch slot reuse after failure** | Source uses unique monotonic batch IDs. After failure, a new batch ID is used. | TLA+ allows FailBatch to reset a slot to "idle", then resubmit with a different `newRoot`. The cross-reference may have been requested against the OLD submission. | YES (modeling artifact) | **DOCUMENTED LIMITATION.** Phase 1 notes open issue #1 identifies this precisely: "If a batch slot is resubmitted after a cross-reference was requested against it, the cross-reference may reference stale state." This is a consequence of finite-model-checking with reusable batch slots. The Consistency invariant still holds (both batches must be "verified"), but the verified root may differ from the root at request time. In the production system with unique batch IDs, this scenario cannot occur. The limitation does not weaken any invariant -- it broadens the verification scope by testing a scenario that is impossible in production. |
| **Isolation invariant formulation** | REPORT.md "Privacy Analysis": "The cross-reference proof reveals only that an interaction EXISTS between two enterprises. No data content is leaked." | `Isolation` checks that `currentRoot[e]` is either GenesisRoot or matches some verified batch's claimed root. Does not directly encode information-theoretic privacy. | NO | **CORRECT SCOPE.** The TLA+ Isolation invariant captures STATE INDEPENDENCE: no cross-enterprise action modifies another enterprise's root. This is verified structurally by the UNCHANGED clauses on all cross-enterprise actions (RequestCrossRef, VerifyCrossRef, RejectCrossRef all have `UNCHANGED << currentRoot, batchStatus, batchNewRoot >>`). The information-theoretic guarantee (zero data leakage) is a ZK proof property, verified by the UNCHANGED clauses at the protocol level and by Groth16 soundness at the cryptographic level. |
| **Verified batch permanence** | Source: once an enterprise proof is verified on L1, the state root is committed on-chain. Irreversible. | TLA+ has no action that transitions a "verified" batch back to any other state. Once verified, batch status is permanent. | NO | **EXACT MATCH.** Both source and spec agree: L1 verification is final. The only mutable transitions are from "idle" (SubmitBatch) and from "submitted" (VerifyBatch, FailBatch). |

**Result**: **Two instances of conservative semantic drift detected, one restrictive.** The
RequestCrossRef over-approximation and SubmitBatch restriction are both sound. The batch slot
reuse artifact is a documented modeling limitation that does not weaken any invariant. No drift
introduces false confidence.

---

## 4. Invariant Completeness Assessment

### 4.1 Source Invariants vs TLA+ Properties

| Source Requirement | Source Location | TLA+ Property | Faithfulness |
|-------------------|-----------------|---------------|-------------|
| Enterprise state isolation: "proof from A reveals nothing about B" | REPORT.md Recommendations (Prover task); "Privacy Analysis": ZK guarantee | `Isolation` | FAITHFUL. The invariant `\A e : currentRoot[e] = GenesisRoot \/ \E b : batchStatus[e][b] = "verified" /\ batchNewRoot[e][b] = currentRoot[e]` guarantees that each enterprise's root is determined SOLELY by its own verified batches. Cross-enterprise actions cannot modify enterprise state (enforced by UNCHANGED clauses). This captures state-level isolation. Information-theoretic isolation (ZK property) is out of scope. |
| Cross-reference consistency: "valid only if both proofs valid" | REPORT.md Recommendations | `Consistency` | FAITHFUL. The invariant `crossRefStatus[ref] = "verified" => batchStatus[ref.src][ref.srcBatch] = "verified" /\ batchStatus[ref.dst][ref.dstBatch] = "verified"` directly encodes the source requirement. Every verified cross-reference implies both constituent proofs are independently verified on L1. |
| No self-referencing | Structural: an enterprise cannot cross-reference itself | `NoCrossRefSelfLoop` | FAITHFUL. Enforced structurally by the `CrossRefIds` definition (`r.src # r.dst`). The invariant confirms this holds in all reachable states. |
| Cross-reference resolution (liveness) | Implicit: pending cross-references should eventually resolve | `CrossRefTermination` | FAITHFUL. `crossRefStatus[ref] = "pending" ~> crossRefStatus[ref] \in {"verified", "rejected"}` encodes eventual resolution under fairness. Not yet model-checked (Phase 1 open issue #2). The property is correctly formulated: under weak fairness on VerifyBatch, FailBatch, VerifyCrossRef, and RejectCrossRef, every pending cross-ref eventually resolves. |
| Type safety | Standard | `TypeOK` | STANDARD. All 4 variables inhabit their declared domains in all reachable states. |

**Assessment**: All source requirements are faithfully represented. The liveness property is
defined but not yet model-checked -- this is documented and does not affect the safety verdict.
No source requirement was weakened or omitted.

### 4.2 Fairness Assessment

| TLA+ Fairness | Source Justification | Assessment |
|---------------|---------------------|------------|
| `WF_vars(VerifyBatch(e, b))` | L1 verifier contract always eventually processes submitted proofs | Correct. Weak fairness: if a batch is permanently submitted, it will eventually be verified. |
| `WF_vars(FailBatch(e, b))` | Adversarial: proofs that fail must eventually resolve | Correct. Weak fairness: if verification is continuously attempted and fails, it eventually produces FailBatch. |
| `WF_vars(VerifyCrossRef(s, d, sb, db))` | L1 verifier processes cross-reference proofs | Correct. Weak fairness: if both constituent proofs are verified and a cross-ref is pending, it eventually gets verified. |
| `WF_vars(RejectCrossRef(s, d, sb, db))` | Protocol resolution: stale cross-references must clear | Correct. Weak fairness: if a constituent proof is not verified, pending cross-ref eventually rejects. |
| No fairness on SubmitBatch | Enterprise decision to submit batches is voluntary | Correct. Batch submission is an environment action. |
| No fairness on RequestCrossRef | Cross-reference requests are voluntary | Correct. Cross-reference initiation is an environment action. |

**Assessment**: Fairness constraints are correctly calibrated. Weak fairness on verification
and resolution actions ensures liveness. No fairness on voluntary enterprise actions. The
distinction between system-guaranteed actions (verification, resolution) and voluntary actions
(submission, request) is correct.

---

## 5. Model Configuration Assessment

| Parameter | Value | Source Justification | Adequacy |
|-----------|-------|---------------------|----------|
| `Enterprises` | `{E1, E2}` | Source primary scenario: 2 enterprises, 1 interaction | ADEQUATE. Exercises bilateral cross-reference, the fundamental protocol mechanic. Source scaling analysis (2-50 enterprises) is a performance concern, not a structural concern -- the same 6 actions apply at any scale. |
| `BatchIds` | `{B1, B2}` | 2 batches per enterprise allows multi-batch scenarios | ADEQUATE. Exercises: (a) submit B1, verify B1, then submit B2 (sequential batches); (b) submit B1 and B2 concurrently; (c) fail B1, resubmit, verify. |
| `StateRoots` | `{R0, R1, R2}` | 3 roots: genesis + 2 distinct non-genesis | ADEQUATE. Allows each enterprise to advance through 2 distinct state transitions. Sufficient to verify that roots advance correctly and independently. |
| `GenesisRoot` | `R0` | All enterprises start with same genesis root | CORRECT. Source: all enterprises begin with genesis state root. |
| `MC_Constraint` | At most 1 active cross-reference | Source primary scenario: 1 interaction | ADEQUATE. Reduces state space from exponential (all cross-ref combinations) to linear. The Consistency invariant is per-cross-reference, so verifying it for 1 active cross-ref at a time is sufficient. The constraint still allows TLC to explore all 8 possible cross-reference IDs (2 enterprises x 2 batches x 2 directions) -- it just limits concurrency. |
| State space | 54,009 distinct states, depth 11 | Complete exploration (0 states on queue) | ADEQUATE. Exhaustive search covers all reachable states. Fingerprint collision probability < 1.2E-9. |

**Assessment**: Model parameters are well-chosen for the protocol's scope. The 2-enterprise
model exercises the complete cross-enterprise coordination protocol. The 1-active-cross-ref
constraint is a proportionate state space reduction that does not exclude structurally novel
behaviors.

---

## 6. Findings Summary

### 6.1 No Required Corrections

The formalization faithfully represents the source materials. No corrections are required
for the v0-analysis specification to serve as a valid contract for downstream agents.

### 6.2 Observations (Non-Blocking)

| # | Category | Observation | Impact | Recommendation |
|---|----------|-------------|--------|----------------|
| O-1 | Over-approximation | `RequestCrossRef` allows cross-references when constituent batches are "submitted" (not yet verified). Source implies roots must be public (verified) before cross-referencing. | None (Consistency gate at VerifyCrossRef ensures safety). | The Architect MAY enforce a tighter guard at request time (require both batches "verified" before accepting cross-reference requests). This is an optimization, not a correctness requirement. |
| O-2 | Restriction | `SubmitBatch` guard `newRoot # currentRoot[enterprise]` excludes trivial (same-root) submissions. Source does not explicitly require this. | None (Poseidon collision-freeness makes same-root submissions physically impossible). | No action required. The guard reflects physical reality. |
| O-3 | Modeling artifact | Batch slot reuse after FailBatch can cause a cross-reference to reference a different root than the one present at request time. Phase 1 open issue #1. | None in production (unique batch IDs prevent this). Broadens TLC verification scope (tests an impossible scenario). | The Architect MUST use unique monotonic batch identifiers in the implementation. The TLA+ model's reusable slots are a finite-state abstraction. |
| O-4 | Deferred verification | Liveness property `CrossRefTermination` is defined but not model-checked. Phase 1 open issue #2. | Low. The safety properties (Isolation, Consistency) are verified. Liveness is expected to hold under the specified fairness conditions. | The Logicist SHOULD run TLC with `SPECIFICATION LiveSpec` and `PROPERTIES CrossRefTermination` to complete liveness verification. Not blocking for Architect handoff. |
| O-5 | Scope | Dense interaction graphs (interactions >> enterprises) are not specifically modeled. Source identifies sequential verification exceeds 2x overhead in this regime. | None for correctness (Consistency invariant is per-cross-ref). Performance concern for implementation. | The Architect MUST implement batched pairing verification for dense interaction scenarios (source recommendation). |

---

## 7. Verdict

### **TRUE TO SOURCE**

The TLA+ specification `CrossEnterprise.tla` is a faithful formalization of the RU-V7
Cross-Enterprise Verification research materials. The audit confirms:

1. **State completeness**: All 4 TLA+ variables trace to source protocol concepts. Cryptographic
   primitives (Poseidon hash, Merkle proofs, Groth16 pairing equations) are correctly abstracted
   as opaque operations. No specification-level tracking variables were needed.

2. **Transition completeness**: Source describes 2 explicit transitions (batch submission,
   cross-reference verification) and 1 implicit prerequisite (batch verification). TLA+ defines
   6 actions: 3 exact mappings + 1 enrichment (RequestCrossRef staging) + 2 adversarial additions
   (FailBatch, RejectCrossRef). All additions are justified and documented.

3. **Invariant faithfulness**: All source requirements (Isolation, Consistency, no self-reference)
   are directly encoded as TLA+ invariants. The liveness property (CrossRefTermination) correctly
   formalizes eventual resolution under fairness. No invariant was weakened.

4. **Semantic integrity**: Two instances of conservative semantic drift (RequestCrossRef
   over-approximation, SubmitBatch restriction) and one documented modeling artifact (batch slot
   reuse). All are sound and do not introduce false confidence. No drift weakens any invariant.

5. **Zero hallucinations**: Every TLA+ element traces to a source artifact or is a justified
   adversarial extension with explicit documentation in Phase 1 notes.

The specification is ready to serve as the contract for the Prime Architect (implementation
of CrossEnterpriseVerifier.sol with batched pairing verification) and the Prover (Coq
certification of Isolation and Consistency properties).

---

## Appendix A: Traceability Matrix

| TLA+ Line | Source Tag | Source Location |
|-----------|-----------|-----------------|
| 9 | `[Source: 0-input/REPORT.md -- RU-V7 Cross-Enterprise Verification]` | Module header |
| 10 | `[Source: 0-input/hypothesis.json -- Hub-and-spoke model hypothesis]` | Module header |
| 30-36 | `[Source: 0-input/REPORT.md, Section "Cross-Reference Circuit Design"]` | CrossRefIds definition |
| 62 | `[Source: 0-input/REPORT.md -- all enterprises begin with genesis state root]` | Init state |
| 73 | `[Source: 0-input/REPORT.md, "Sequential Verification" baseline]` | SubmitBatch action |
| 84 | `[Source: 0-input/REPORT.md, "Groth16 Individual Verification Cost" -- 205,600 gas]` | VerifyBatch action |
| 97-98 | Not tagged (derived from adversarial model) | FailBatch action |
| 107 | `[Source: 0-input/REPORT.md, Section "Cross-Reference Circuit Design"]` | RequestCrossRef action |
| 124-133 | `[Source: 0-input/REPORT.md, "Cross-Reference Circuit Design" + "Privacy Analysis"]` | VerifyCrossRef action (public/private input documentation) |
| 153-155 | Not tagged (derived from failure path) | RejectCrossRef action |
| 207-212 | `[Source: 0-input/REPORT.md, "Privacy Analysis" -- ZK guarantees, 128-bit]` | Isolation invariant |
| 224-225 | `[Source: 0-input/REPORT.md, Recommendations -- "valid only if both proofs valid"]` | Consistency invariant |
| 233 | Structural (derived from protocol semantics) | NoCrossRefSelfLoop invariant |
| 244-248 | Liveness property (derived from protocol requirements) | CrossRefTermination |

## Appendix B: Cross-Reference to Prior Audit Reports

| Prior Unit | Relevant Finding | Impact on RU-V7 |
|-----------|-----------------|-----------------|
| RU-V3 (State Commitment) | Gas cost baseline: 285,756 gas per enterprise submission, 205,600 gas for ZK verification | Source data for RU-V7 overhead ratios. TLA+ correctly abstracts gas costs. |
| RU-V5 (Enterprise Node) | Isolation invariant pattern: state determined solely by own verified batches | RU-V7 Isolation invariant follows the same pattern, extended to cross-enterprise context. |
| RU-V1 (Sparse Merkle Tree) | Merkle tree formalized separately; Poseidon collision resistance assumed | RU-V7 correctly abstracts Merkle proofs and state roots as opaque values. |
