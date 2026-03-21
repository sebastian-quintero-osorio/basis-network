---- MODULE PlonkMigration ----

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ============================================================================
\*                          CONSTANTS
\* ============================================================================

CONSTANTS
    Enterprises,        \* Set of registered enterprises on the network
    MaxBatches,         \* Maximum number of batches any enterprise can submit
    ProofSystems,       \* Set of proof systems: {"groth16", "plonk"}
    MaxMigrationSteps   \* Upper bound on steps before dual period must terminate

\* ============================================================================
\*                     DERIVED CONSTANTS
\* ============================================================================

\* The set of valid migration phases.
Phases == {"groth16_only", "dual", "plonk_only", "rollback"}

\* Mapping from phase to which verifiers are active.
\* This is the ground truth for the phase-verifier relationship.
VerifiersForPhase(p) ==
    CASE p = "groth16_only" -> {"groth16"}
      [] p = "dual"          -> {"groth16", "plonk"}
      [] p = "plonk_only"    -> {"plonk"}
      [] p = "rollback"      -> {"groth16"}

\* ============================================================================
\*                          VARIABLES
\* ============================================================================

VARIABLES
    migrationPhase,     \* Current phase: element of Phases
    activeVerifiers,    \* Set of proof systems currently accepted for verification
    batchQueue,         \* [Enterprises -> Seq(BatchRecord)] -- pending batches per enterprise
    verifiedBatches,    \* [Enterprises -> Set(BatchRecord)] -- verified batches per enterprise
    batchCounter,       \* [Enterprises -> Nat] -- total batches submitted per enterprise
    proofRegistry,      \* Set of ProofRecord -- all verification outcomes
    migrationStepCount, \* Counter for steps elapsed during dual verification period
    failureDetected     \* BOOLEAN -- whether a critical failure has been detected

vars == << migrationPhase, activeVerifiers, batchQueue, verifiedBatches,
           batchCounter, proofRegistry, migrationStepCount, failureDetected >>

\* ============================================================================
\*                     DOMAIN DEFINITIONS
\* ============================================================================

\* [Source: 0-input/REPORT.md, Section 4.3 -- "Migration Strategy"]
\* A batch record: enterprise, sequence number, and the proof system used to generate it.
BatchRecord == [enterprise: Enterprises, seqNo: 1..MaxBatches, proofSystem: ProofSystems]

\* A proof record: the batch, the verification result, and the phase in which
\* verification occurred. The phase stamp is critical for Completeness and
\* BackwardCompatibility invariants -- these properties must evaluate validity
\* relative to the verifiers that were active AT VERIFICATION TIME, not the
\* current state. Without this stamp, phase transitions (e.g., groth16_only -> dual)
\* would retroactively invalidate historical records.
ProofRecord == [batch: BatchRecord, valid: BOOLEAN, phase: Phases]

\* ============================================================================
\*                     TYPE INVARIANT
\* ============================================================================

TypeOK ==
    /\ migrationPhase \in Phases
    /\ activeVerifiers \subseteq ProofSystems
    /\ activeVerifiers /= {}
    /\ \A e \in Enterprises:
        /\ batchQueue[e] \in Seq(BatchRecord)
        /\ verifiedBatches[e] \subseteq BatchRecord
        /\ batchCounter[e] \in 0..MaxBatches
    /\ proofRegistry \subseteq ProofRecord
    /\ migrationStepCount \in 0..MaxMigrationSteps
    /\ failureDetected \in BOOLEAN

\* ============================================================================
\*                     INITIAL STATE
\* ============================================================================

\* [Source: 0-input/REPORT.md, Section 4.1 -- "Existing Groth16 Infrastructure"]
\* The system starts in groth16_only mode with only the Groth16 verifier active.
\* All enterprises have empty queues and no verified batches.
Init ==
    /\ migrationPhase = "groth16_only"
    /\ activeVerifiers = {"groth16"}
    /\ batchQueue = [e \in Enterprises |-> << >>]
    /\ verifiedBatches = [e \in Enterprises |-> {}]
    /\ batchCounter = [e \in Enterprises |-> 0]
    /\ proofRegistry = {}
    /\ migrationStepCount = 0
    /\ failureDetected = FALSE

\* ============================================================================
\*                     PROOF SYSTEM AXIOMS
\* ============================================================================

