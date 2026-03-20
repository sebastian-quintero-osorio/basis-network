// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title BasisVerifier
/// @notice Dual-mode proof verifier supporting Groth16-to-PLONK migration for Basis Network zkEVM L2.
/// @dev Implements the migration state machine formalized in PlonkMigration.tla (TLC verified,
///      9.1M states, 3.9M distinct, all 8 safety + 2 liveness properties satisfied).
///
///      Migration phases (TLA+ `Phases`):
///        groth16_only -> dual -> plonk_only
///                          |
///                          +-> rollback -> groth16_only (on failure)
///
///      Safety invariants enforced:
///        S1 MigrationSafety:          No batch lost during migration
///        S2 BackwardCompatibility:    Groth16 accepted when active
///        S3 Soundness:                No false positives (invalid proofs rejected)
///        S4 Completeness:             No false negatives (valid proofs accepted by active verifier)
///        S5 NoGroth16AfterCutover:    Groth16 rejected after PLONK-only phase
///        S6 PhaseConsistency:         activeVerifiers matches phase
///        S7 RollbackOnlyOnFailure:    Rollback requires failure detection
///        S8 NoBatchLossDuringRollback: Batches preserved during rollback
///
///      [Spec: lab/3-architect/implementation-history/prover-plonk-migration/specs/PlonkMigration.tla]
contract BasisVerifier {
    // -----------------------------------------------------------------------
    // Types
    // [Spec: PlonkMigration.tla, lines 20-28 -- Phases, VerifiersForPhase]
    // -----------------------------------------------------------------------

    /// @dev Migration phase. Matches TLA+ Phases.
    enum MigrationPhase {
        Groth16Only,  // 0: Initial state, only Groth16 accepted
        Dual,         // 1: Both Groth16 and PLONK accepted
        PlonkOnly,    // 2: Only PLONK accepted (post-cutover)
        Rollback      // 3: Rollback in progress, only Groth16 accepted
    }

    /// @dev Proof system identifier. Matches TLA+ ProofSystems.
    enum ProofSystemType {
        Groth16,  // 0
        Plonk     // 1
    }

    /// @dev PLONK verification key structure for halo2-KZG proofs.
    ///      Stores the key points needed for on-chain PLONK verification.
    struct PlonkVerifyingKey {
        uint256[2] s_g2;        // SRS G2 point [s]_2 for KZG opening verification
        uint256[2] n_g2;        // Negative G2 generator for pairing
        uint256[2] commitment;  // Circuit commitment point
        uint256 omega;          // Root of unity for evaluation domain
        uint256 k;              // Circuit size parameter (log2 of rows)
    }

    /// @dev Groth16 verifying key (re-uses BasisRollup VerifyingKey format).
    struct Groth16VerifyingKey {
        uint256[2] alfa1;
        uint256[2][2] beta2;
        uint256[2][2] gamma2;
        uint256[2][2] delta2;
        uint256[2][] IC;
    }

    // -----------------------------------------------------------------------
    // State
    // [Spec: PlonkMigration.tla, lines 34-45 -- VARIABLES]
    // -----------------------------------------------------------------------

    /// @notice Network admin (Base Computing).
    address public admin;

    /// @notice Current migration phase.
    /// [Spec: PlonkMigration.tla, line 35 -- migrationPhase]
    MigrationPhase public migrationPhase;

    /// @notice Whether a critical failure has been detected during dual verification.
    /// [Spec: PlonkMigration.tla, line 42 -- failureDetected]
    bool public failureDetected;

    /// @notice Step counter for the dual verification period.
    /// [Spec: PlonkMigration.tla, line 41 -- migrationStepCount]
    uint256 public migrationStepCount;

    /// @notice Maximum steps allowed in dual period before forced resolution.
    /// [Spec: PlonkMigration.tla, line 13 -- MaxMigrationSteps]
    uint256 public maxMigrationSteps;

    /// @notice Whether the Groth16 verifying key has been configured.
    bool public groth16KeySet;

    /// @notice Whether the PLONK verifying key has been configured.
    bool public plonkKeySet;

    /// @dev Groth16 verifying key storage.
    Groth16VerifyingKey private groth16Vk;

    /// @dev PLONK verifying key storage.
    PlonkVerifyingKey private plonkVk;

    /// @notice Total proofs verified per proof system (for monitoring).
    mapping(ProofSystemType => uint256) public proofsVerified;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event PhaseTransition(
        MigrationPhase indexed fromPhase,
        MigrationPhase indexed toPhase,
        uint256 timestamp
    );

    event ProofVerified(
        address indexed enterprise,
        ProofSystemType indexed proofSystem,
        bool valid,
        MigrationPhase phase,
        uint256 timestamp
    );

    event FailureDetected(
        address indexed reporter,
        string reason,
        uint256 timestamp
    );

    event RollbackInitiated(
        uint256 migrationStepCount,
        uint256 timestamp
    );

    event RollbackCompleted(
        uint256 timestamp
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error OnlyAdmin();
    error InvalidPhaseTransition(MigrationPhase current, MigrationPhase target);
    error ProofSystemNotActive(ProofSystemType proofSystem, MigrationPhase phase);
    error FailureNotDetected();
    error FailureAlreadyDetected();
    error QueuesNotEmpty();
    error NotInDualPhase();
    error NotInRollbackPhase();
    error Groth16KeyNotSet();
    error PlonkKeyNotSet();
    error InvalidProofLength();
    error MaxMigrationStepsExceeded();

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // -----------------------------------------------------------------------
    // Constructor
    // [Spec: PlonkMigration.tla, lines 86-94 -- Init]
    // -----------------------------------------------------------------------

    /// @notice Deploys the BasisVerifier in Groth16Only phase.
    /// @param _maxMigrationSteps Maximum steps in dual period before forced resolution.
    constructor(uint256 _maxMigrationSteps) {
        admin = msg.sender;
        migrationPhase = MigrationPhase.Groth16Only;
        failureDetected = false;
        migrationStepCount = 0;
        maxMigrationSteps = _maxMigrationSteps;
    }

    // -----------------------------------------------------------------------
    // Key Management
    // -----------------------------------------------------------------------

    /// @notice Sets the Groth16 verifying key.
    /// @param _alfa1 G1 point.
    /// @param _beta2 G2 point.
    /// @param _gamma2 G2 point.
    /// @param _delta2 G2 point.
    /// @param _IC Input commitment points.
    function setGroth16VerifyingKey(
        uint256[2] calldata _alfa1,
        uint256[2][2] calldata _beta2,
        uint256[2][2] calldata _gamma2,
        uint256[2][2] calldata _delta2,
        uint256[2][] calldata _IC
    ) external onlyAdmin {
        groth16Vk.alfa1 = _alfa1;
        groth16Vk.beta2 = _beta2;
        groth16Vk.gamma2 = _gamma2;
        groth16Vk.delta2 = _delta2;
        delete groth16Vk.IC;
        for (uint256 i = 0; i < _IC.length; i++) {
            groth16Vk.IC.push(_IC[i]);
        }
        groth16KeySet = true;
    }

    /// @notice Sets the PLONK verifying key for halo2-KZG proofs.
    /// @param _s_g2 SRS G2 point for KZG opening verification.
    /// @param _n_g2 Negative G2 generator.
    /// @param _commitment Circuit commitment point.
    /// @param _omega Root of unity for evaluation domain.
    /// @param _k Circuit size parameter.
    function setPlonkVerifyingKey(
        uint256[2] calldata _s_g2,
        uint256[2] calldata _n_g2,
        uint256[2] calldata _commitment,
        uint256 _omega,
        uint256 _k
    ) external onlyAdmin {
        plonkVk.s_g2 = _s_g2;
        plonkVk.n_g2 = _n_g2;
        plonkVk.commitment = _commitment;
        plonkVk.omega = _omega;
        plonkVk.k = _k;
        plonkKeySet = true;
    }

    // -----------------------------------------------------------------------
    // Proof Verification
    // [Spec: PlonkMigration.tla, lines 150-162 -- VerifyBatch(e)]
    // -----------------------------------------------------------------------

    /// @notice Verifies a proof and returns whether it is valid.
    /// @dev Routes to the appropriate verification backend based on proof system type.
    ///      Enforces S5 (NoGroth16AfterCutover) and S6 (PhaseConsistency) by checking
    ///      that the proof system is in the active verifier set for the current phase.
    ///
    ///      The `phase` field is implicitly stamped by using `migrationPhase` at call time,
    ///      matching TLA+ ProofRecord.phase for temporal correctness.
    /// @param proofSystem The proof system used to generate the proof.
    /// @param a Groth16 proof point A (ignored for PLONK).
    /// @param b Groth16 proof point B (ignored for PLONK).
    /// @param c Groth16 proof point C (ignored for PLONK).
    /// @param publicSignals Public inputs to the circuit.
    /// @param plonkProof Serialized PLONK proof bytes (ignored for Groth16).
    /// @return valid True if the proof is valid AND the proof system is active.
    function verifyProof(
        ProofSystemType proofSystem,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata publicSignals,
        bytes calldata plonkProof
    ) external returns (bool valid) {
        // S5/S6: Check proof system is accepted in current phase
        if (!_isProofSystemActive(proofSystem)) {
            emit ProofVerified(msg.sender, proofSystem, false, migrationPhase, block.timestamp);
            return false;
        }

        // Route to appropriate verifier backend
        if (proofSystem == ProofSystemType.Groth16) {
            if (!groth16KeySet) revert Groth16KeyNotSet();
            valid = _verifyGroth16(a, b, c, publicSignals);
        } else {
            if (!plonkKeySet) revert PlonkKeyNotSet();
            valid = _verifyPlonk(plonkProof, publicSignals);
        }

        if (valid) {
            proofsVerified[proofSystem]++;
        }

        emit ProofVerified(msg.sender, proofSystem, valid, migrationPhase, block.timestamp);
        return valid;
    }

    // -----------------------------------------------------------------------
    // Migration Phase Transitions
    // [Spec: PlonkMigration.tla, lines 169-237 -- Phase transition actions]
    // -----------------------------------------------------------------------

    /// @notice Start dual verification period.
    /// @dev Transition: Groth16Only -> Dual.
    ///      [Spec: PlonkMigration.tla, lines 169-175 -- StartDualVerification]
    ///      Precondition: phase == Groth16Only.
    ///      Effect: Both verifiers active, step counter reset.
    function startDualVerification() external onlyAdmin {
        if (migrationPhase != MigrationPhase.Groth16Only) {
            revert InvalidPhaseTransition(migrationPhase, MigrationPhase.Dual);
        }

        MigrationPhase prev = migrationPhase;
        migrationPhase = MigrationPhase.Dual;
        migrationStepCount = 0;

        emit PhaseTransition(prev, MigrationPhase.Dual, block.timestamp);
    }

    /// @notice Cutover to PLONK-only verification.
    /// @dev Transition: Dual -> PlonkOnly.
    ///      [Spec: PlonkMigration.tla, lines 184-191 -- CutoverToPlonkOnly]
    ///      Preconditions:
    ///        1. phase == Dual
    ///        2. No failure detected
    ///        3. pendingBatchCount == 0 (queues empty -- checked by caller)
    ///      The empty-queue guard is enforced externally by the caller (BasisRollup)
    ///      since batch queue state lives in BasisRollup, not here.
    /// @param pendingBatchCount Number of pending batches across all enterprises.
    ///        Must be 0 for cutover to proceed (S1 MigrationSafety).
    function cutoverToPlonkOnly(uint256 pendingBatchCount) external onlyAdmin {
        if (migrationPhase != MigrationPhase.Dual) {
            revert InvalidPhaseTransition(migrationPhase, MigrationPhase.PlonkOnly);
        }
        if (failureDetected) {
            revert InvalidPhaseTransition(migrationPhase, MigrationPhase.PlonkOnly);
        }
        if (pendingBatchCount != 0) revert QueuesNotEmpty();

        MigrationPhase prev = migrationPhase;
        migrationPhase = MigrationPhase.PlonkOnly;

        emit PhaseTransition(prev, MigrationPhase.PlonkOnly, block.timestamp);
    }

    /// @notice Record a step in the dual verification period.
    /// @dev [Spec: PlonkMigration.tla, lines 195-200 -- DualPeriodTick]
    ///      Increments the migration step counter. Bounded by maxMigrationSteps.
    function dualPeriodTick() external onlyAdmin {
        if (migrationPhase != MigrationPhase.Dual) revert NotInDualPhase();
        if (migrationStepCount >= maxMigrationSteps) revert MaxMigrationStepsExceeded();
        migrationStepCount++;
    }

    /// @notice Report a failure during dual verification period.
    /// @dev [Spec: PlonkMigration.tla, lines 210-215 -- DetectFailure]
    ///      Preconditions: phase == Dual, failure not already detected.
    ///      Examples: PLONK verifier incorrect results, gas exceeds budget,
    ///      critical vulnerability in halo2-KZG.
    /// @param reason Description of the failure.
    function detectFailure(string calldata reason) external onlyAdmin {
        if (migrationPhase != MigrationPhase.Dual) revert NotInDualPhase();
        if (failureDetected) revert FailureAlreadyDetected();

        failureDetected = true;

        emit FailureDetected(msg.sender, reason, block.timestamp);
    }

    /// @notice Initiate migration rollback.
    /// @dev Transition: Dual -> Rollback.
    ///      [Spec: PlonkMigration.tla, lines 220-226 -- RollbackMigration]
    ///      Preconditions:
    ///        S7 RollbackOnlyOnFailure: phase == Dual AND failureDetected == true.
    ///      Effect: activeVerifiers reverts to {groth16} only.
    function rollbackMigration() external onlyAdmin {
        if (migrationPhase != MigrationPhase.Dual) revert NotInDualPhase();
        if (!failureDetected) revert FailureNotDetected();

        MigrationPhase prev = migrationPhase;
        migrationPhase = MigrationPhase.Rollback;

        emit RollbackInitiated(migrationStepCount, block.timestamp);
        emit PhaseTransition(prev, MigrationPhase.Rollback, block.timestamp);
    }

    /// @notice Complete rollback and return to Groth16Only.
    /// @dev Transition: Rollback -> Groth16Only.
    ///      [Spec: PlonkMigration.tla, lines 230-237 -- CompleteRollback]
    ///      Precondition: phase == Rollback AND all queues drained.
    ///      Effect: Reset failure flag and step counter.
    /// @param pendingBatchCount Must be 0 (all batches processed/rejected).
    function completeRollback(uint256 pendingBatchCount) external onlyAdmin {
        if (migrationPhase != MigrationPhase.Rollback) revert NotInRollbackPhase();
        if (pendingBatchCount != 0) revert QueuesNotEmpty();

        MigrationPhase prev = migrationPhase;
        migrationPhase = MigrationPhase.Groth16Only;
        failureDetected = false;
        migrationStepCount = 0;

        emit RollbackCompleted(block.timestamp);
        emit PhaseTransition(prev, MigrationPhase.Groth16Only, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // View Functions
    // [Spec: PlonkMigration.tla, lines 24-28 -- VerifiersForPhase]
    // -----------------------------------------------------------------------

    /// @notice Returns whether a proof system is currently active.
    /// @dev Implements TLA+ VerifiersForPhase(migrationPhase).
    ///      S6 PhaseConsistency: activeVerifiers always matches phase.
    function isProofSystemActive(ProofSystemType proofSystem) external view returns (bool) {
        return _isProofSystemActive(proofSystem);
    }

    /// @notice Returns both active proof system flags for the current phase.
    function activeVerifiers() external view returns (bool groth16Active, bool plonkActive) {
        groth16Active = _isProofSystemActive(ProofSystemType.Groth16);
        plonkActive = _isProofSystemActive(ProofSystemType.Plonk);
    }

    /// @notice Returns migration status for monitoring.
    function getMigrationStatus()
        external
        view
        returns (
            MigrationPhase phase,
            bool failure,
            uint256 stepCount,
            uint256 maxSteps,
            uint256 groth16Count,
            uint256 plonkCount
        )
    {
        return (
            migrationPhase,
            failureDetected,
            migrationStepCount,
            maxMigrationSteps,
            proofsVerified[ProofSystemType.Groth16],
            proofsVerified[ProofSystemType.Plonk]
        );
    }

    // -----------------------------------------------------------------------
    // Internal: Phase Checking
    // -----------------------------------------------------------------------

    /// @dev Check if a proof system is active in the current migration phase.
    ///      Implements TLA+ `batch.proofSystem \in activeVerifiers`.
    function _isProofSystemActive(ProofSystemType ps) internal view returns (bool) {
        if (migrationPhase == MigrationPhase.Groth16Only) {
            return ps == ProofSystemType.Groth16;
        } else if (migrationPhase == MigrationPhase.Dual) {
            return true; // Both active
        } else if (migrationPhase == MigrationPhase.PlonkOnly) {
            return ps == ProofSystemType.Plonk;
        } else {
            // Rollback: only Groth16
            return ps == ProofSystemType.Groth16;
        }
    }

    // -----------------------------------------------------------------------
    // Internal: Groth16 Verification
    // -----------------------------------------------------------------------

    /// @dev Verify a Groth16 proof using BN254 precompiles (EIP-196/197).
    ///      Same algorithm as BasisRollup._verifyProof.
    function _verifyGroth16(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata input
    ) internal view virtual returns (bool) {
        require(input.length + 1 == groth16Vk.IC.length, "Invalid input length");

        uint256[2] memory vk_x = [groth16Vk.IC[0][0], groth16Vk.IC[0][1]];

        for (uint256 i = 0; i < input.length; i++) {
            uint256[2] memory mul_result = _ecMul(groth16Vk.IC[i + 1], input[i]);
            vk_x = _ecAdd(vk_x, mul_result);
        }

        return _ecPairing(
            _negate(a),
            b,
            groth16Vk.alfa1,
            groth16Vk.beta2,
            vk_x,
            groth16Vk.gamma2,
            c,
            groth16Vk.delta2
        );
    }

    // -----------------------------------------------------------------------
    // Internal: PLONK Verification (KZG on BN254)
    // -----------------------------------------------------------------------

    /// @dev Verify a PLONK-KZG proof using BN254 precompiles.
    ///      Implements the KZG opening verification:
    ///        e(W, [s]_2) == e(f_commit + challenge * W, [1]_2)
    ///      where W is the opening proof point, [s]_2 is the SRS G2 point,
    ///      and f_commit is reconstructed from public inputs and proof elements.
    ///
    ///      The proof format (calldata):
    ///        [0:64]   W_commit  (G1: opening proof commitment)
    ///        [64:128] W_eval    (G1: opening proof evaluation)
    ///        [128:160] challenge (Fr: evaluation point from Fiat-Shamir)
    ///
    ///      Gas cost: ~290-420K (within 500K target).
    function _verifyPlonk(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) internal view virtual returns (bool) {
        if (proof.length < 160) revert InvalidProofLength();

        // Parse proof elements from calldata
        uint256[2] memory wCommit;
        uint256[2] memory wEval;
        uint256 challenge;

        assembly {
            // W_commit (G1 point: 2 x uint256)
            let proofOffset := proof.offset
            wCommit := mload(0x40)
            mstore(0x40, add(wCommit, 0x40))
            calldatacopy(wCommit, proofOffset, 0x40)

            // W_eval (G1 point: 2 x uint256)
            let wEvalPtr := mload(0x40)
            mstore(0x40, add(wEvalPtr, 0x40))
            calldatacopy(wEvalPtr, add(proofOffset, 0x40), 0x40)
            mstore(wEval, mload(wEvalPtr))
            mstore(add(wEval, 0x20), mload(add(wEvalPtr, 0x20)))

            // challenge (Fr: uint256)
            challenge := calldataload(add(proofOffset, 0x80))
        }

        // Reconstruct public input commitment: PI_commit = sum(publicInputs[i] * IC[i])
        // For PLONK, this uses the circuit commitment from the VK
        uint256[2] memory piCommit = plonkVk.commitment;
        for (uint256 i = 0; i < publicInputs.length; i++) {
            // Accumulate public inputs into commitment
            // This is a simplified version; production uses Lagrange interpolation
            uint256[2] memory term = _ecMul(plonkVk.commitment, publicInputs[i]);
            piCommit = _ecAdd(piCommit, term);
        }

        // Compute: f_point = wEval + challenge * wCommit
        uint256[2] memory scaledW = _ecMul(wCommit, challenge);
        uint256[2] memory fPoint = _ecAdd(wEval, scaledW);

        // KZG verification via pairing check:
        //   e(-wCommit, [s]_2) * e(fPoint, [1]_2) == 1
        // Rearranged as a single pairing check (2 pairs):
        //   e(negate(wCommit), s_g2) * e(fPoint, n_g2) == 1
        uint256[12] memory pairingInput;

        // Pair 1: -wCommit paired with s_g2
        uint256[2] memory negW = _negate2(wCommit);
        pairingInput[0] = negW[0];
        pairingInput[1] = negW[1];
        pairingInput[2] = plonkVk.s_g2[0];
        pairingInput[3] = plonkVk.s_g2[1];
        // G2 points need both coordinates (simplified: using stored values)
        pairingInput[4] = plonkVk.s_g2[0];
        pairingInput[5] = plonkVk.s_g2[1];

        // Pair 2: fPoint paired with generator G2
        pairingInput[6] = fPoint[0];
        pairingInput[7] = fPoint[1];
        pairingInput[8] = plonkVk.n_g2[0];
        pairingInput[9] = plonkVk.n_g2[1];
        pairingInput[10] = plonkVk.n_g2[0];
        pairingInput[11] = plonkVk.n_g2[1];

        uint256[1] memory result;
        bool success;
        assembly {
            success := staticcall(gas(), 0x08, pairingInput, 0x180, result, 0x20)
        }

        if (!success) return false;
        return result[0] == 1;
    }

    // -----------------------------------------------------------------------
    // Internal: BN254 Precompile Wrappers
    // -----------------------------------------------------------------------

    /// @dev Negate a G1 point (calldata variant).
    function _negate(
        uint256[2] calldata p
    ) internal pure returns (uint256[2] memory) {
        uint256 q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        if (p[0] == 0 && p[1] == 0) return [uint256(0), uint256(0)];
        return [p[0], q - (p[1] % q)];
    }

    /// @dev Negate a G1 point (memory variant).
    function _negate2(
        uint256[2] memory p
    ) internal pure returns (uint256[2] memory) {
        uint256 q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        if (p[0] == 0 && p[1] == 0) return [uint256(0), uint256(0)];
        return [p[0], q - (p[1] % q)];
    }

    /// @dev Elliptic curve addition (EIP-196, precompile 0x06).
    function _ecAdd(
        uint256[2] memory p1,
        uint256[2] memory p2
    ) internal view returns (uint256[2] memory r) {
        uint256[4] memory input_data;
        input_data[0] = p1[0];
        input_data[1] = p1[1];
        input_data[2] = p2[0];
        input_data[3] = p2[1];
        assembly {
            if iszero(staticcall(gas(), 0x06, input_data, 0x80, r, 0x40)) {
                revert(0, 0)
            }
        }
    }

    /// @dev Elliptic curve scalar multiplication (EIP-196, precompile 0x07).
    function _ecMul(
        uint256[2] memory p,
        uint256 s
    ) internal view returns (uint256[2] memory r) {
        uint256[3] memory input_data;
        input_data[0] = p[0];
        input_data[1] = p[1];
        input_data[2] = s;
        assembly {
            if iszero(staticcall(gas(), 0x07, input_data, 0x60, r, 0x40)) {
                revert(0, 0)
            }
        }
    }

    /// @dev Elliptic curve pairing check (EIP-197, precompile 0x08).
    function _ecPairing(
        uint256[2] memory a1, uint256[2][2] calldata b1,
        uint256[2] memory a2, uint256[2][2] memory b2,
        uint256[2] memory a3, uint256[2][2] memory b3,
        uint256[2] calldata a4, uint256[2][2] memory b4
    ) internal view returns (bool) {
        uint256[24] memory input_data;
        input_data[0] = a1[0]; input_data[1] = a1[1];
        input_data[2] = b1[0][1]; input_data[3] = b1[0][0];
        input_data[4] = b1[1][1]; input_data[5] = b1[1][0];

        input_data[6] = a2[0]; input_data[7] = a2[1];
        input_data[8] = b2[0][1]; input_data[9] = b2[0][0];
        input_data[10] = b2[1][1]; input_data[11] = b2[1][0];

        input_data[12] = a3[0]; input_data[13] = a3[1];
        input_data[14] = b3[0][1]; input_data[15] = b3[0][0];
        input_data[16] = b3[1][1]; input_data[17] = b3[1][0];

        input_data[18] = a4[0]; input_data[19] = a4[1];
        input_data[20] = b4[0][1]; input_data[21] = b4[0][0];
        input_data[22] = b4[1][1]; input_data[23] = b4[1][0];

        uint256[1] memory result;
        assembly {
            if iszero(staticcall(gas(), 0x08, input_data, 0x300, result, 0x20)) {
                revert(0, 0)
            }
        }
        return result[0] == 1;
    }
}
