// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "../core/EnterpriseRegistry.sol";

/// @title DACAttestation
/// @notice On-chain registry and verification of Data Availability Committee attestations.
/// @dev Implements the on-chain verification logic for the DAC protocol:
///      - Committee member registration (admin-managed)
///      - Batch attestation submission with ECDSA signatures
///      - Threshold enforcement (k-of-n)
///      - Certificate state tracking (none -> valid | fallback)
///
/// [Spec: validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/specs/DataAvailability/DataAvailability.tla]
///
/// Security model:
///   CertificateSoundness: certState[b] = "valid" => signatureCount >= threshold
///   AttestationIntegrity: only registered committee members can attest
///   No duplicate signers per batch
contract DACAttestation {
    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------

    /// @dev Certificate state as per TLA+ specification.
    /// [Spec: certState \in [Batches -> {"none", "valid", "fallback"}]]
    enum CertState {
        None,
        Valid,
        Fallback
    }

    /// @dev On-chain attestation record for a batch.
    struct BatchAttestation {
        bytes32 commitment;
        address submitter;
        uint256 signatureCount;
        CertState state;
        uint256 timestamp;
    }

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    EnterpriseRegistry public immutable enterpriseRegistry;
    address public admin;

    /// @dev Registered committee member addresses.
    mapping(address => bool) public isCommitteeMember;
    address[] private committeeMembers;

    /// @dev Attestation threshold k.
    uint256 public threshold;

    /// @dev Committee size n.
    uint256 public committeeSize;

    /// @dev Batch ID -> attestation record.
    mapping(bytes32 => BatchAttestation) private attestations;

    /// @dev Batch ID -> signer address -> has signed.
    mapping(bytes32 => mapping(address => bool)) private hasSigned;

    /// @dev All submitted batch IDs.
    bytes32[] private batchIds;

    /// @dev Counters for observability.
    uint256 public totalBatches;
    uint256 public totalCertified;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @dev Emitted when a new batch attestation is submitted.
    event AttestationSubmitted(
        bytes32 indexed batchId,
        bytes32 commitment,
        uint256 signatureCount,
        CertState state,
        uint256 timestamp
    );

    /// @dev Emitted when a committee member is added.
    event CommitteeMemberAdded(address indexed member, uint256 timestamp);

    /// @dev Emitted when a committee member is removed.
    event CommitteeMemberRemoved(address indexed member, uint256 timestamp);

    /// @dev Emitted when threshold is updated.
    event ThresholdUpdated(uint256 newThreshold, uint256 timestamp);

    /// @dev Emitted when a batch falls back to on-chain DA.
    event FallbackTriggered(bytes32 indexed batchId, uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error OnlyAdmin();
    error NotAuthorized();
    error InvalidThreshold();
    error NotCommitteeMember();
    error BatchAlreadyExists();
    error BatchNotFound();
    error DuplicateSigner();
    error InsufficientSignatures();
    error InvalidSignature();
    error ZeroAddress();
    error MemberAlreadyRegistered();

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyAuthorizedEnterprise() {
        if (!enterpriseRegistry.isAuthorized(msg.sender)) revert NotAuthorized();
        _;
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @notice Deploys the DACAttestation contract.
    /// @param _enterpriseRegistry Address of the EnterpriseRegistry contract.
    /// @param _threshold Initial attestation threshold k (must be >= 1).
    constructor(address _enterpriseRegistry, uint256 _threshold) {
        if (_threshold < 1) revert InvalidThreshold();
        enterpriseRegistry = EnterpriseRegistry(_enterpriseRegistry);
        admin = msg.sender;
        threshold = _threshold;
    }

    // -----------------------------------------------------------------------
    // Committee Management (Admin)
    // -----------------------------------------------------------------------

    /// @notice Register a new committee member.
    /// @param member The address of the DAC node operator.
    function addCommitteeMember(address member) external onlyAdmin {
        if (member == address(0)) revert ZeroAddress();
        if (isCommitteeMember[member]) revert MemberAlreadyRegistered();

        isCommitteeMember[member] = true;
        committeeMembers.push(member);
        committeeSize++;

        emit CommitteeMemberAdded(member, block.timestamp);
    }

    /// @notice Remove a committee member.
    /// @param member The address to remove.
    function removeCommitteeMember(address member) external onlyAdmin {
        if (!isCommitteeMember[member]) revert NotCommitteeMember();

        isCommitteeMember[member] = false;
        committeeSize--;

        // Remove from array (swap and pop)
        for (uint256 i = 0; i < committeeMembers.length; i++) {
            if (committeeMembers[i] == member) {
                committeeMembers[i] = committeeMembers[committeeMembers.length - 1];
                committeeMembers.pop();
                break;
            }
        }

        emit CommitteeMemberRemoved(member, block.timestamp);
    }

    /// @notice Update the attestation threshold.
    /// @param _threshold New threshold value (must be >= 1 and <= committeeSize).
    function setThreshold(uint256 _threshold) external onlyAdmin {
        if (_threshold < 1 || _threshold > committeeSize) revert InvalidThreshold();
        threshold = _threshold;
        emit ThresholdUpdated(_threshold, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Attestation Submission
    // -----------------------------------------------------------------------

    /// @notice Submit a batch attestation with committee member signatures.
    /// @dev Verifies each signature via ecrecover, enforces:
    ///      1. All signers are registered committee members
    ///      2. No duplicate signers
    ///      3. Signature count >= threshold for valid certificate
    ///
    /// [Spec: ProduceCertificate(b) -- certState'[b] = "valid" when threshold met]
    /// [Spec: CertificateSoundness -- valid => signatureCount >= Threshold]
    ///
    /// @param batchId Unique batch identifier.
    /// @param commitment SHA-256 data commitment (as bytes32).
    /// @param signers Array of signer addresses (committee members).
    /// @param signatures Array of ECDSA signatures over keccak256(batchId, commitment).
    function submitAttestation(
        bytes32 batchId,
        bytes32 commitment,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external onlyAuthorizedEnterprise {
        if (attestations[batchId].timestamp != 0) revert BatchAlreadyExists();
        if (signers.length != signatures.length) revert InsufficientSignatures();

        // EIP-191 signed message: prefix + keccak256(batchId, commitment)
        // The digest is 32 bytes, so the EIP-191 length field is "32".
        bytes32 digest = keccak256(abi.encodePacked(batchId, commitment));
        bytes32 messageHash = keccak256(
            abi.encodePacked("\x19Ethereum Signed Message:\n32", digest)
        );

        uint256 validCount = 0;

        for (uint256 i = 0; i < signers.length; i++) {
            // Verify committee membership
            if (!isCommitteeMember[signers[i]]) revert NotCommitteeMember();

            // Verify no duplicate signer
            if (hasSigned[batchId][signers[i]]) revert DuplicateSigner();

            // Verify signature
            address recovered = _recoverSigner(messageHash, signatures[i]);
            if (recovered != signers[i]) revert InvalidSignature();

            hasSigned[batchId][signers[i]] = true;
            validCount++;
        }

        CertState state;
        if (validCount >= threshold) {
            state = CertState.Valid;
            totalCertified++;
        } else {
            state = CertState.None;
        }

        attestations[batchId] = BatchAttestation({
            commitment: commitment,
            submitter: msg.sender,
            signatureCount: validCount,
            state: state,
            timestamp: block.timestamp
        });

        batchIds.push(batchId);
        totalBatches++;

        emit AttestationSubmitted(batchId, commitment, validCount, state, block.timestamp);
    }

    /// @notice Trigger fallback for a batch (post data on-chain).
    /// @dev Called when threshold is structurally unreachable.
    ///
    /// [Spec: TriggerFallback(b) -- certState[b] = "none" /\ |shareHolders[b]| < Threshold]
    ///
    /// @param batchId The batch to trigger fallback for.
    function triggerFallback(bytes32 batchId) external onlyAuthorizedEnterprise {
        BatchAttestation storage att = attestations[batchId];

        // Can only trigger fallback on existing batches that are not yet certified
        if (att.timestamp == 0) revert BatchNotFound();
        if (att.state != CertState.None) revert BatchAlreadyExists();

        att.state = CertState.Fallback;

        emit FallbackTriggered(batchId, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Query Functions
    // -----------------------------------------------------------------------

    /// @notice Check if a batch has a valid attestation certificate.
    /// @param batchId The batch to check.
    /// @return True if the batch has been certified (signatureCount >= threshold).
    function verifyAttestation(bytes32 batchId) external view returns (bool) {
        return attestations[batchId].state == CertState.Valid;
    }

    /// @notice Get full attestation details for a batch.
    /// @param batchId The batch to query.
    /// @return commitment The data commitment.
    /// @return submitter The address that submitted the attestation.
    /// @return signatureCount Number of valid signatures.
    /// @return state Certificate state.
    /// @return timestamp Submission timestamp.
    function getAttestation(bytes32 batchId)
        external
        view
        returns (
            bytes32 commitment,
            address submitter,
            uint256 signatureCount,
            CertState state,
            uint256 timestamp
        )
    {
        BatchAttestation storage att = attestations[batchId];
        if (att.timestamp == 0) revert BatchNotFound();
        return (att.commitment, att.submitter, att.signatureCount, att.state, att.timestamp);
    }

    /// @notice Returns all batch IDs.
    function getAllBatches() external view returns (bytes32[] memory) {
        return batchIds;
    }

    /// @notice Returns all registered committee member addresses.
    function getCommitteeMembers() external view returns (address[] memory) {
        return committeeMembers;
    }

    /// @notice Transfer admin rights.
    /// @param newAdmin The new admin address.
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    /// @dev Recover signer address from an ECDSA signature.
    function _recoverSigner(bytes32 messageHash, bytes memory signature)
        internal
        pure
        returns (address)
    {
        if (signature.length != 65) return address(0);

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        if (v < 27) {
            v += 27;
        }

        if (v != 27 && v != 28) return address(0);

        return ecrecover(messageHash, v, r, s);
    }
}