\* [Source: 0-input/REPORT.md, Section 8 -- "Recommendation for Downstream Agents"]
\*
\* AXIOM (Soundness): A proof system Verify(vk, inputs, proof) returns TRUE only
\* for correctly computed proofs. In this model, we abstract this as: a batch is
\* valid iff its proofSystem is in activeVerifiers at verification time. The verifier
\* contract routes to the correct backend (Groth16Verifier or PLONKVerifier) based
\* on the proof type. An inactive backend rejects all proofs.
\*
\* AXIOM (Completeness): A proof system Verify(vk, inputs, proof) returns TRUE for
\* every correctly generated proof. We model this as: if a batch's proofSystem is
\* in activeVerifiers at verification time, verification succeeds (valid=TRUE).
\* This assumes correct proof generation by the enterprise prover.
\*
\* AXIOM (Zero-Knowledge): The proof reveals nothing beyond the statement's truth.
\* This is a property of the cryptographic construction (Groth16: simulation-based,
\* PLONK: polynomial hiding). Not modeled in TLA+ -- verified at protocol level.
\* Both Groth16 and halo2-KZG satisfy computational zero-knowledge under BN254.

\* ============================================================================
\*                     ACTIONS
\* ============================================================================

\* --- Batch Submission ---

\* [Source: 0-input/REPORT.md, Section 4.3 -- "Phase 1: Dual Verification"]
\* An enterprise submits a batch with a proof generated under a specific proof system.
\* Submission is allowed for ANY known proof system -- the verifier decides acceptance.
\* This models the realistic scenario where an enterprise may have a stale prover
\* (e.g., Groth16 prover still running after cutover to PLONK-only).
\* Guard: enterprise has not exceeded MaxBatches, not in rollback.
SubmitBatch(e, ps) ==
    /\ batchCounter[e] < MaxBatches
    /\ ps \in ProofSystems
    /\ migrationPhase /= "rollback"  \* No new submissions during rollback
    /\ LET newSeqNo == batchCounter[e] + 1
           newBatch == [enterprise |-> e, seqNo |-> newSeqNo, proofSystem |-> ps]
       IN
        /\ batchQueue' = [batchQueue EXCEPT ![e] = Append(@, newBatch)]
        /\ batchCounter' = [batchCounter EXCEPT ![e] = newSeqNo]
        /\ UNCHANGED << migrationPhase, activeVerifiers, verifiedBatches,
                        proofRegistry, migrationStepCount, failureDetected >>

\* --- Proof Verification ---

