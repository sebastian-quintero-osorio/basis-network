// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.24;

/// @title BasisDAC -- Data Availability Committee for Basis Network zkEVM L2
/// @author Base Computing S.A.S.
/// @notice Manages enterprise DAC committee membership, attestation verification,
///         certificate storage, and AnyTrust fallback for data availability.
/// @dev [Spec: zkl2/specs/units/2026-03-production-dac/ProductionDAC.tla]
///      Implements on-chain verification of the DAC protocol invariants:
///      - CertificateSoundness: valid cert requires >= threshold attestations
///      - AttestationIntegrity: only registered committee members can attest
///      - No duplicate signers in a certificate
contract BasisDAC {

    // =========================================================================
    // ERRORS
    // =========================================================================

    error NotAdmin();
    error MemberAlreadyRegistered(address member);
    error MemberNotRegistered(address member);
    error CommitteeFull();
    error CommitteeEmpty();
    error InvalidThreshold(uint8 threshold, uint8 committeeSize);
    error CertificateAlreadySubmitted(uint64 batchId);
    error InsufficientAttestations(uint256 count, uint8 required);
    error DuplicateSigner(address signer);
    error SignerNotMember(address signer);
    error InvalidSignatureLength();
    error InvalidSignature();
    error FallbackAlreadyActive(uint64 batchId);
    error FallbackNotActive(uint64 batchId);
    error BatchNotCertified(uint64 batchId);

    // =========================================================================
    // EVENTS
    // =========================================================================

    /// @notice Emitted when a new committee member is registered.
    event MemberAdded(address indexed member, uint8 index);

    /// @notice Emitted when a committee member is removed.
    event MemberRemoved(address indexed member, uint8 index);

    /// @notice Emitted when a valid DACCertificate is submitted on-chain.
    event CertificateSubmitted(
        uint64 indexed batchId,
        bytes32 dataHash,
        uint8 signerBitmap,
        uint8 signerCount
    );

    /// @notice Emitted when AnyTrust fallback is activated for a batch.
    event FallbackActivated(uint64 indexed batchId, bytes32 dataHash);

    /// @notice Emitted when the attestation threshold is updated.
    event ThresholdUpdated(uint8 oldThreshold, uint8 newThreshold);

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    /// @notice Maximum committee size (7 for enterprise DAC).
    uint8 public constant MAX_COMMITTEE_SIZE = 7;

    // =========================================================================
    // STATE
    // =========================================================================

    /// @notice Admin address (deployer, can manage committee).
    address public admin;

    /// @notice Minimum number of attestations for a valid certificate.
    /// @dev [Spec: Threshold constant in ProductionDAC.tla]
    uint8 public threshold;

    /// @notice Ordered list of committee member addresses.
    address[] public committeeMembers;

    /// @notice Mapping from address to committee membership status.
    mapping(address => bool) public isMember;

    /// @notice Mapping from address to committee index.
    mapping(address => uint8) public memberIndex;

    /// @notice Certificate state per batch.
    /// @dev 0 = none, 1 = valid, 2 = fallback
    /// @dev [Spec: certState variable in ProductionDAC.tla]
    mapping(uint64 => uint8) public certState;

    /// @notice Stored certificate data hash per batch.
    mapping(uint64 => bytes32) public certDataHash;

    /// @notice Signer bitmap per batch.
    mapping(uint64 => uint8) public certSignerBitmap;

    /// @notice Signer count per batch.
    mapping(uint64 => uint8) public certSignerCount;

    /// @notice Fallback data hash per batch (when raw data posted as calldata).
    mapping(uint64 => bytes32) public fallbackDataHash;

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /// @notice Initializes the DAC contract with admin and threshold.
    /// @param _threshold Minimum attestations for a valid certificate.
    /// @param _members Initial committee members (up to MAX_COMMITTEE_SIZE).
    constructor(uint8 _threshold, address[] memory _members) {
        if (_members.length > MAX_COMMITTEE_SIZE) revert CommitteeFull();
        if (_threshold == 0 || _threshold > uint8(_members.length)) {
            revert InvalidThreshold(_threshold, uint8(_members.length));
        }

        admin = msg.sender;
        threshold = _threshold;

        for (uint8 i = 0; i < _members.length; i++) {
            address member = _members[i];
            if (isMember[member]) revert MemberAlreadyRegistered(member);
            committeeMembers.push(member);
            isMember[member] = true;
            memberIndex[member] = i;
            emit MemberAdded(member, i);
        }
    }

    // =========================================================================
    // COMMITTEE MANAGEMENT
    // =========================================================================

    /// @notice Adds a new member to the committee.
    /// @param member Address of the new committee member.
    function addMember(address member) external onlyAdmin {
        if (committeeMembers.length >= MAX_COMMITTEE_SIZE) revert CommitteeFull();
        if (isMember[member]) revert MemberAlreadyRegistered(member);

        uint8 index = uint8(committeeMembers.length);
        committeeMembers.push(member);
        isMember[member] = true;
        memberIndex[member] = index;

        emit MemberAdded(member, index);
    }

    /// @notice Removes a member from the committee. Replaces with last member.
    /// @param member Address of the member to remove.
    function removeMember(address member) external onlyAdmin {
        if (!isMember[member]) revert MemberNotRegistered(member);
        if (committeeMembers.length <= threshold) {
            revert InvalidThreshold(threshold, uint8(committeeMembers.length - 1));
        }

        uint8 idx = memberIndex[member];
        uint8 lastIdx = uint8(committeeMembers.length - 1);
        address lastMember = committeeMembers[lastIdx];

        // Swap with last and pop.
        committeeMembers[idx] = lastMember;
        memberIndex[lastMember] = idx;

        committeeMembers.pop();
        delete isMember[member];
        delete memberIndex[member];

        emit MemberRemoved(member, idx);
    }

    /// @notice Updates the attestation threshold.
    /// @param _threshold New threshold value.
    function setThreshold(uint8 _threshold) external onlyAdmin {
        if (_threshold == 0 || _threshold > uint8(committeeMembers.length)) {
            revert InvalidThreshold(_threshold, uint8(committeeMembers.length));
        }
        uint8 old = threshold;
        threshold = _threshold;
        emit ThresholdUpdated(old, _threshold);
    }

    /// @notice Transfers admin role to a new address.
    /// @param newAdmin Address of the new admin.
    function transferAdmin(address newAdmin) external onlyAdmin {
        admin = newAdmin;
    }

    // =========================================================================
    // CERTIFICATE SUBMISSION
    // =========================================================================

    /// @notice Submits a DACCertificate for on-chain verification and storage.
    /// @dev Verifies that:
    ///      1. No certificate exists for this batch
    ///      2. All signers are committee members
    ///      3. No duplicate signers
    ///      4. Signatures are valid (ecrecover)
    ///      5. Signer count >= threshold
    ///      [Spec: ProduceCertificate action + CertificateSoundness invariant]
    /// @param batchId The batch identifier.
    /// @param dataHash SHA-256 hash of the original batch data.
    /// @param signatures Packed signatures (65 bytes each: r || s || v).
    /// @param signers Addresses of the signers (same order as signatures).
    function submitCertificate(
        uint64 batchId,
        bytes32 dataHash,
        bytes[] calldata signatures,
        address[] calldata signers
    ) external {
        if (certState[batchId] != 0) revert CertificateAlreadySubmitted(batchId);
        if (signatures.length != signers.length) revert InsufficientAttestations(0, threshold);
        if (signatures.length < threshold) {
            revert InsufficientAttestations(signatures.length, threshold);
        }

        uint8 bitmap = 0;
        uint8 count = 0;

        // Compute the attestation digest: keccak256(abi.encodePacked(batchId, dataHash))
        bytes32 digest = keccak256(abi.encodePacked(batchId, dataHash));

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = signers[i];

            // Verify signer is a committee member.
            if (!isMember[signer]) revert SignerNotMember(signer);

            // Check for duplicate signers via bitmap.
            uint8 idx = memberIndex[signer];
            uint8 mask = uint8(1 << idx);
            if (bitmap & mask != 0) revert DuplicateSigner(signer);

            // Verify ECDSA signature.
            if (signatures[i].length != 65) revert InvalidSignatureLength();
            address recovered = _recoverSigner(digest, signatures[i]);
            if (recovered != signer) revert InvalidSignature();

            bitmap |= mask;
            count++;
        }

        // CertificateSoundness: count >= threshold.
        if (count < threshold) {
            revert InsufficientAttestations(count, threshold);
        }

        // Store certificate.
        certState[batchId] = 1; // valid
        certDataHash[batchId] = dataHash;
        certSignerBitmap[batchId] = bitmap;
        certSignerCount[batchId] = count;

        emit CertificateSubmitted(batchId, dataHash, bitmap, count);
    }

    // =========================================================================
    // ANYTRUST FALLBACK
    // =========================================================================

    /// @notice Activates AnyTrust fallback mode for a batch.
    /// @dev When fewer than threshold nodes are available, the sequencer posts
    ///      raw batch data as L1 calldata (validium -> rollup mode).
    ///      [Spec: TriggerFallback action -- certState[b] <- "fallback"]
    /// @param batchId The batch identifier.
    /// @param dataHash Hash of the raw data posted as calldata.
    function activateFallback(uint64 batchId, bytes32 dataHash) external onlyAdmin {
        if (certState[batchId] != 0) revert CertificateAlreadySubmitted(batchId);

        certState[batchId] = 2; // fallback
        fallbackDataHash[batchId] = dataHash;

        emit FallbackActivated(batchId, dataHash);
    }

    // =========================================================================
    // QUERIES
    // =========================================================================

    /// @notice Returns whether a batch has a valid certificate or fallback.
    /// @param batchId The batch identifier.
    /// @return True if data availability is confirmed for this batch.
    function isDataAvailable(uint64 batchId) external view returns (bool) {
        return certState[batchId] == 1 || certState[batchId] == 2;
    }

    /// @notice Returns whether a batch has a valid DAC certificate (not fallback).
    /// @param batchId The batch identifier.
    /// @return True if a valid certificate exists.
    function hasCertificate(uint64 batchId) external view returns (bool) {
        return certState[batchId] == 1;
    }

    /// @notice Returns whether a batch is in AnyTrust fallback mode.
    /// @param batchId The batch identifier.
    /// @return True if fallback is active.
    function isFallback(uint64 batchId) external view returns (bool) {
        return certState[batchId] == 2;
    }

    /// @notice Returns the current committee size.
    /// @return Number of registered committee members.
    function committeeSize() external view returns (uint8) {
        return uint8(committeeMembers.length);
    }

    /// @notice Returns the full list of committee member addresses.
    /// @return Array of committee member addresses.
    function getCommittee() external view returns (address[] memory) {
        return committeeMembers;
    }

    // =========================================================================
    // INTERNAL
    // =========================================================================

    /// @notice Recovers the signer address from a message digest and signature.
    /// @param digest The message digest (32 bytes).
    /// @param sig The signature (65 bytes: r || s || v).
    /// @return The recovered signer address.
    function _recoverSigner(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }

        return ecrecover(digest, v, r, s);
    }
}
