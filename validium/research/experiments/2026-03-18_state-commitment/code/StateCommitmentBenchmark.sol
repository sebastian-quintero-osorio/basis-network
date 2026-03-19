// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title StateCommitmentBenchmark -- Gas Measurement Harness
/// @notice Identical to V1/V2 but with mock proof verification for precise gas measurement.
/// @dev The mock allows isolating storage + logic gas from ZK verification gas.
///      Real ZK verification gas is a known constant (~205,600) added analytically.

// --- Layout A: Minimal (roots only, metadata in events) ---

contract BenchmarkMinimal {

    struct EnterpriseState {
        bytes32 currentRoot;
        uint64 batchCount;
        uint64 lastTimestamp;
        bool initialized;
    }

    address public admin;
    mapping(address => EnterpriseState) public enterprises;
    mapping(address => mapping(uint256 => bytes32)) public batchRoots;
    uint256 public totalBatchesCommitted;

    event BatchCommitted(
        address indexed enterprise,
        uint256 indexed batchId,
        bytes32 prevRoot,
        bytes32 newRoot,
        uint256 batchSize,
        uint256 timestamp
    );

    error EnterpriseNotInitialized();
    error EnterpriseAlreadyInitialized();
    error RootChainBroken(bytes32 expected, bytes32 provided);
    error OnlyAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function initializeEnterprise(address enterprise, bytes32 genesisRoot) external onlyAdmin {
        if (enterprises[enterprise].initialized) revert EnterpriseAlreadyInitialized();
        enterprises[enterprise] = EnterpriseState({
            currentRoot: genesisRoot,
            batchCount: 0,
            lastTimestamp: uint64(block.timestamp),
            initialized: true
        });
    }

    /// @notice Submit batch with mock verification. Measures storage + logic gas only.
    function submitBatch(
        bytes32 prevStateRoot,
        bytes32 newStateRoot,
        uint256 batchSize
    ) external {
        EnterpriseState storage es = enterprises[msg.sender];
        if (!es.initialized) revert EnterpriseNotInitialized();

        // ChainContinuity check
        if (es.currentRoot != prevStateRoot) {
            revert RootChainBroken(es.currentRoot, prevStateRoot);
        }

        // Mock verification (always passes) -- real cost is ~205,600 gas
        // This isolates storage layout gas from verification gas

        uint256 batchId = es.batchCount;

        // State update
        es.currentRoot = newStateRoot;
        es.batchCount = uint64(batchId + 1);
        es.lastTimestamp = uint64(block.timestamp);

        // History: 1 slot per batch
        batchRoots[msg.sender][batchId] = newStateRoot;

        totalBatchesCommitted++;

        emit BatchCommitted(
            msg.sender, batchId, prevStateRoot, newStateRoot, batchSize, block.timestamp
        );
    }

    function getCurrentRoot(address enterprise) external view returns (bytes32) {
        return enterprises[enterprise].currentRoot;
    }

    function getBatchRoot(address enterprise, uint256 batchId) external view returns (bytes32) {
        return batchRoots[enterprise][batchId];
    }
}

// --- Layout B: Rich (roots + packed metadata on-chain) ---