\* [Source: 0-input/REPORT.md, Section 4.3 -- "BasisRollup.sol accepts both proof types
\*  via router pattern"]
\* Verify the first batch in an enterprise's queue (FIFO).
\* The batch is accepted (valid=TRUE) iff its proofSystem is in activeVerifiers.
\* If the proofSystem is NOT in activeVerifiers, the batch is rejected (valid=FALSE).
\* The phase at verification time is stamped into the ProofRecord for invariant checking.
VerifyBatch(e) ==
    /\ Len(batchQueue[e]) > 0
    /\ LET batch == Head(batchQueue[e])
           isValid == batch.proofSystem \in activeVerifiers
       IN
        /\ proofRegistry' = proofRegistry \union
               {[batch |-> batch, valid |-> isValid, phase |-> migrationPhase]}
        /\ IF isValid
           THEN verifiedBatches' = [verifiedBatches EXCEPT ![e] = @ \union {batch}]
           ELSE verifiedBatches' = verifiedBatches
        /\ batchQueue' = [batchQueue EXCEPT ![e] = Tail(@)]
        /\ UNCHANGED << migrationPhase, activeVerifiers, batchCounter,
                        migrationStepCount, failureDetected >>

\* --- Migration Phase Transitions ---

\* [Source: 0-input/REPORT.md, Section 4.3 -- "Phase 1: Dual Verification"]
\* Initiate migration: move from groth16_only to dual verification.
\* Both Groth16 and PLONK verifiers become active. The dual period step counter begins.
StartDualVerification ==
    /\ migrationPhase = "groth16_only"
    /\ migrationPhase' = "dual"
    /\ activeVerifiers' = {"groth16", "plonk"}
    /\ migrationStepCount' = 0
    /\ UNCHANGED << batchQueue, verifiedBatches, batchCounter,
                    proofRegistry, failureDetected >>

\* [Source: 0-input/REPORT.md, Section 4.3 -- "Phase 2: PLONK-Only"]
\* Cutover to PLONK-only. Preconditions:
\*   1. Currently in dual phase
\*   2. No failure detected
\*   3. All enterprise queues are empty (no in-flight batches of either type)
\* The empty-queue guard ensures MigrationSafety: no Groth16 batch is stranded
\* when the Groth16 verifier is deactivated.
CutoverToPlonkOnly ==
    /\ migrationPhase = "dual"
    /\ ~failureDetected
    /\ \A e \in Enterprises: batchQueue[e] = << >>
    /\ migrationPhase' = "plonk_only"
    /\ activeVerifiers' = {"plonk"}
    /\ UNCHANGED << batchQueue, verifiedBatches, batchCounter,
                    proofRegistry, migrationStepCount, failureDetected >>

\* Tick the dual period step counter. Models time progression during the
\* dual verification period. Bounded by MaxMigrationSteps.
DualPeriodTick ==
    /\ migrationPhase = "dual"
    /\ migrationStepCount < MaxMigrationSteps
    /\ migrationStepCount' = migrationStepCount + 1
    /\ UNCHANGED << migrationPhase, activeVerifiers, batchQueue, verifiedBatches,
                    batchCounter, proofRegistry, failureDetected >>

\* --- Failure Detection and Rollback ---

\* [Source: User requirement -- "Rollback de migracion si fallo detectado"]
\* A failure is detected during dual verification. Examples:
\*   - PLONK verifier produces incorrect results
\*   - Gas cost exceeds 500K budget
\*   - Critical vulnerability found in halo2-KZG
\* [Source: 0-input/REPORT.md, Section 6.2 -- "What Would Change Our Mind"]
DetectFailure ==
    /\ migrationPhase = "dual"
    /\ ~failureDetected
    /\ failureDetected' = TRUE
    /\ UNCHANGED << migrationPhase, activeVerifiers, batchQueue, verifiedBatches,
                    batchCounter, proofRegistry, migrationStepCount >>

\* Rollback: revert verifiers to groth16-only. Only from dual phase after failure.
\* Pending PLONK batches remain in queue -- they will be rejected at verification
\* since activeVerifiers reverts to {"groth16"} only.
RollbackMigration ==
    /\ migrationPhase = "dual"
    /\ failureDetected
    /\ migrationPhase' = "rollback"
    /\ activeVerifiers' = {"groth16"}
    /\ UNCHANGED << batchQueue, verifiedBatches, batchCounter,
                    proofRegistry, migrationStepCount, failureDetected >>

\* Complete rollback: after all queues are drained (remaining batches verified/rejected),
\* return to stable groth16_only state. Reset failure flag and step counter.
CompleteRollback ==
    /\ migrationPhase = "rollback"
    /\ \A e \in Enterprises: batchQueue[e] = << >>
    /\ migrationPhase' = "groth16_only"
    /\ failureDetected' = FALSE
    /\ migrationStepCount' = 0
    /\ UNCHANGED << activeVerifiers, batchQueue, verifiedBatches,
                    batchCounter, proofRegistry >>

\* ============================================================================
\*                     NEXT-STATE RELATION
\* ============================================================================

Next ==
    \/ \E e \in Enterprises, ps \in ProofSystems: SubmitBatch(e, ps)
    \/ \E e \in Enterprises: VerifyBatch(e)
    \/ StartDualVerification
    \/ CutoverToPlonkOnly
    \/ DualPeriodTick
    \/ DetectFailure
    \/ RollbackMigration
    \/ CompleteRollback

Spec == Init /\ [][Next]_vars

\* ============================================================================
\*                     SAFETY PROPERTIES
\* ============================================================================

\* --- S1: MigrationSafety ---
\* [Why]: No batch goes unverified during the migration. For every submitted
\* sequence number, a batch with that seqNo must exist either in the queue
\* (awaiting verification) or in the proofRegistry (already processed).
\* We quantify over seqNo (not the full BatchRecord type) because a given
\* seqNo maps to exactly one batch record with a specific proofSystem.
MigrationSafety ==
    \A e \in Enterprises:
        \A n \in 1..batchCounter[e]:
            \/ \E i \in 1..Len(batchQueue[e]):
                   batchQueue[e][i].enterprise = e /\ batchQueue[e][i].seqNo = n
            \/ \E r \in proofRegistry:
                   r.batch.enterprise = e /\ r.batch.seqNo = n

\* --- S2: BackwardCompatibility ---
\* [Why]: Groth16 proofs must be accepted during phases where Groth16 is active.
\* Any Groth16 batch verified during groth16_only, dual, or rollback phase
\* (all of which include "groth16" in activeVerifiers) must have valid=TRUE.
\* Uses the phase stamp to evaluate against the verifiers active at verification time.
BackwardCompatibility ==
    \A r \in proofRegistry:
        (r.batch.proofSystem = "groth16" /\
         "groth16" \in VerifiersForPhase(r.phase)) =>
            r.valid = TRUE

\* --- S3: Soundness ---
\* [Why]: No false positives. Every batch in verifiedBatches (accepted as valid)
\* must have a corresponding valid=TRUE record in the proofRegistry. This ensures
\* the proof system change does not allow unverified state transitions.
Soundness ==
    \A e \in Enterprises:
        \A b \in verifiedBatches[e]:
            \E r \in proofRegistry: r.batch = b /\ r.valid = TRUE

\* --- S4: Completeness ---
\* [Why]: No false negatives. If a batch's proofSystem was in the active verifiers
\* at the time of its verification (phase-stamped), then verification must have
\* produced valid=TRUE. This ensures valid proofs are never rejected by an active verifier.
\* The phase stamp resolves the temporal ambiguity: a PLONK batch verified during
\* groth16_only phase is correctly rejected (valid=FALSE) because "plonk" is not
\* in VerifiersForPhase("groth16_only").
Completeness ==
    \A r \in proofRegistry:
        (r.batch.proofSystem \in VerifiersForPhase(r.phase)) => r.valid = TRUE

\* --- S5: NoGroth16AfterCutover ---
\* [Why]: After cutover to plonk_only, no Groth16 batch can be verified as valid.
\* Any Groth16 batch verified during plonk_only phase must have valid=FALSE.
\* This is the structural guarantee that the cutover is irreversible for Groth16.
NoGroth16AfterCutover ==
    \A r \in proofRegistry:
        (r.batch.proofSystem = "groth16" /\ r.phase = "plonk_only") =>
            r.valid = FALSE

\* --- S6: PhaseConsistency ---
\* [Why]: The activeVerifiers set must always correspond to the current migrationPhase.
\* This prevents any state where the wrong verifier set is active for a given phase.
\* Enforced structurally by action guards, verified exhaustively here.
PhaseConsistency ==
    activeVerifiers = VerifiersForPhase(migrationPhase)

\* --- S7: RollbackOnlyOnFailure ---
\* [Why]: The system enters rollback phase only after a failure is detected.
\* Prevents spurious rollbacks that could disrupt enterprise operations.
RollbackOnlyOnFailure ==
    (migrationPhase = "rollback") => failureDetected

\* --- S8: NoBatchLossDuringRollback ---
\* [Why]: During rollback, batches in the queue are not dropped -- they are
\* verified (and rejected if PLONK) or accepted (if Groth16). The queue
\* drains normally; no batch disappears without a registry entry.
\* This is a specialization of MigrationSafety for the rollback path.
NoBatchLossDuringRollback ==
    (migrationPhase = "rollback") =>
        \A e \in Enterprises:
            \A n \in 1..batchCounter[e]:
                \/ \E i \in 1..Len(batchQueue[e]):
                       batchQueue[e][i].enterprise = e /\ batchQueue[e][i].seqNo = n
                \/ \E r \in proofRegistry:
                       r.batch.enterprise = e /\ r.batch.seqNo = n

\* ============================================================================
\*                     LIVENESS PROPERTIES
\* ============================================================================

\* --- L1: DualPeriodTermination ---
\* [Why]: The dual verification period must eventually terminate -- either by
\* successful cutover to plonk_only or by rollback to groth16_only.
\* The system must not remain in "dual" indefinitely.
DualPeriodTermination ==
    (migrationPhase = "dual") ~> (migrationPhase \in {"plonk_only", "groth16_only"})

\* --- L2: BatchEventualVerification ---
\* [Why]: Every submitted batch must eventually be processed (verified or rejected).
\* No batch remains in the queue indefinitely.
BatchEventualVerification ==
    \A e \in Enterprises:
        (Len(batchQueue[e]) > 0) ~> (Len(batchQueue[e]) = 0)

====
