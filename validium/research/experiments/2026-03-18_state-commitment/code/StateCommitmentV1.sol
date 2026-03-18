// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title StateCommitmentV1 -- Minimal Layout (Integrated Verification)
/// @notice Per-enterprise state root chains with integrated Groth16 verification.
/// @dev Layout V1: Only state roots stored in mapping. Batch metadata emitted via events.
///      Target: < 300K gas per submission, < 500 bytes storage per batch.
///      This variant stores 1 slot (32 bytes) of new state per batch.
contract StateCommitmentV1 {

    // -- Structs --

    struct VerifyingKey {
        uint256[2] alfa1;
        uint256[2][2] beta2;
        uint256[2][2] gamma2;
        uint256[2][2] delta2;
        uint256[2][] IC;
    }

    struct EnterpriseState {
        bytes32 currentRoot;
        uint64 batchCount;
        uint64 lastTimestamp;
        bool initialized;
    }

    // -- State --

    address public admin;
    address public enterpriseRegistry;
    VerifyingKey private vk;
    bool public verifyingKeySet;

    /// @notice Per-enterprise state chain head.
    mapping(address => EnterpriseState) public enterprises;

    /// @notice Per-enterprise batch history: enterprise -> batchId -> stateRoot.
    mapping(address => mapping(uint256 => bytes32)) public batchRoots;

    // -- Global counters --

    uint256 public totalBatchesCommitted;

    // -- Events --

    event BatchCommitted(
        address indexed enterprise,
        uint256 indexed batchId,
        bytes32 prevRoot,
        bytes32 newRoot,
        uint256 batchSize,
        uint256 timestamp
    );

    event EnterpriseInitialized(
        address indexed enterprise,
        bytes32 genesisRoot,
        uint256 timestamp
    );

    // -- Errors --

    error NotAuthorized();
    error VerifyingKeyNotSet();
    error EnterpriseNotInitialized();
    error EnterpriseAlreadyInitialized();
    error RootChainBroken(bytes32 expected, bytes32 provided);
    error InvalidProof();
    error OnlyAdmin();

    // -- Modifiers --

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // -- Constructor --

    constructor(address _enterpriseRegistry) {
        admin = msg.sender;
        enterpriseRegistry = _enterpriseRegistry;
    }

    // -- Admin Functions --

    /// @notice Sets the Groth16 verifying key for the state transition circuit.
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
    /// @dev Must be called before the enterprise can submit batches.
    function initializeEnterprise(address enterprise, bytes32 genesisRoot) external onlyAdmin {
        if (enterprises[enterprise].initialized) revert EnterpriseAlreadyInitialized();
        enterprises[enterprise] = EnterpriseState({
            currentRoot: genesisRoot,
            batchCount: 0,
            lastTimestamp: uint64(block.timestamp),
            initialized: true
        });
        emit EnterpriseInitialized(enterprise, genesisRoot, block.timestamp);
    }

    // -- Core Function --

    /// @notice Submits a batch with ZK proof. Verifies proof and advances the state chain.
    /// @dev Enforces: ChainContinuity (prevRoot == currentRoot), NoGap (sequential batchId),
    ///      ProofBeforeState (proof must verify before state update).
    /// @param prevStateRoot The state root before this batch (must match current chain head).
    /// @param newStateRoot The state root after this batch.
    /// @param batchSize Number of transactions in the batch.
    /// @param a Groth16 proof point A.
    /// @param b Groth16 proof point B.
    /// @param c Groth16 proof point C.
    /// @param publicSignals Public inputs: [prevStateRoot, newStateRoot, batchNum, enterpriseId].
    function submitBatch(
        bytes32 prevStateRoot,
        bytes32 newStateRoot,
        uint256 batchSize,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata publicSignals
    ) external {
        if (!verifyingKeySet) revert VerifyingKeyNotSet();

        // Authorization check (inline to avoid cross-contract call in benchmark)
        // In production, this calls EnterpriseRegistry.isAuthorized(msg.sender)
        _checkAuthorized(msg.sender);

        EnterpriseState storage es = enterprises[msg.sender];
        if (!es.initialized) revert EnterpriseNotInitialized();

        // INV-S1: ChainContinuity -- prevRoot must match current chain head
        if (es.currentRoot != prevStateRoot) {
            revert RootChainBroken(es.currentRoot, prevStateRoot);
        }

        // INV-S2: ProofBeforeState -- verify ZK proof before any state change
        bool valid = _verifyProof(a, b, c, publicSignals);
        if (!valid) revert InvalidProof();

        // NoGap: batch ID is always sequential (es.batchCount is the next batch ID)
        uint256 batchId = es.batchCount;

        // State update (atomic with proof verification)
        es.currentRoot = newStateRoot;
        es.batchCount = uint64(batchId + 1);
        es.lastTimestamp = uint64(block.timestamp);

        // History: store only the new state root (32 bytes = 1 slot)
        batchRoots[msg.sender][batchId] = newStateRoot;

        totalBatchesCommitted++;

        // Metadata in event (not in storage -- saves ~22K gas per SSTORE avoided)
        emit BatchCommitted(
            msg.sender,
            batchId,
            prevStateRoot,
            newStateRoot,
            batchSize,
            block.timestamp
        );
    }

    // -- View Functions --

    /// @notice Returns the current state root for an enterprise.
    function getCurrentRoot(address enterprise) external view returns (bytes32) {
        return enterprises[enterprise].currentRoot;
    }

    /// @notice Returns the state root for a specific batch.
    function getBatchRoot(address enterprise, uint256 batchId) external view returns (bytes32) {
        return batchRoots[enterprise][batchId];
    }

    /// @notice Returns the batch count for an enterprise.
    function getBatchCount(address enterprise) external view returns (uint256) {
        return enterprises[enterprise].batchCount;
    }

    /// @notice Verifies that a state root exists in an enterprise's history.
    function isCommittedRoot(address enterprise, uint256 batchId, bytes32 root) external view returns (bool) {
        return batchRoots[enterprise][batchId] == root;
    }

    // -- Internal: Authorization --

    function _checkAuthorized(address enterprise) internal view {
        // Call EnterpriseRegistry.isAuthorized(enterprise)
        (bool success, bytes memory data) = enterpriseRegistry.staticcall(
            abi.encodeWithSignature("isAuthorized(address)", enterprise)
        );
        if (!success || (data.length >= 32 && abi.decode(data, (bool)) == false)) {
            revert NotAuthorized();
        }
    }

    // -- Internal: Groth16 Verification --

    function _verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata input
    ) internal view returns (bool) {
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

    function _negate(uint256[2] calldata p) internal pure returns (uint256[2] memory) {
        uint256 q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        if (p[0] == 0 && p[1] == 0) return [uint256(0), uint256(0)];
        return [p[0], q - (p[1] % q)];
    }

    function _ecAdd(uint256[2] memory p1, uint256[2] memory p2) internal view returns (uint256[2] memory r) {
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

    function _ecMul(uint256[2] memory p, uint256 s) internal view returns (uint256[2] memory r) {
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
