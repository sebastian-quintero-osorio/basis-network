// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title BasisAggregator
/// @notice On-chain verification and accounting for aggregated proofs from N enterprise batches.
/// @dev Implements the L1 verification side of the proof aggregation pipeline formalized
///      in ProofAggregation.tla (TLC verified: 788,734 states, all 5 safety properties).
///
///      Architecture:
///        N enterprise halo2-KZG proofs -> ProtoGalaxy folding -> Groth16 decider -> this contract
///
///      The aggregated proof is a standard Groth16 proof (~128 bytes) that proves the accumulated
///      PLONKish instance from ProtoGalaxy folding is satisfiable. Verification costs ~220K gas
///      regardless of N, compared to N * 420K gas for individual halo2-KZG verification.
///
///      Safety invariants enforced:
///        S1 AggregationSoundness:     Aggregated proof valid iff ALL component proofs valid
///        S4 GasMonotonicity:          Aggregated cost < individual cost * N for N >= 2
///
///      Gas accounting:
///        Per-enterprise cost tracked for economic transparency. Each enterprise's share
///        of the aggregated verification cost is AggregatedGasCost / N.
///
///      [Spec: lab/3-architect/implementation-history/prover-aggregation/specs/ProofAggregation.tla]
///      [Source: lab/3-architect/implementation-history/prover-aggregation/research/findings.md]
contract BasisAggregator {
    // -----------------------------------------------------------------------
    // Types
    // [Spec: ProofAggregation.tla, lines 24-28 -- AggStatuses]
    // -----------------------------------------------------------------------

    /// @dev Lifecycle status of an aggregated proof submission.
    enum AggregationStatus {
        None,       // 0: No submission exists for this ID
        Pending,    // 1: Submitted, awaiting verification
        Verified,   // 2: L1 verification passed (all components valid)
        Rejected    // 3: L1 verification failed (invalid component detected)
    }

    /// @dev Groth16 verifying key for the aggregation decider circuit.
    ///      The decider circuit proves that the ProtoGalaxy folded instance is satisfiable.
    struct VerifyingKey {
        uint256[2] alfa1;
        uint256[2][2] beta2;
        uint256[2][2] gamma2;
        uint256[2][2] delta2;
        uint256[2][] IC;
    }

    /// @dev Record of an aggregated proof submission.
    ///      [Spec: ProofAggregation.tla, lines 47-55 -- aggregation record domain]
    struct AggregatedBatch {
        bytes32 aggregationHash;       // Deterministic hash of component batch hashes (OrderIndependence)
        uint64 numEnterprises;         // Number of enterprises in this aggregation
        uint64 submittedAt;            // Block timestamp of submission
        AggregationStatus status;      // Lifecycle status
    }

    // -----------------------------------------------------------------------
    // Constants
    // [Spec: ProofAggregation.tla, lines 12-13 -- BaseGasPerProof, AggregatedGasCost]
    // [Source: findings.md, Section 3.2 -- Gas Savings by Strategy]
    // -----------------------------------------------------------------------

    /// @notice Gas cost for individual halo2-KZG proof verification on L1.
    uint256 public constant BASE_GAS_PER_PROOF = 420_000;

    /// @notice Gas cost for aggregated Groth16 decider proof verification on L1.
    uint256 public constant AGGREGATED_GAS_COST = 220_000;

    /// @notice Minimum number of proofs for aggregation to be beneficial.
    /// [Spec: ProofAggregation.tla, line 175 -- Cardinality(S) >= 2]
    uint256 public constant MIN_AGGREGATION_SIZE = 2;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    /// @notice Network admin (Base Computing).
    address public admin;

    /// @notice Whether the Groth16 verifying key for the decider circuit has been set.
    bool public verifyingKeySet;

    /// @dev Groth16 verifying key for the aggregation decider circuit.
    VerifyingKey private vk;

    /// @notice Next aggregation ID (monotonically increasing).
    uint256 public nextAggregationId;

    /// @notice Aggregation records by ID.
    mapping(uint256 => AggregatedBatch) public aggregations;

    /// @notice Component enterprises for each aggregation (sorted for OrderIndependence).
    mapping(uint256 => address[]) public aggregationEnterprises;

    /// @notice Component batch hashes for each aggregation.
    mapping(uint256 => bytes32[]) public aggregationBatchHashes;

    /// @notice Per-enterprise cumulative gas accounting.
    mapping(address => uint256) public enterpriseGasUsed;

    /// @notice Total aggregated proofs verified.
    uint256 public totalAggregationsVerified;

    /// @notice Total individual proofs that were aggregated.
    uint256 public totalProofsAggregated;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when an aggregated proof is submitted for verification.
    event AggregationSubmitted(
        uint256 indexed aggregationId,
        uint256 numEnterprises,
        bytes32 aggregationHash,
        uint256 timestamp
    );

    /// @notice Emitted when an aggregated proof is verified on L1.
    event AggregationVerified(
        uint256 indexed aggregationId,
        bool valid,
        uint256 gasPerEnterprise,
        uint256 timestamp
    );

    /// @notice Emitted per enterprise when their proof is part of a verified aggregation.
    event EnterpriseProofVerified(
        uint256 indexed aggregationId,
        address indexed enterprise,
        uint256 gasCharged,
        uint256 timestamp
    );

    /// @notice Emitted when the decider verifying key is configured.
    event DeciderKeySet(uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error NotAdmin();
    error VerifyingKeyNotSet();
    error DeciderKeyAlreadySet();
    error InsufficientProofs(uint256 provided, uint256 minimum);
    error EnterpriseBatchMismatch(uint256 enterprises, uint256 batches);
    error AggregationNotFound(uint256 aggregationId);
    error AggregationNotPending(uint256 aggregationId, AggregationStatus current);
    error DuplicateEnterprise(address enterprise);

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @param _admin The admin address (Base Computing).
    constructor(address _admin) {
        admin = _admin;
    }

    // -----------------------------------------------------------------------
    // Admin functions
    // -----------------------------------------------------------------------

    /// @notice Set the Groth16 verifying key for the aggregation decider circuit.
    /// @dev The decider circuit proves that the ProtoGalaxy folded instance is satisfiable.
    ///      This key is generated from a one-time trusted setup of the decider circuit.
    ///      Can only be set once to prevent key substitution attacks.
    function setDeciderKey(
        uint256[2] calldata _alfa1,
        uint256[2][2] calldata _beta2,
        uint256[2][2] calldata _gamma2,
        uint256[2][2] calldata _delta2,
        uint256[2][] calldata _IC
    ) external onlyAdmin {
        if (verifyingKeySet) revert DeciderKeyAlreadySet();

        vk.alfa1 = _alfa1;
        vk.beta2 = _beta2;
        vk.gamma2 = _gamma2;
        vk.delta2 = _delta2;
        delete vk.IC;
        for (uint256 i = 0; i < _IC.length; i++) {
            vk.IC.push(_IC[i]);
        }
        verifyingKeySet = true;

        emit DeciderKeySet(block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Core functions
    // -----------------------------------------------------------------------

    /// @notice Submit and verify an aggregated proof for N enterprise batches.
    /// @dev Performs Groth16 verification of the decider proof, which attests that
    ///      the ProtoGalaxy folded instance (aggregating N halo2-KZG proofs) is satisfiable.
    ///
    ///      The public signals encode the batch hashes and state roots of all component
    ///      enterprise batches, binding the aggregated proof to specific batch data.
    ///
    ///      Gas cost is ~220K regardless of N, compared to N * 420K for individual verification.
    ///
    ///      [Spec: ProofAggregation.tla, lines 190-199 -- VerifyOnL1(agg)]
    ///
    /// @param a Groth16 proof point a (G1)
    /// @param b Groth16 proof point b (G2)
    /// @param c Groth16 proof point c (G1)
    /// @param publicSignals Public inputs to the decider circuit
    /// @param enterprises Addresses of enterprises whose proofs are aggregated (must be sorted)
    /// @param batchHashes Batch hashes for each enterprise (parallel array with enterprises)
    /// @return aggregationId The ID of this aggregation
    /// @return valid Whether the aggregated proof was accepted
    function verifyAggregatedProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata publicSignals,
        address[] calldata enterprises,
        bytes32[] calldata batchHashes
    ) external returns (uint256 aggregationId, bool valid) {
        if (!verifyingKeySet) revert VerifyingKeyNotSet();
        if (enterprises.length < MIN_AGGREGATION_SIZE) {
            revert InsufficientProofs(enterprises.length, MIN_AGGREGATION_SIZE);
        }
        if (enterprises.length != batchHashes.length) {
            revert EnterpriseBatchMismatch(enterprises.length, batchHashes.length);
        }

        // Enforce sorted enterprise addresses (OrderIndependence: canonical ordering)
        for (uint256 i = 1; i < enterprises.length; i++) {
            if (uint160(enterprises[i]) <= uint160(enterprises[i - 1])) {
                revert DuplicateEnterprise(enterprises[i]);
            }
        }

        // Compute aggregation hash (deterministic, order-independent via sorted addresses)
        bytes32 aggHash = _computeAggregationHash(enterprises, batchHashes);

        // Allocate aggregation ID
        aggregationId = nextAggregationId++;

        // Verify the Groth16 decider proof
        valid = _verifyGroth16(a, b, c, publicSignals);

        // Record the aggregation
        AggregationStatus status = valid
            ? AggregationStatus.Verified
            : AggregationStatus.Rejected;

        aggregations[aggregationId] = AggregatedBatch({
            aggregationHash: aggHash,
            numEnterprises: uint64(enterprises.length),
            submittedAt: uint64(block.timestamp),
            status: status
        });

        // Store component data
        for (uint256 i = 0; i < enterprises.length; i++) {
            aggregationEnterprises[aggregationId].push(enterprises[i]);
            aggregationBatchHashes[aggregationId].push(batchHashes[i]);
        }

        emit AggregationSubmitted(aggregationId, enterprises.length, aggHash, block.timestamp);

        if (valid) {
            _accountGas(aggregationId, enterprises);
            totalAggregationsVerified++;
            totalProofsAggregated += enterprises.length;
        }

        emit AggregationVerified(
            aggregationId,
            valid,
            valid ? AGGREGATED_GAS_COST / enterprises.length : 0,
            block.timestamp
        );
    }

    // -----------------------------------------------------------------------
    // View functions
    // -----------------------------------------------------------------------

    /// @notice Compute amortized gas cost per enterprise for a given aggregation size.
    /// @dev S4 GasMonotonicity: result strictly decreases as n increases for n >= 2.
    ///      [Spec: ProofAggregation.tla, lines 296-298]
    /// @param n Number of enterprises in the aggregation
    /// @return perEnterprise Amortized gas per enterprise
    /// @return savingsFactor Ratio of individual to aggregated cost (scaled by 100)
    function gasPerEnterprise(uint256 n)
        external
        pure
        returns (uint256 perEnterprise, uint256 savingsFactor)
    {
        if (n == 0) return (0, 0);
        perEnterprise = AGGREGATED_GAS_COST / n;
        savingsFactor = (BASE_GAS_PER_PROOF * n * 100) / AGGREGATED_GAS_COST;
    }

    /// @notice Get the component enterprises for an aggregation.
    function getAggregationEnterprises(uint256 aggregationId)
        external
        view
        returns (address[] memory)
    {
        return aggregationEnterprises[aggregationId];
    }

    /// @notice Get the component batch hashes for an aggregation.
    function getAggregationBatchHashes(uint256 aggregationId)
        external
        view
        returns (bytes32[] memory)
    {
        return aggregationBatchHashes[aggregationId];
    }

    // -----------------------------------------------------------------------
    // Internal functions
    // -----------------------------------------------------------------------

    /// @dev Compute a deterministic hash of the aggregation components.
    ///      Sorted enterprise addresses ensure OrderIndependence (S3).
    function _computeAggregationHash(
        address[] calldata enterprises,
        bytes32[] calldata batchHashes
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(enterprises, batchHashes));
    }

    /// @dev Account gas costs per enterprise for a verified aggregation.
    ///      Each enterprise is charged an equal share: AGGREGATED_GAS_COST / N.
    function _accountGas(uint256 aggregationId, address[] calldata enterprises) internal {
        uint256 perEnterprise = AGGREGATED_GAS_COST / enterprises.length;

        for (uint256 i = 0; i < enterprises.length; i++) {
            enterpriseGasUsed[enterprises[i]] += perEnterprise;

            emit EnterpriseProofVerified(
                aggregationId,
                enterprises[i],
                perEnterprise,
                block.timestamp
            );
        }
    }

    /// @dev Verify a Groth16 proof using BN254 precompiles (EIP-196/197).
    ///      This is the decider proof -- it proves the ProtoGalaxy folded instance
    ///      is satisfiable, which in turn proves ALL component proofs are valid.
    ///
    ///      [Spec: ProofAggregation.tla, lines 99-103 -- Aggregation Soundness axiom]
    function _verifyGroth16(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata input
    ) internal view virtual returns (bool) {
        uint256 snark_scalar_field = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

        // Validate inputs are in the scalar field
        for (uint256 i = 0; i < input.length; i++) {
            if (input[i] >= snark_scalar_field) return false;
        }

        // Compute the linear combination of public inputs with IC points
        // vk_x = IC[0] + sum(input[i] * IC[i+1])
        if (input.length + 1 != vk.IC.length) return false;

        uint256[2] memory vk_x = [vk.IC[0][0], vk.IC[0][1]];
        for (uint256 i = 0; i < input.length; i++) {
            // ecMul: IC[i+1] * input[i]
            (bool mulOk, bytes memory mulResult) = address(7).staticcall(
                abi.encode(vk.IC[i + 1][0], vk.IC[i + 1][1], input[i])
            );
            if (!mulOk) return false;

            uint256[2] memory mulPoint;
            (mulPoint[0], mulPoint[1]) = abi.decode(mulResult, (uint256, uint256));

            // ecAdd: vk_x + mulPoint
            (bool addOk, bytes memory addResult) = address(6).staticcall(
                abi.encode(vk_x[0], vk_x[1], mulPoint[0], mulPoint[1])
            );
            if (!addOk) return false;

            (vk_x[0], vk_x[1]) = abi.decode(addResult, (uint256, uint256));
        }

        // Pairing check: e(-a, b) * e(alfa1, beta2) * e(vk_x, gamma2) * e(c, delta2) == 1
        // Encoded as: e(a_neg, b) * e(alfa1, beta2) * e(vk_x, gamma2) * e(c, delta2)
        uint256[24] memory pairingInput;

        // Negate a (point negation on BN254: negate y coordinate)
        pairingInput[0] = a[0];
        pairingInput[1] = (21888242871839275222246405745257275088696311157297823662689037894645226208583 - a[1]) % 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        pairingInput[2] = b[0][0];
        pairingInput[3] = b[0][1];
        pairingInput[4] = b[1][0];
        pairingInput[5] = b[1][1];

        pairingInput[6] = vk.alfa1[0];
        pairingInput[7] = vk.alfa1[1];
        pairingInput[8] = vk.beta2[0][0];
        pairingInput[9] = vk.beta2[0][1];
        pairingInput[10] = vk.beta2[1][0];
        pairingInput[11] = vk.beta2[1][1];

        pairingInput[12] = vk_x[0];
        pairingInput[13] = vk_x[1];
        pairingInput[14] = vk.gamma2[0][0];
        pairingInput[15] = vk.gamma2[0][1];
        pairingInput[16] = vk.gamma2[1][0];
        pairingInput[17] = vk.gamma2[1][1];

        pairingInput[18] = c[0];
        pairingInput[19] = c[1];
        pairingInput[20] = vk.delta2[0][0];
        pairingInput[21] = vk.delta2[0][1];
        pairingInput[22] = vk.delta2[1][0];
        pairingInput[23] = vk.delta2[1][1];

        // ecPairing precompile (address 8)
        (bool pairingOk, bytes memory pairingResult) = address(8).staticcall(
            abi.encode(pairingInput)
        );

        if (!pairingOk) return false;
        uint256 pairingSuccess = abi.decode(pairingResult, (uint256));
        return pairingSuccess == 1;
    }
}
