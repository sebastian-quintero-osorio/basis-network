// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "../core/StateCommitment.sol";
import "../core/EnterpriseRegistry.sol";

/// @title CrossEnterpriseVerifier
/// @notice Verifies cross-enterprise interactions on L1 using ZK proofs.
/// @dev Implements the hub-and-spoke proof aggregation model where the L1 contract
///      aggregates proofs from multiple enterprises and verifies cross-enterprise
///      interactions without revealing private data from either party.
///
///      The cross-reference proof verifies:
///        1. Merkle inclusion of a record in Enterprise A's state tree
///        2. Merkle inclusion of a record in Enterprise B's state tree
///        3. An interaction commitment binding both records
///
///      Public inputs (3 field elements):
///        - stateRootA (already public from individual submission)
///        - stateRootB (already public from individual submission)
///        - interactionCommitment (Poseidon hash, reveals only existence)
///
///      Privacy: All Merkle paths, keys, and values remain private (Groth16 ZK, 128-bit).
///
/// [Spec: validium/specs/units/2026-03-cross-enterprise/1-formalization/v0-analysis/specs/CrossEnterprise/CrossEnterprise.tla]
///
/// Safety invariants enforced:
///   Isolation:           no enterprise state root is modified by cross-ref operations
///   Consistency:         cross-ref verified ONLY when both batch proofs are verified
///   NoCrossRefSelfLoop:  enterpriseA != enterpriseB enforced structurally
contract CrossEnterpriseVerifier {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    /// @dev Cross-reference lifecycle states.
    /// [Spec: crossRefStatus \in [CrossRefIds -> {"none","pending","verified","rejected"}]]
    enum CrossRefState {
        None,       // 0 -- default, no reference exists
        Pending,    // 1 -- requested, awaiting proof verification
        Verified,   // 2 -- both proofs verified, interaction confirmed
        Rejected    // 3 -- at least one proof failed
    }

    /// @dev Groth16 verifying key for the cross-reference circuit.
    struct VerifyingKey {
        uint256[2] alfa1;
        uint256[2][2] beta2;
        uint256[2][2] gamma2;
        uint256[2][2] delta2;
        uint256[2][] IC;
    }

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    /// @notice Network admin address (Base Computing).
    address public admin;

    /// @notice Reference to the StateCommitment contract for batch verification queries.
    StateCommitment public immutable stateCommitment;

    /// @notice Reference to the EnterpriseRegistry for authorization checks.
    EnterpriseRegistry public immutable enterpriseRegistry;

    /// @dev Groth16 verifying key for the cross-reference circuit.
    VerifyingKey private vk;

    /// @notice Whether the cross-reference verifying key has been configured.
    bool public verifyingKeySet;

    /// @notice Cross-reference status indexed by refId.
    /// refId = keccak256(abi.encode(enterpriseA, enterpriseB, batchIdA, batchIdB))
    /// [Spec: crossRefStatus variable]
    mapping(bytes32 => CrossRefState) public crossReferenceStatus;

    /// @notice Total number of verified cross-references.
    uint256 public totalCrossRefsVerified;

    /// @notice Total number of rejected cross-references.
    uint256 public totalCrossRefsRejected;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @dev Emitted when a cross-reference is verified on L1.
    /// [Spec: VerifyCrossRef action -- transition: pending -> verified]
    event CrossReferenceVerified(
        bytes32 indexed refId,
        address indexed enterpriseA,
        address indexed enterpriseB,
        uint256 batchIdA,
        uint256 batchIdB,
        bytes32 interactionCommitment,
        uint256 timestamp
    );

    /// @dev Emitted when a cross-reference is rejected on L1.
    /// [Spec: RejectCrossRef action -- transition: pending -> rejected]
    event CrossReferenceRejected(
        bytes32 indexed refId,
        address indexed enterpriseA,
        address indexed enterpriseB,
        uint256 batchIdA,
        uint256 batchIdB,
        string reason,
        uint256 timestamp
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error OnlyAdmin();
    error VerifyingKeyNotSet();

    /// @dev NoCrossRefSelfLoop violation: enterpriseA == enterpriseB.
    error SelfReference();

    /// @dev Consistency violation: source enterprise batch not verified on L1.
    error SourceBatchNotVerified(address enterprise, uint256 batchId);

    /// @dev Consistency violation: destination enterprise batch not verified on L1.
    error DestBatchNotVerified(address enterprise, uint256 batchId);

    /// @dev Enterprise not registered or not active.
    error EnterpriseNotAuthorized(address enterprise);

    /// @dev State root provided does not match the batch root on L1.
    error StateRootMismatch(address enterprise, uint256 batchId, bytes32 expected, bytes32 provided);

    /// @dev Cross-reference already in a terminal state (verified or rejected).
    error CrossRefAlreadyResolved(bytes32 refId);

    /// @dev Groth16 proof verification failed.
    error InvalidCrossRefProof();

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @notice Deploys the CrossEnterpriseVerifier contract.
    /// @param _stateCommitment Address of the StateCommitment contract.
    /// @param _enterpriseRegistry Address of the EnterpriseRegistry contract.
    constructor(address _stateCommitment, address _enterpriseRegistry) {
        admin = msg.sender;
        stateCommitment = StateCommitment(_stateCommitment);
        enterpriseRegistry = EnterpriseRegistry(_enterpriseRegistry);
    }

    // -----------------------------------------------------------------------
    // Admin Functions
    // -----------------------------------------------------------------------

    /// @notice Sets the Groth16 verifying key for the cross-reference circuit.
    /// @dev Only callable by admin. Must match the cross-reference circuit (3 public inputs).
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

    // -----------------------------------------------------------------------
    // Core Function
    // -----------------------------------------------------------------------

    /// @notice Verifies a cross-enterprise interaction proof on L1.
    /// @dev Enforces all TLA+ safety invariants atomically:
    ///
    ///   NoCrossRefSelfLoop: enterpriseA != enterpriseB
    ///   Consistency: both enterprise batch proofs must be verified on L1
    ///   Isolation: no enterprise state root is modified (only crossRefStatus changes)
    ///
    /// [Spec: VerifyCrossRef(src, dst, srcBatch, dstBatch)]
    ///   Guard: crossRefStatus[ref] \in {"none", "pending"}
    ///   Guard: batchStatus[src][srcBatch] = "verified"
    ///   Guard: batchStatus[dst][dstBatch] = "verified"
    ///   Effect: crossRefStatus' = "verified"
    ///   ISOLATION: UNCHANGED << currentRoot, batchStatus, batchNewRoot >>
    ///
    /// @param enterpriseA Address of the source enterprise.
    /// @param batchIdA Batch ID from the source enterprise.
    /// @param enterpriseB Address of the destination enterprise.
    /// @param batchIdB Batch ID from the destination enterprise.
    /// @param interactionCommitment Poseidon commitment binding both enterprises' records.
    /// @param a Groth16 proof point A.
    /// @param b Groth16 proof point B.
    /// @param c Groth16 proof point C.
    function verifyCrossReference(
        address enterpriseA,
        uint256 batchIdA,
        address enterpriseB,
        uint256 batchIdB,
        bytes32 interactionCommitment,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c
    ) external {
        // Phase 1: Validate preconditions and build public signals.
        // Separated into _validateAndBuildSignals to avoid stack-too-deep.
        (bytes32 refId, uint256[] memory publicSignals) = _validateAndBuildSignals(
            enterpriseA, batchIdA, enterpriseB, batchIdB, interactionCommitment
        );

        // Phase 2: Verify Groth16 proof
        bool valid = _verifyProof(a, b, c, publicSignals);
        if (!valid) revert InvalidCrossRefProof();

        // Phase 3: State update
        // [Spec: crossRefStatus' = "verified"]
        // [Spec: ISOLATION -- UNCHANGED << currentRoot, batchStatus, batchNewRoot >>]
        // Only crossReferenceStatus is modified. No enterprise state is touched.
        crossReferenceStatus[refId] = CrossRefState.Verified;
        totalCrossRefsVerified++;

        emit CrossReferenceVerified(
            refId,
            enterpriseA,
            enterpriseB,
            batchIdA,
            batchIdB,
            interactionCommitment,
            block.timestamp
        );
    }

    /// @dev Validates all preconditions for verifyCrossReference and constructs public signals.
    ///      Separated from the main function to avoid stack-too-deep.
    function _validateAndBuildSignals(
        address enterpriseA,
        uint256 batchIdA,
        address enterpriseB,
        uint256 batchIdB,
        bytes32 interactionCommitment
    ) internal view returns (bytes32 refId, uint256[] memory publicSignals) {
        // Verifying key must be configured
        if (!verifyingKeySet) revert VerifyingKeyNotSet();

        // [Spec: NoCrossRefSelfLoop -- src # dst]
        if (enterpriseA == enterpriseB) revert SelfReference();

        // Authorization: both enterprises must be registered and active
        if (!enterpriseRegistry.isAuthorized(enterpriseA)) {
            revert EnterpriseNotAuthorized(enterpriseA);
        }
        if (!enterpriseRegistry.isAuthorized(enterpriseB)) {
            revert EnterpriseNotAuthorized(enterpriseB);
        }

        // Compute refId for status tracking
        refId = keccak256(abi.encode(enterpriseA, enterpriseB, batchIdA, batchIdB));

        // Cannot re-verify or re-reject a terminal state
        CrossRefState currentState = crossReferenceStatus[refId];
        if (currentState == CrossRefState.Verified || currentState == CrossRefState.Rejected) {
            revert CrossRefAlreadyResolved(refId);
        }

        // [Spec: Consistency -- batchStatus[src][srcBatch] = "verified"]
        // StateCommitment stores batch roots: a non-zero root means verified.
        bytes32 rootA = stateCommitment.getBatchRoot(enterpriseA, batchIdA);
        if (rootA == bytes32(0)) {
            revert SourceBatchNotVerified(enterpriseA, batchIdA);
        }

        // [Spec: Consistency -- batchStatus[dst][dstBatch] = "verified"]
        bytes32 rootB = stateCommitment.getBatchRoot(enterpriseB, batchIdB);
        if (rootB == bytes32(0)) {
            revert DestBatchNotVerified(enterpriseB, batchIdB);
        }

        // Construct public signals for the cross-reference circuit
        // [Spec: Public inputs: stateRootA, stateRootB, interactionCommitment]
        publicSignals = new uint256[](3);
        publicSignals[0] = uint256(rootA);
        publicSignals[1] = uint256(rootB);
        publicSignals[2] = uint256(interactionCommitment);
    }

    // -----------------------------------------------------------------------
    // View Functions
    // -----------------------------------------------------------------------

    /// @notice Returns the status of a cross-reference.
    /// @param enterpriseA Source enterprise address.
    /// @param batchIdA Source batch ID.
    /// @param enterpriseB Destination enterprise address.
    /// @param batchIdB Destination batch ID.
    /// @return The cross-reference state.
    function getCrossRefStatus(
        address enterpriseA,
        uint256 batchIdA,
        address enterpriseB,
        uint256 batchIdB
    ) external view returns (CrossRefState) {
        bytes32 refId = keccak256(abi.encode(
            enterpriseA, enterpriseB, batchIdA, batchIdB
        ));
        return crossReferenceStatus[refId];
    }

    /// @notice Computes the refId for a cross-reference.
    /// @param enterpriseA Source enterprise address.
    /// @param batchIdA Source batch ID.
    /// @param enterpriseB Destination enterprise address.
    /// @param batchIdB Destination batch ID.
    /// @return The keccak256 hash used as refId.
    function computeRefId(
        address enterpriseA,
        uint256 batchIdA,
        address enterpriseB,
        uint256 batchIdB
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(
            enterpriseA, enterpriseB, batchIdA, batchIdB
        ));
    }

    // -----------------------------------------------------------------------
    // Internal: Groth16 Verification (Inline)
    // -----------------------------------------------------------------------

    /// @dev Verifies a Groth16 proof against the stored verifying key.
    ///      Inline implementation avoids cross-contract call overhead.
    ///      Uses EIP-196 (ecAdd, ecMul) and EIP-197 (ecPairing) precompiles.
    ///      Virtual to allow test harness override.
    function _verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] memory input
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

    /// @dev Negates a point on the BN254 curve.
    function _negate(
        uint256[2] calldata p
    ) internal pure returns (uint256[2] memory) {
        uint256 q = 21888242871839275222246405745257275088696311157297823662689037894645226208583;
        if (p[0] == 0 && p[1] == 0) return [uint256(0), uint256(0)];
        return [p[0], q - (p[1] % q)];
    }

    /// @dev Elliptic curve addition using precompile at address 0x06 (EIP-196).
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

    /// @dev Elliptic curve scalar multiplication using precompile at address 0x07 (EIP-196).
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

    /// @dev Pairing check using precompile at address 0x08 (EIP-197).
    function _ecPairing(
        uint256[2] memory a1, uint256[2][2] calldata b1,
        uint256[2] memory a2, uint256[2][2] memory b2,
        uint256[2] memory a3, uint256[2][2] memory b3,
        uint256[2] calldata a4, uint256[2][2] memory b4
    ) internal view returns (bool) {
        // EIP-197 precompile: G2 points passed directly from snarkjs format.
        // No coordinate swapping -- snarkjs exportSolidityCallData already provides correct order.
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
