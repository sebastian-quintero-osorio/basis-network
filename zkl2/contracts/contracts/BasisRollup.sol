// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "./IEnterpriseRegistry.sol";

/// @title BasisRollup
/// @notice L1 rollup contract for Basis Network zkEVM L2 with per-enterprise state chains.
/// @dev Implements a three-phase commit-prove-execute lifecycle for L2 batch submissions.
///      Each enterprise maintains an independent state root chain. Batches track L2 block
///      ranges for bridge withdrawal references and forced inclusion verification.
///
///      Lifecycle:
///        commitBatch  -> Committed  (sequencer posts batch metadata)
///        proveBatch   -> Proven     (prover submits Groth16 validity proof)
///        executeBatch -> Executed   (state root finalized, L2->L1 messages processed)
///
///      [Spec: zkl2/specs/units/2026-03-basis-rollup/1-formalization/v0-analysis/specs/BasisRollup/BasisRollup.tla]
///
///      Safety invariants enforced (12 TLA+ invariants, all TLC-verified):
///        INV-01 TypeOK:               Type system integrity (Solidity type enforcement)
///        INV-02 BatchChainContinuity: currentRoot == batchRoot of last executed batch
///        INV-03 ProveBeforeExecute:   Batch must be Proven before execution (INV-R2)
///        INV-04 ExecuteInOrder:       Sequential batch execution (INV-R1)
///        INV-05 RevertSafety:         Executed batches cannot be reverted (INV-R5)
///        INV-06 CommitBeforeProve:    Batch must be Committed before proving (INV-R3)
///        INV-07 CounterMonotonicity:  executed <= proven <= committed
///        INV-08 NoReversal:           Initialized enterprise always has valid root
///        INV-09 InitBeforeBatch:      Batches only for initialized enterprises
///        INV-10 StatusConsistency:    Batch statuses align with counter watermarks
///        INV-11 GlobalCountIntegrity: Global counters == sum of per-enterprise counters
///        INV-12 BatchRootIntegrity:   Committed batches have roots, uncommitted do not
///
///      Additional Solidity-level invariants (not in TLA+ -- data-level constraints):
///        INV-R4 MonotonicBlockRange:  L2 block ranges are non-overlapping and ascending
contract BasisRollup {
    // -----------------------------------------------------------------------
    // Types
    // [Spec: BasisRollup.tla, lines 41-49 -- AllStatuses]
    // -----------------------------------------------------------------------

    enum BatchStatus { None, Committed, Proven, Executed }

    /// @dev Groth16 verifying key (same structure as validium StateCommitment.sol).
    struct VerifyingKey {
        uint256[2] alfa1;
        uint256[2][2] beta2;
        uint256[2][2] gamma2;
        uint256[2][2] delta2;
        uint256[2][] IC;
    }

    /// @dev Per-enterprise chain state. Packed into 3 storage slots.
    /// [Spec: BasisRollup.tla, lines 58-68 -- currentRoot, initialized,
    ///  totalBatchesCommitted, totalBatchesProven, totalBatchesExecuted]
    struct EnterpriseState {
        bytes32 currentRoot;           // Slot 1: finalized state root (32 bytes)
        uint64 totalBatchesCommitted;  // Slot 2: next batch to commit (8 bytes)
        uint64 totalBatchesProven;     // Slot 2: next batch to prove (8 bytes)
        uint64 totalBatchesExecuted;   // Slot 2: next batch to execute (8 bytes)
        bool initialized;              // Slot 2: initialization flag (1 byte)
        uint64 lastL2Block;            // Slot 3: highest L2 block finalized (8 bytes)
    }

    /// @dev Batch data committed by the sequencer. Used to compute batchHash.
    struct CommitBatchData {
        bytes32 newStateRoot;      // State root after applying this batch
        uint64 l2BlockStart;       // First L2 block number in this batch
        uint64 l2BlockEnd;         // Last L2 block number in this batch
        bytes32 priorityOpsHash;   // Hash of priority operations included
        uint64 timestamp;          // L2 timestamp of the batch
    }

    /// @dev Stored on-chain per batch. Batch hash pattern (integrity for prove phase).
    /// [Spec: BasisRollup.tla, lines 64-65 -- batchStatus, batchRoot per enterprise per batch]
    struct StoredBatchInfo {
        bytes32 batchHash;         // Slot 1: keccak256(abi.encode(CommitBatchData))
        bytes32 stateRoot;         // Slot 2: new state root (needed for execute phase)
        uint64 l2BlockStart;       // Slot 3 (packed): first L2 block
        uint64 l2BlockEnd;         // Slot 3 (packed): last L2 block
        BatchStatus status;        // Slot 3 (packed): lifecycle status (1 byte)
    }

    // -----------------------------------------------------------------------
    // State
    // [Spec: BasisRollup.tla, lines 58-68 -- VARIABLES]
    // -----------------------------------------------------------------------

    /// @notice Network admin address (Base Computing).
    address public admin;

    /// @notice Reference to the EnterpriseRegistry for authorization.
    IEnterpriseRegistry public immutable enterpriseRegistry;

    /// @dev Groth16 verifying key for the L2 state transition circuit.
    VerifyingKey private vk;

    /// @notice Whether the verifying key has been configured.
    bool public verifyingKeySet;

    /// @notice Per-enterprise chain state.
    mapping(address => EnterpriseState) public enterprises;

    /// @notice Per-enterprise batch info: enterprise -> batchId -> StoredBatchInfo.
    mapping(address => mapping(uint256 => StoredBatchInfo)) public storedBatches;

    /// @notice Global counters for all enterprises.
    /// [Spec: BasisRollup.tla, lines 66-68 -- globalCommitted, globalProven, globalExecuted]
    uint256 public totalBatchesCommitted;
    uint256 public totalBatchesProven;
    uint256 public totalBatchesExecuted;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event BatchCommitted(
        address indexed enterprise,
        uint256 indexed batchId,
        bytes32 batchHash,
        bytes32 newStateRoot,
        uint64 l2BlockStart,
        uint64 l2BlockEnd,
        uint256 timestamp
    );

    event BatchProven(
        address indexed enterprise,
        uint256 indexed batchId,
        uint256 timestamp
    );

    event BatchExecuted(
        address indexed enterprise,
        uint256 indexed batchId,
        bytes32 prevRoot,
        bytes32 newRoot,
        uint256 timestamp
    );

    event BatchReverted(
        address indexed enterprise,
        uint256 indexed batchId,
        uint256 timestamp
    );

    event EnterpriseInitialized(
        address indexed enterprise,
        bytes32 genesisRoot,
        uint256 timestamp
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error OnlyAdmin();
    error NotAuthorized();
    error VerifyingKeyNotSet();
    error EnterpriseNotInitialized();
    error EnterpriseAlreadyInitialized();
    error InvalidProof();
    error BatchNotCommitted();
    error BatchNotProven();
    error BatchAlreadyProven();
    error BatchAlreadyExecuted();
    error BatchNotNextToExecute();
    error BatchNotNextToProve();
    error InvalidBlockRange();
    error BlockRangeGap(uint64 expected, uint64 provided);
    error RootChainBroken(bytes32 expected, bytes32 provided);
    error NothingToRevert();
    error CannotRevertExecuted();

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // -----------------------------------------------------------------------
    // Constructor
    // [Spec: BasisRollup.tla, lines 98-108 -- Init]
    // -----------------------------------------------------------------------

    /// @notice Deploys the BasisRollup contract.
    /// @param _enterpriseRegistry Address of the EnterpriseRegistry contract.
    constructor(address _enterpriseRegistry) {
        admin = msg.sender;
        enterpriseRegistry = IEnterpriseRegistry(_enterpriseRegistry);
    }

    // -----------------------------------------------------------------------
    // Admin Functions
    // -----------------------------------------------------------------------

    /// @notice Sets the Groth16 verifying key for the L2 state transition circuit.
    /// @param _alfa1 The alfa1 point of the verifying key.
    /// @param _beta2 The beta2 point of the verifying key.
    /// @param _gamma2 The gamma2 point of the verifying key.
    /// @param _delta2 The delta2 point of the verifying key.
    /// @param _IC The IC points of the verifying key.
    function setVerifyingKey(
        uint256[2] calldata _alfa1,
        uint256[2][2] calldata _beta2,
        uint256[2][2] calldata _gamma2,
        uint256[2][2] calldata _delta2,
        uint256[2][] calldata _IC
    ) external onlyAdmin {
        vk.alfa1 = _alfa1;
        vk.beta2 = _beta2;
        vk.gamma2 = _gamma2;
        vk.delta2 = _delta2;
        delete vk.IC;
        for (uint256 i = 0; i < _IC.length; i++) {
            vk.IC.push(_IC[i]);
        }
        verifyingKeySet = true;
    }

    /// @notice Initializes an enterprise's state chain with a genesis root.
    /// @dev [Spec: BasisRollup.tla, lines 121-128 -- InitializeEnterprise(e, genesisRoot)]
    ///      Guard: enterprise must not already be initialized.
    ///      Effect: currentRoot = genesisRoot, initialized = true.
    ///      Enforces: INV-09 InitBeforeBatch, INV-08 NoReversal.
    /// @param enterprise The address of the enterprise to initialize.
    /// @param genesisRoot The initial state root (hash of empty SMT).
    function initializeEnterprise(
        address enterprise,
        bytes32 genesisRoot
    ) external onlyAdmin {
        if (enterprises[enterprise].initialized) revert EnterpriseAlreadyInitialized();

        enterprises[enterprise] = EnterpriseState({
            currentRoot: genesisRoot,
            totalBatchesCommitted: 0,
            totalBatchesProven: 0,
            totalBatchesExecuted: 0,
            initialized: true,
            lastL2Block: 0
        });

        emit EnterpriseInitialized(enterprise, genesisRoot, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Phase 1: Commit
    // [Spec: BasisRollup.tla, lines 150-162 -- CommitBatch(e, newRoot)]
    // -----------------------------------------------------------------------

    /// @notice Commits a batch of L2 transactions. Sequencer posts batch metadata.
    /// @dev Stores keccak256(batchData) and metadata on-chain. Does not verify proofs.
    ///      Enforces: INV-R4 MonotonicBlockRange, INV-09 InitBeforeBatch,
    ///               INV-11 GlobalCountIntegrity, INV-12 BatchRootIntegrity.
    /// @param data The batch data including state root, L2 block range, and priority ops hash.
    function commitBatch(CommitBatchData calldata data) external {
        if (!enterpriseRegistry.isAuthorized(msg.sender)) revert NotAuthorized();

        EnterpriseState storage es = enterprises[msg.sender];
        if (!es.initialized) revert EnterpriseNotInitialized();

        // INV-R4: Block range must be valid and ascending
        if (data.l2BlockEnd < data.l2BlockStart) revert InvalidBlockRange();

        // INV-R4: Block range must be contiguous with previous batch
        uint64 expectedStart = es.lastL2Block == 0 ? 1 : es.lastL2Block + 1;
        if (data.l2BlockStart != expectedStart) {
            revert BlockRangeGap(expectedStart, data.l2BlockStart);
        }

        uint256 batchId = es.totalBatchesCommitted;

        // Compute batch hash for integrity verification in prove phase
        bytes32 batchHash = keccak256(abi.encode(
            msg.sender,
            batchId,
            data.newStateRoot,
            data.l2BlockStart,
            data.l2BlockEnd,
            data.priorityOpsHash,
            data.timestamp
        ));

        // Store batch info
        // INV-12 BatchRootIntegrity: committed batch gets a valid root
        storedBatches[msg.sender][batchId] = StoredBatchInfo({
            batchHash: batchHash,
            stateRoot: data.newStateRoot,
            l2BlockStart: data.l2BlockStart,
            l2BlockEnd: data.l2BlockEnd,
            status: BatchStatus.Committed
        });

        // Update enterprise state (NoGap: batchId auto-incremented)
        es.totalBatchesCommitted = uint64(batchId + 1);
        es.lastL2Block = data.l2BlockEnd;

        // INV-11 GlobalCountIntegrity: increment global counter
        totalBatchesCommitted++;

        emit BatchCommitted(
            msg.sender,
            batchId,
            batchHash,
            data.newStateRoot,
            data.l2BlockStart,
            data.l2BlockEnd,
            block.timestamp
        );
    }

    // -----------------------------------------------------------------------
    // Phase 2: Prove
    // [Spec: BasisRollup.tla, lines 183-195 -- ProveBatch(e, proofIsValid)]
    // -----------------------------------------------------------------------

    /// @notice Proves a committed batch with a Groth16 validity proof.
    /// @dev Enforces: INV-06 CommitBeforeProve, INV-03 ProveBeforeExecute (status gate),
    ///               INV-07 CounterMonotonicity, INV-11 GlobalCountIntegrity.
    /// @param batchId The batch to prove (must be next sequential unproven batch).
    /// @param a Groth16 proof point A.
    /// @param b Groth16 proof point B.
    /// @param c Groth16 proof point C.
    /// @param publicSignals Public inputs to the state transition circuit.
    function proveBatch(
        uint256 batchId,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata publicSignals
    ) external {
        if (!verifyingKeySet) revert VerifyingKeyNotSet();
        if (!enterpriseRegistry.isAuthorized(msg.sender)) revert NotAuthorized();

        EnterpriseState storage es = enterprises[msg.sender];
        if (!es.initialized) revert EnterpriseNotInitialized();

        // INV-06 CommitBeforeProve + sequential proving: must prove in order
        if (batchId != es.totalBatchesProven) revert BatchNotNextToProve();

        StoredBatchInfo storage batch = storedBatches[msg.sender][batchId];
        if (batch.status != BatchStatus.Committed) revert BatchNotCommitted();

        // INV-S2 ProofBeforeState: verify proof BEFORE any state change
        bool valid = _verifyProof(a, b, c, publicSignals);
        if (!valid) revert InvalidProof();

        // Transition: Committed -> Proven
        batch.status = BatchStatus.Proven;
        es.totalBatchesProven = uint64(batchId + 1);
        totalBatchesProven++;

        emit BatchProven(msg.sender, batchId, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Phase 3: Execute
    // [Spec: BasisRollup.tla, lines 216-228 -- ExecuteBatch(e)]
    // -----------------------------------------------------------------------

    /// @notice Executes a proven batch, finalizing the state root.
    /// @dev Enforces: INV-04 ExecuteInOrder, INV-03 ProveBeforeExecute,
    ///               INV-02 BatchChainContinuity, INV-07 CounterMonotonicity,
    ///               INV-11 GlobalCountIntegrity.
    /// @param batchId The batch to execute (must be next sequential unexecuted batch).
    function executeBatch(uint256 batchId) external {
        if (!enterpriseRegistry.isAuthorized(msg.sender)) revert NotAuthorized();

        EnterpriseState storage es = enterprises[msg.sender];
        if (!es.initialized) revert EnterpriseNotInitialized();

        // INV-04 ExecuteInOrder: sequential execution
        if (batchId != es.totalBatchesExecuted) revert BatchNotNextToExecute();

        StoredBatchInfo storage batch = storedBatches[msg.sender][batchId];
        // INV-03 ProveBeforeExecute: must be Proven
        if (batch.status != BatchStatus.Proven) revert BatchNotProven();

        // INV-02 BatchChainContinuity: advance currentRoot to batch's committed root
        bytes32 prevRoot = es.currentRoot;
        es.currentRoot = batch.stateRoot;
        es.totalBatchesExecuted = uint64(batchId + 1);
        batch.status = BatchStatus.Executed;
        totalBatchesExecuted++;

        emit BatchExecuted(
            msg.sender,
            batchId,
            prevRoot,
            batch.stateRoot,
            block.timestamp
        );
    }

    // -----------------------------------------------------------------------
    // Revert (Admin Safety)
    // [Spec: BasisRollup.tla, lines 249-268 -- RevertBatch(e)]
    // -----------------------------------------------------------------------

    /// @notice Reverts the last committed (but not executed) batch for an enterprise.
    /// @dev Enforces: INV-05 RevertSafety (executed batches cannot be reverted).
    ///      LIFO revert: always targets batchId = totalBatchesCommitted - 1.
    ///      If batch was Proven, also reverts the proven counter.
    /// @param enterprise The enterprise whose batch to revert.
    function revertBatch(address enterprise) external onlyAdmin {
        EnterpriseState storage es = enterprises[enterprise];
        if (!es.initialized) revert EnterpriseNotInitialized();
        if (es.totalBatchesCommitted == es.totalBatchesExecuted) revert NothingToRevert();

        uint256 batchId = es.totalBatchesCommitted - 1;
        StoredBatchInfo storage batch = storedBatches[enterprise][batchId];

        // INV-05 RevertSafety: cannot revert executed batches
        if (batch.status == BatchStatus.Executed) revert CannotRevertExecuted();

        // If batch was proven, revert the proven counter too
        if (batch.status == BatchStatus.Proven) {
            es.totalBatchesProven = uint64(batchId);
            totalBatchesProven--;
        }

        // Restore lastL2Block to the previous batch's end block
        if (batchId > 0) {
            es.lastL2Block = storedBatches[enterprise][batchId - 1].l2BlockEnd;
        } else {
            es.lastL2Block = 0;
        }

        // INV-12 BatchRootIntegrity: clear batch data (status -> None, root -> zero)
        delete storedBatches[enterprise][batchId];
        es.totalBatchesCommitted = uint64(batchId);
        totalBatchesCommitted--;

        emit BatchReverted(enterprise, batchId, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // View Functions
    // -----------------------------------------------------------------------

    /// @notice Returns the current finalized state root for an enterprise.
    function getCurrentRoot(address enterprise) external view returns (bytes32) {
        return enterprises[enterprise].currentRoot;
    }

    /// @notice Returns the stored batch info for a specific batch.
    function getBatchInfo(
        address enterprise,
        uint256 batchId
    ) external view returns (
        bytes32 batchHash,
        bytes32 stateRoot,
        uint64 l2BlockStart,
        uint64 l2BlockEnd,
        BatchStatus status
    ) {
        StoredBatchInfo storage b = storedBatches[enterprise][batchId];
        return (b.batchHash, b.stateRoot, b.l2BlockStart, b.l2BlockEnd, b.status);
    }

    /// @notice Returns the batch counts for an enterprise.
    function getBatchCounts(address enterprise) external view returns (
        uint64 committed,
        uint64 proven,
        uint64 executed
    ) {
        EnterpriseState storage es = enterprises[enterprise];
        return (es.totalBatchesCommitted, es.totalBatchesProven, es.totalBatchesExecuted);
    }

    /// @notice Returns the highest finalized L2 block number for an enterprise.
    function getLastL2Block(address enterprise) external view returns (uint64) {
        return enterprises[enterprise].lastL2Block;
    }

    /// @notice Checks if a specific state root was finalized at a given batch.
    function isExecutedRoot(
        address enterprise,
        uint256 batchId,
        bytes32 root
    ) external view returns (bool) {
        StoredBatchInfo storage b = storedBatches[enterprise][batchId];
        return b.status == BatchStatus.Executed && b.stateRoot == root;
    }

    // -----------------------------------------------------------------------
    // Internal: Groth16 Verification (Inline)
    // -----------------------------------------------------------------------

    /// @dev Verifies a Groth16 proof against the stored verifying key.
    ///      Inline to avoid cross-contract call overhead (~56K gas saved).
    ///      Uses EIP-196 (ecAdd, ecMul) and EIP-197 (ecPairing) precompiles.
    ///      Virtual for test harness override.
    function _verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata input
    ) internal view virtual returns (bool) {
        require(input.length + 1 == vk.IC.length, "Invalid input length");

        uint256[2] memory vk_x = [vk.IC[0][0], vk.IC[0][1]];

        for (uint256 i = 0; i < input.length; i++) {
            uint256[2] memory mul_result = _ecMul(vk.IC[i + 1], input[i]);
            vk_x = _ecAdd(vk_x, mul_result);
        }

        return _ecPairing(
            _negate(a),
            b,
            vk.alfa1,
            vk.beta2,
            vk_x,
            vk.gamma2,
            c,
            vk.delta2
        );
    }

    function _negate(
        uint256[2] calldata p
    ) internal pure returns (uint256[2] memory) {
        uint256 q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        if (p[0] == 0 && p[1] == 0) return [uint256(0), uint256(0)];
        return [p[0], q - (p[1] % q)];
    }

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
