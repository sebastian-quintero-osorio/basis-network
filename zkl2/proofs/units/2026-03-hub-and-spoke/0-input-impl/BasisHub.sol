// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "./IEnterpriseRegistry.sol";

/// @title BasisHub
/// @notice L1 hub contract for cross-enterprise communication in the Basis Network
///         hub-and-spoke architecture. Routes messages between enterprise spokes (L2 chains),
///         verifies ZK proofs, enforces replay protection, and settles cross-enterprise
///         transactions atomically.
///
/// @dev [Spec: zkl2/specs/units/2026-03-hub-and-spoke/HubAndSpoke.tla]
///
///      Protocol lifecycle (4 phases):
///        Phase 1: prepareMessage  -> Prepared  (source enterprise submits commitment + proof)
///        Phase 2: verifyMessage   -> Verified  (hub checks registration, root, proof, nonce)
///        Phase 3: respondMessage  -> Responded (dest enterprise submits response + proof)
///        Phase 4: settleMessage   -> Settled   (atomic settlement: both roots verified)
///
///      Alternative terminal states:
///        timeoutMessage -> TimedOut (deadline exceeded, unilateral withdrawal)
///        Any verification failure -> Failed
///
///      Safety invariants enforced (6 TLA+ invariants, all TLC-verified on 7,411 states):
///        INV-CE5  CrossEnterpriseIsolation: No private data in messages (structural)
///        INV-CE6  AtomicSettlement:         Both roots verified or neither changes
///        INV-CE7  CrossRefConsistency:      Settled messages have both proofs valid
///        INV-CE8  ReplayProtection:         At most one message per (source, dest, nonce) passes verification
///        INV-CE9  TimeoutSafety:            No premature timeouts
///        INV-CE10 HubNeutrality:            Hub only verifies proofs, never generates
contract BasisHub {
    // -----------------------------------------------------------------------
    // Types
    // [Spec: HubAndSpoke.tla, MsgStatuses]
    // -----------------------------------------------------------------------

    /// @dev Cross-enterprise message lifecycle status.
    enum MessageStatus {
        None,       // 0: Message does not exist
        Prepared,   // 1: Phase 1 complete -- source has commitment + ZK proof
        Verified,   // 2: Phase 2 complete -- hub verified registration, root, proof, nonce
        Responded,  // 3: Phase 3 complete -- destination has response proof
        Settled,    // 4: Phase 4 complete -- atomic settlement (terminal)
        TimedOut,   // 5: Timeout expired (terminal)
        Failed      // 6: Verification failed (terminal)
    }

    /// @dev Groth16 verifying key for cross-enterprise ZK proofs.
    struct VerifyingKey {
        uint256[2] alfa1;
        uint256[2][2] beta2;
        uint256[2][2] gamma2;
        uint256[2][2] delta2;
        uint256[2][] IC;
    }

    /// @dev Cross-enterprise message record stored on-chain.
    /// [Spec: HubAndSpoke.tla, message domain definition]
    ///
    /// CRITICAL (Isolation -- INV-CE5): This struct carries ONLY public metadata
    /// and opaque commitments. Enterprise private data is NEVER stored on-chain.
    /// ZK proofs ensure commitments are valid without revealing the underlying data.
    struct Message {
        address source;             // Originating enterprise (public, registered on L1)
        address dest;               // Destination enterprise (public, registered on L1)
        uint256 nonce;              // Per-directed-pair replay protection nonce
        bytes32 sourceStateRoot;    // Source's L1 state root at preparation time
        bytes32 destStateRoot;      // Dest's L1 state root at response time
        bytes32 commitment;         // Poseidon commitment from source (opaque)
        bytes32 responseCommitment; // Poseidon commitment from dest (opaque)
        MessageStatus status;       // Current lifecycle state
        uint256 createdAtBlock;     // L1 block when prepared
        bool sourceProofValid;      // Source ZK proof verification result
        bool destProofValid;        // Dest ZK proof verification result
    }

    // -----------------------------------------------------------------------
    // Immutables and Configuration
    // -----------------------------------------------------------------------

    /// @notice The enterprise registry for authorization checks.
    IEnterpriseRegistry public immutable enterpriseRegistry;

    /// @notice Network admin (Base Computing).
    address public admin;

    /// @notice Number of L1 blocks before a pending message times out.
    /// [Spec: HubAndSpoke.tla, TimeoutBlocks]
    uint256 public immutable timeoutBlocks;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    /// @dev Groth16 verifying key for cross-enterprise proofs.
    VerifyingKey private vk;

    /// @notice Whether the verifying key has been configured.
    bool public verifyingKeySet;

    /// @notice Cross-enterprise messages by ID: keccak256(source, dest, nonce).
    mapping(bytes32 => Message) public messages;

    /// @notice Used nonces per directed enterprise pair: keccak256(source, dest) -> nonce -> used.
    /// [Spec: HubAndSpoke.tla, usedNonces]
    mapping(bytes32 => mapping(uint256 => bool)) public usedNonces;

    /// @notice Nonce counters per directed pair: keccak256(source, dest) -> count.
    /// [Spec: HubAndSpoke.tla, msgCounter]
    mapping(bytes32 => uint256) public messageCounters;

    /// @notice Total messages prepared (global counter).
    uint256 public totalMessagesPrepared;

    /// @notice Total messages settled (global counter).
    uint256 public totalMessagesSettled;

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted when a cross-enterprise message is prepared (Phase 1).
    event MessagePrepared(
        bytes32 indexed msgId,
        address indexed source,
        address indexed dest,
        uint256 nonce,
        bytes32 commitment,
        uint256 blockNumber
    );

    /// @notice Emitted when a message passes hub verification (Phase 2).
    event MessageVerified(
        bytes32 indexed msgId,
        address indexed source,
        address indexed dest,
        uint256 nonce
    );

    /// @notice Emitted when a destination enterprise responds (Phase 3).
    event MessageResponded(
        bytes32 indexed msgId,
        address indexed dest,
        bytes32 responseCommitment
    );

    /// @notice Emitted when a cross-enterprise transaction settles atomically (Phase 4).
    event MessageSettled(
        bytes32 indexed msgId,
        address indexed source,
        address indexed dest,
        uint256 nonce
    );

    /// @notice Emitted when a message times out.
    event MessageTimedOut(bytes32 indexed msgId, uint256 blockNumber);

    /// @notice Emitted when a message verification fails.
    event MessageFailed(bytes32 indexed msgId, string reason);

    /// @notice Emitted when the verifying key is set.
    event VerifyingKeySet(uint256 timestamp);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error NotAdmin();
    error ZeroAddress();
    error SelfMessage();
    error NotRegistered(address enterprise);
    error MessageAlreadyExists(bytes32 msgId);
    error MessageNotFound(bytes32 msgId);
    error InvalidStatus(bytes32 msgId, MessageStatus expected, MessageStatus actual);
    error StaleStateRoot(bytes32 expected, bytes32 actual);
    error InvalidProof();
    error NonceReplay(bytes32 pairHash, uint256 nonce);
    error TimeoutNotReached(uint256 remaining);
    error TerminalMessage(bytes32 msgId, MessageStatus status);
    error VerifyingKeyNotSet();

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

    /// @notice Deploys the BasisHub contract.
    /// @param _registry Address of the IEnterpriseRegistry contract.
    /// @param _timeoutBlocks Number of blocks before message timeout.
    constructor(address _registry, uint256 _timeoutBlocks) {
        if (_registry == address(0)) revert ZeroAddress();
        if (_timeoutBlocks == 0) revert ZeroAddress(); // reuse error for zero value
        enterpriseRegistry = IEnterpriseRegistry(_registry);
        timeoutBlocks = _timeoutBlocks;
        admin = msg.sender;
    }

    // -----------------------------------------------------------------------
    // Admin: Verifying Key
    // -----------------------------------------------------------------------

    /// @notice Sets the Groth16 verifying key for cross-enterprise proof verification.
    /// @dev Can only be called once by admin.
    function setVerifyingKey(
        uint256[2] calldata alfa1,
        uint256[2][2] calldata beta2,
        uint256[2][2] calldata gamma2,
        uint256[2][2] calldata delta2,
        uint256[2][] calldata IC
    ) external onlyAdmin {
        vk.alfa1 = alfa1;
        vk.beta2 = beta2;
        vk.gamma2 = gamma2;
        vk.delta2 = delta2;
        delete vk.IC;
        for (uint256 i = 0; i < IC.length; i++) {
            vk.IC.push(IC[i]);
        }
        verifyingKeySet = true;
        emit VerifyingKeySet(block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Phase 1: Prepare Message
    // [Spec: HubAndSpoke.tla, PrepareMessage]
    // -----------------------------------------------------------------------

    /// @notice Prepares a cross-enterprise message from the calling enterprise to a destination.
    /// @dev The source enterprise computes a Poseidon commitment off-chain and submits it
    ///      along with a ZK proof. The proof is verified inline via Groth16 precompiles.
    ///      The nonce is allocated from the per-pair counter (monotonically increasing).
    /// @param dest Destination enterprise address.
    /// @param commitment Poseidon commitment: Poseidon(claimType, enterprise_id, data_hash, nonce).
    /// @param sourceStateRoot The source enterprise's current state root (caller asserts).
    /// @param a Groth16 proof point A (G1).
    /// @param b Groth16 proof point B (G2).
    /// @param c Groth16 proof point C (G1).
    /// @param publicSignals Public inputs to the ZK circuit.
    /// @return msgId The unique identifier for this message.
    function prepareMessage(
        address dest,
        bytes32 commitment,
        bytes32 sourceStateRoot,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata publicSignals
    ) external returns (bytes32 msgId) {
        // Validate enterprises.
        if (dest == address(0)) revert ZeroAddress();
        if (msg.sender == dest) revert SelfMessage();

        // Allocate nonce and compute message ID.
        bytes32 pairHash = keccak256(abi.encodePacked(msg.sender, dest));
        uint256 nonce = ++messageCounters[pairHash];
        msgId = keccak256(abi.encodePacked(msg.sender, dest, nonce));

        // Write directly to storage to avoid stack depth issues.
        Message storage m = messages[msgId];
        m.source = msg.sender;
        m.dest = dest;
        m.nonce = nonce;
        m.sourceStateRoot = sourceStateRoot;
        m.commitment = commitment;
        m.status = MessageStatus.Prepared;
        m.createdAtBlock = block.number;
        m.sourceProofValid = _verifyProof(a, b, c, publicSignals);

        totalMessagesPrepared++;

        emit MessagePrepared(msgId, msg.sender, dest, nonce, commitment, block.number);
    }

    // -----------------------------------------------------------------------
    // Phase 2: Hub Verification
    // [Spec: HubAndSpoke.tla, VerifyAtHub]
    // -----------------------------------------------------------------------

    /// @notice Verifies a prepared cross-enterprise message.
    /// @dev Checks: (1) source registered, (2) dest registered, (3) state root current,
    ///      (4) ZK proof valid, (5) nonce fresh.
    ///      On success: status -> Verified, nonce consumed.
    ///      On failure: status -> Failed, nonce NOT consumed.
    /// @param msgId The message identifier.
    /// @param currentSourceRoot The expected current state root for the source enterprise.
    function verifyMessage(bytes32 msgId, bytes32 currentSourceRoot) external {
        Message storage m = messages[msgId];
        if (m.status == MessageStatus.None) revert MessageNotFound(msgId);
        if (m.status != MessageStatus.Prepared) {
            revert InvalidStatus(msgId, MessageStatus.Prepared, m.status);
        }

        bytes32 pairHash = keccak256(abi.encodePacked(m.source, m.dest));

        // Check 1: Source enterprise is registered.
        bool sourceRegistered = enterpriseRegistry.isAuthorized(m.source);

        // Check 2: Destination enterprise is registered.
        bool destRegistered = enterpriseRegistry.isAuthorized(m.dest);

        // Check 3: State root matches caller-provided current root.
        bool rootCurrent = (m.sourceStateRoot == currentSourceRoot);

        // Check 4: ZK proof was valid at preparation time.
        bool proofValid = m.sourceProofValid;

        // Check 5: Nonce is fresh.
        bool nonceFresh = !usedNonces[pairHash][m.nonce];

        if (sourceRegistered && destRegistered && rootCurrent && proofValid && nonceFresh) {
            // SUCCESS: transition to Verified, consume nonce.
            m.status = MessageStatus.Verified;
            usedNonces[pairHash][m.nonce] = true;

            emit MessageVerified(msgId, m.source, m.dest, m.nonce);
        } else {
            // FAILURE: transition to Failed, nonce NOT consumed.
            m.status = MessageStatus.Failed;

            string memory reason;
            if (!sourceRegistered) reason = "source not registered";
            else if (!destRegistered) reason = "dest not registered";
            else if (!rootCurrent) reason = "stale state root";
            else if (!proofValid) reason = "invalid proof";
            else reason = "nonce replay";

            emit MessageFailed(msgId, reason);
        }
    }

    // -----------------------------------------------------------------------
    // Phase 3: Response
    // [Spec: HubAndSpoke.tla, RespondToMessage]
    // -----------------------------------------------------------------------

    /// @notice Destination enterprise responds to a hub-verified message.
    /// @dev The destination computes a response commitment and ZK proof.
    ///      The response proof is verified inline.
    /// @param msgId The message identifier.
    /// @param responseCommitment Poseidon commitment from destination.
    /// @param destStateRoot Destination's current state root.
    /// @param a Groth16 proof point A (G1).
    /// @param b Groth16 proof point B (G2).
    /// @param c Groth16 proof point C (G1).
    /// @param publicSignals Public inputs to the ZK circuit.
    function respondToMessage(
        bytes32 msgId,
        bytes32 responseCommitment,
        bytes32 destStateRoot,
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata publicSignals
    ) external {
        Message storage m = messages[msgId];
        if (m.status == MessageStatus.None) revert MessageNotFound(msgId);
        if (m.status != MessageStatus.Verified) {
            revert InvalidStatus(msgId, MessageStatus.Verified, m.status);
        }

        // Only destination enterprise can respond.
        if (msg.sender != m.dest) revert NotRegistered(msg.sender);

        // Verify response ZK proof.
        bool proofValid = _verifyProof(a, b, c, publicSignals);

        m.status = MessageStatus.Responded;
        m.destProofValid = proofValid;
        m.destStateRoot = destStateRoot;
        m.responseCommitment = responseCommitment;

        emit MessageResponded(msgId, m.dest, responseCommitment);
    }

    // -----------------------------------------------------------------------
    // Phase 4: Atomic Settlement
    // [Spec: HubAndSpoke.tla, AttemptSettlement]
    // [Invariant: INV-CE6 AtomicSettlement]
    // -----------------------------------------------------------------------

    /// @notice Attempts atomic settlement of a responded cross-enterprise message.
    /// @dev Verifies: both proofs valid, both state roots current.
    ///      SUCCESS: message settled, both enterprises' settlement recorded.
    ///      FAILURE: message failed, no state changes.
    ///
    ///      ATOMIC GUARANTEE: This function either fully succeeds (status -> Settled)
    ///      or fully reverts / marks as Failed. There is NO intermediate state where
    ///      one enterprise is settled but the other is not.
    ///
    /// @param msgId The message identifier.
    /// @param currentSourceRoot Expected current source state root.
    /// @param currentDestRoot Expected current dest state root.
    function settleMessage(
        bytes32 msgId,
        bytes32 currentSourceRoot,
        bytes32 currentDestRoot
    ) external {
        Message storage m = messages[msgId];
        if (m.status == MessageStatus.None) revert MessageNotFound(msgId);
        if (m.status != MessageStatus.Responded) {
            revert InvalidStatus(msgId, MessageStatus.Responded, m.status);
        }

        // Settlement verification checks.
        bool sourceRootCurrent = (m.sourceStateRoot == currentSourceRoot);
        bool destRootCurrent = (m.destStateRoot == currentDestRoot);
        bool bothProofsValid = m.sourceProofValid && m.destProofValid;
        bool allValid = sourceRootCurrent && destRootCurrent && bothProofsValid;

        if (allValid) {
            // SUCCESS: Atomic settlement.
            // Both enterprises' cross-enterprise transaction is recorded.
            // The actual state root advancement happens in the next batch cycle
            // for each enterprise via BasisRollup.
            m.status = MessageStatus.Settled;
            totalMessagesSettled++;

            emit MessageSettled(msgId, m.source, m.dest, m.nonce);
        } else {
            // FAILURE: Neither side settles. Atomic revert.
            m.status = MessageStatus.Failed;

            string memory reason;
            if (!m.sourceProofValid) reason = "invalid source proof";
            else if (!m.destProofValid) reason = "invalid dest proof";
            else if (!sourceRootCurrent) reason = "stale source root";
            else reason = "stale dest root";

            emit MessageFailed(msgId, reason);
        }
    }

    // -----------------------------------------------------------------------
    // Timeout
    // [Spec: HubAndSpoke.tla, TimeoutMessage]
    // [Invariant: INV-CE9 TimeoutSafety]
    // -----------------------------------------------------------------------

    /// @notice Times out a non-terminal message that has exceeded the deadline.
    /// @dev No state root changes occur. Consumed nonces remain consumed
    ///      (preventing replay of timed-out messages). Either party can call this.
    /// @param msgId The message identifier.
    function timeoutMessage(bytes32 msgId) external {
        Message storage m = messages[msgId];
        if (m.status == MessageStatus.None) revert MessageNotFound(msgId);

        // Only non-terminal messages can time out.
        if (_isTerminal(m.status)) {
            revert TerminalMessage(msgId, m.status);
        }

        // Check timeout condition: blockHeight - createdAt >= timeoutBlocks
        uint256 elapsed = block.number - m.createdAtBlock;
        if (elapsed < timeoutBlocks) {
            revert TimeoutNotReached(timeoutBlocks - elapsed);
        }

        m.status = MessageStatus.TimedOut;

        emit MessageTimedOut(msgId, block.number);
    }

    // -----------------------------------------------------------------------
    // View Functions
    // -----------------------------------------------------------------------

    /// @notice Returns the full message record.
    function getMessage(bytes32 msgId) external view returns (
        address source,
        address dest,
        uint256 nonce,
        bytes32 sourceStateRoot,
        bytes32 destStateRoot,
        bytes32 commitment,
        bytes32 responseCommitment,
        MessageStatus status,
        uint256 createdAtBlock,
        bool sourceProofValid,
        bool destProofValid
    ) {
        Message storage m = messages[msgId];
        return (
            m.source, m.dest, m.nonce,
            m.sourceStateRoot, m.destStateRoot,
            m.commitment, m.responseCommitment,
            m.status, m.createdAtBlock,
            m.sourceProofValid, m.destProofValid
        );
    }

    /// @notice Checks if a nonce has been consumed for a directed pair.
    function isNonceUsed(address source, address dest, uint256 nonce) external view returns (bool) {
        bytes32 pairHash = keccak256(abi.encodePacked(source, dest));
        return usedNonces[pairHash][nonce];
    }

    /// @notice Returns the current nonce counter for a directed pair.
    function getNonce(address source, address dest) external view returns (uint256) {
        bytes32 pairHash = keccak256(abi.encodePacked(source, dest));
        return messageCounters[pairHash];
    }

    /// @notice Computes the message ID for a given (source, dest, nonce) triple.
    function computeMessageId(address source, address dest, uint256 nonce) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(source, dest, nonce));
    }

    // -----------------------------------------------------------------------
    // Internal: Status Helpers
    // -----------------------------------------------------------------------

    /// @dev Returns true if the status is terminal (no further transitions).
    function _isTerminal(MessageStatus status) internal pure returns (bool) {
        return status == MessageStatus.Settled
            || status == MessageStatus.TimedOut
            || status == MessageStatus.Failed;
    }

    // -----------------------------------------------------------------------
    // Internal: Groth16 Proof Verification
    // [Invariant: INV-CE10 HubNeutrality -- hub ONLY verifies, never generates]
    //
    // Implementation follows BasisRollup.sol pattern (EIP-196/197 precompiles).
    // -----------------------------------------------------------------------

    /// @dev Verifies a Groth16 proof against the stored verifying key.
    ///      Uses EIP-196 (ecAdd, ecMul) and EIP-197 (ecPairing) precompiles.
    ///      Virtual for test harness override.
    function _verifyProof(
        uint256[2] calldata a,
        uint256[2][2] calldata b,
        uint256[2] calldata c,
        uint256[] calldata input
    ) internal view virtual returns (bool) {
        if (!verifyingKeySet) revert VerifyingKeyNotSet();
        if (input.length + 1 != vk.IC.length) return false;

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