contract BenchmarkRich {

    struct EnterpriseState {
        bytes32 currentRoot;
        uint64 batchCount;
        uint64 lastTimestamp;
        bool initialized;
    }

    struct BatchInfo {
        bytes32 newRoot;
        uint64 batchSize;
        uint64 timestamp;
        uint64 cumulativeTx;
    }

    address public admin;
    mapping(address => EnterpriseState) public enterprises;
    mapping(address => mapping(uint256 => BatchInfo)) public batchHistory;
    uint256 public totalBatchesCommitted;

    event BatchCommitted(
        address indexed enterprise,
        uint256 indexed batchId,
        bytes32 prevRoot,
        bytes32 newRoot,
        uint256 batchSize,
        uint256 timestamp
    );

    error EnterpriseNotInitialized();
    error EnterpriseAlreadyInitialized();
    error RootChainBroken(bytes32 expected, bytes32 provided);
    error OnlyAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function initializeEnterprise(address enterprise, bytes32 genesisRoot) external onlyAdmin {
        if (enterprises[enterprise].initialized) revert EnterpriseAlreadyInitialized();
        enterprises[enterprise] = EnterpriseState({
            currentRoot: genesisRoot,
            batchCount: 0,
            lastTimestamp: uint64(block.timestamp),
            initialized: true
        });
    }

    /// @notice Submit batch with mock verification. Stores rich metadata.
    function submitBatch(
        bytes32 prevStateRoot,
        bytes32 newStateRoot,
        uint256 batchSize
    ) external {
        EnterpriseState storage es = enterprises[msg.sender];
        if (!es.initialized) revert EnterpriseNotInitialized();

        if (es.currentRoot != prevStateRoot) {
            revert RootChainBroken(es.currentRoot, prevStateRoot);
        }

        uint256 batchId = es.batchCount;

        es.currentRoot = newStateRoot;
        es.batchCount = uint64(batchId + 1);
        es.lastTimestamp = uint64(block.timestamp);

        // Rich history: 2 slots per batch (newRoot + packed metadata)
        uint64 prevCumTx = batchId > 0
            ? batchHistory[msg.sender][batchId - 1].cumulativeTx
            : 0;

        batchHistory[msg.sender][batchId] = BatchInfo({
            newRoot: newStateRoot,
            batchSize: uint64(batchSize),
            timestamp: uint64(block.timestamp),
            cumulativeTx: prevCumTx + uint64(batchSize)
        });

        totalBatchesCommitted++;

        emit BatchCommitted(
            msg.sender, batchId, prevStateRoot, newStateRoot, batchSize, block.timestamp
        );
    }

    function getCurrentRoot(address enterprise) external view returns (bytes32) {
        return enterprises[enterprise].currentRoot;
    }

    function getBatchInfo(address enterprise, uint256 batchId)
        external view returns (bytes32, uint64, uint64, uint64)
    {
        BatchInfo storage b = batchHistory[enterprise][batchId];
        return (b.newRoot, b.batchSize, b.timestamp, b.cumulativeTx);
    }
}

// --- Layout C: Events Only (no per-batch storage, minimal state) ---

contract BenchmarkEventsOnly {

    struct EnterpriseState {
        bytes32 currentRoot;
        uint64 batchCount;
        uint64 lastTimestamp;
        bool initialized;
    }

    address public admin;
    mapping(address => EnterpriseState) public enterprises;
    uint256 public totalBatchesCommitted;

    event BatchCommitted(
        address indexed enterprise,
        uint256 indexed batchId,
        bytes32 prevRoot,
        bytes32 newRoot,
        uint256 batchSize,
        uint256 timestamp
    );

    error EnterpriseNotInitialized();
    error EnterpriseAlreadyInitialized();
    error RootChainBroken(bytes32 expected, bytes32 provided);
    error OnlyAdmin();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    function initializeEnterprise(address enterprise, bytes32 genesisRoot) external onlyAdmin {
        if (enterprises[enterprise].initialized) revert EnterpriseAlreadyInitialized();
        enterprises[enterprise] = EnterpriseState({
            currentRoot: genesisRoot,
            batchCount: 0,
            lastTimestamp: uint64(block.timestamp),
            initialized: true
        });
    }

    /// @notice Submit batch. NO per-batch storage. All metadata in events only.
    function submitBatch(
        bytes32 prevStateRoot,
        bytes32 newStateRoot,
        uint256 batchSize
    ) external {
        EnterpriseState storage es = enterprises[msg.sender];
        if (!es.initialized) revert EnterpriseNotInitialized();

        if (es.currentRoot != prevStateRoot) {
            revert RootChainBroken(es.currentRoot, prevStateRoot);
        }

        uint256 batchId = es.batchCount;

        es.currentRoot = newStateRoot;
        es.batchCount = uint64(batchId + 1);
        es.lastTimestamp = uint64(block.timestamp);

        // NO batchRoots storage -- metadata only in event
        totalBatchesCommitted++;

        emit BatchCommitted(
            msg.sender, batchId, prevStateRoot, newStateRoot, batchSize, block.timestamp
        );
    }

    function getCurrentRoot(address enterprise) external view returns (bytes32) {
        return enterprises[enterprise].currentRoot;
    }
}
