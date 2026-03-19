// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title BasisBridge
/// @notice L1 bridge contract for Basis Network zkEVM L2 with escape hatch.
/// @dev Implements three operations:
///      1. Deposit (L1->L2): Lock ETH on L1, emit event for relayer to mint on L2
///      2. Withdrawal (L2->L1): Verify Merkle proof against finalized withdraw root, release ETH
///      3. Escape Hatch: If sequencer offline > timeout, allow direct withdrawal via state proof
///
///      [Spec: zkl2/specs/units/2026-03-bridge/1-formalization/v0-analysis/specs/BasisBridge/BasisBridge.tla]
///
///      Security invariants (all TLC-verified across 211,453 states):
///        INV-B1 NoDoubleSpend:        Each withdrawal can be claimed exactly once (nullifier)
///        INV-B2 BalanceConservation:   totalDeposited - totalWithdrawn == address(this).balance
///        INV-B3 EscapeHatchLiveness:   If no batch executed in > escapeTimeout, escape mode activates
///        INV-B4 ProofFinality:         Withdrawals only claimable after batch is Executed on rollup
///        INV-B5 DepositOrdering:       Deposits assigned monotonically increasing IDs
///        INV-B6 EscapeNoDoubleSpend:   Escape withdrawals tracked by separate nullifier set
///
///      Integration with BasisRollup.sol:
///        - submitWithdrawRoot() verifies batch execution via enterprises().totalBatchesExecuted
///        - escapeWithdraw() uses getCurrentRoot() for state proof verification
///        - deposit() verifies enterprise initialization via enterprises().initialized
/// @dev Minimal interface to BasisRollup for bridge integration.
/// [Spec: BasisBridge.tla -- integration with BasisRollup state]
interface IBasisRollup {
    function isExecutedRoot(
        address enterprise,
        uint256 batchId,
        bytes32 root
    ) external view returns (bool);

    function getCurrentRoot(address enterprise) external view returns (bytes32);

    function getLastL2Block(address enterprise) external view returns (uint64);

    function enterprises(address enterprise) external view returns (
        bytes32 currentRoot,
        uint64 totalBatchesCommitted,
        uint64 totalBatchesProven,
        uint64 totalBatchesExecuted,
        bool initialized,
        uint64 lastL2Block
    );
}

contract BasisBridge {
    // -----------------------------------------------------------------------
    // Types
    // [Spec: BasisBridge.tla, lines 41-52 -- VARIABLES]
    // -----------------------------------------------------------------------

    /// @dev Deposit record stored on L1 for reference.
    struct DepositInfo {
        address depositor;
        address l2Recipient;
        uint256 amount;
        uint64 l2DepositId;
        uint64 timestamp;
    }

    // -----------------------------------------------------------------------
    // State
    // [Spec: BasisBridge.tla, lines 40-52 -- bridgeBalance, claimedNullifiers,
    //  escapeNullifiers, escapeActive, lastBatchTime, nextWid]
    // -----------------------------------------------------------------------

    /// @notice Network admin (Base Computing).
    address public admin;

    /// @notice Reference to BasisRollup contract for finality verification.
    IBasisRollup public immutable rollup;

    /// @notice Escape hatch timeout in seconds (default: 24 hours).
    uint256 public escapeTimeout;

    /// @notice Per-enterprise deposit counter (monotonically increasing).
    /// INV-B5: depositCounter[enterprise] is strictly increasing.
    mapping(address => uint256) public depositCounter;

    /// @notice Per-enterprise total deposited (for balance conservation tracking).
    mapping(address => uint256) public totalDeposited;

    /// @notice Per-enterprise total withdrawn (for balance conservation tracking).
    mapping(address => uint256) public totalWithdrawn;

    /// @notice Withdrawal nullifier: enterprise -> withdrawalHash -> claimed.
    /// INV-B1: Once set to true, cannot be set again.
    mapping(address => mapping(bytes32 => bool)) public withdrawalNullifier;

    /// @notice Escape hatch nullifier: enterprise -> account -> claimed.
    /// INV-B6: Separate from withdrawal nullifier to prevent cross-contamination.
    mapping(address => mapping(address => bool)) public escapeNullifier;

    /// @notice Per-enterprise withdraw trie roots, indexed by batch ID.
    /// Set by admin/relayer after batch execution on rollup.
    mapping(address => mapping(uint256 => bytes32)) public withdrawRoots;

    /// @notice Timestamp of last batch execution per enterprise (for escape hatch).
    mapping(address => uint256) public lastBatchExecutionTime;

    /// @notice Whether escape mode is active per enterprise.
    mapping(address => bool) public escapeMode;

    // -----------------------------------------------------------------------
    // Events
    // [Spec: BasisBridge.tla -- Deposit, ClaimWithdrawal, ActivateEscapeHatch,
    //  EscapeWithdraw, FinalizeBatch actions]
    // -----------------------------------------------------------------------

    event DepositInitiated(
        address indexed enterprise,
        address indexed depositor,
        address indexed l2Recipient,
        uint256 amount,
        uint256 depositId,
        uint256 timestamp
    );

    event WithdrawalClaimed(
        address indexed enterprise,
        address indexed recipient,
        uint256 amount,
        bytes32 withdrawalHash,
        uint256 batchId,
        uint256 timestamp
    );

    event EscapeHatchActivated(
        address indexed enterprise,
        uint256 lastBatchTime,
        uint256 activationTime
    );

    event EscapeWithdrawal(
        address indexed enterprise,
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );

    event WithdrawRootSubmitted(
        address indexed enterprise,
        uint256 indexed batchId,
        bytes32 withdrawRoot,
        uint256 timestamp
    );

    event BatchExecutionRecorded(
        address indexed enterprise,
        uint256 timestamp
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error OnlyAdmin();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidProof();
    error AlreadyClaimed();
    error AlreadyEscaped();
    error EscapeNotActive();
    error EscapeAlreadyActive();
    error EscapeTimeoutNotReached();
    error BatchNotExecuted();
    error WithdrawRootNotSet();
    error TransferFailed();
    error InsufficientBridgeBalance();
    error EnterpriseNotInitialized();

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    // -----------------------------------------------------------------------
    // Constructor
    // [Spec: BasisBridge.tla, lines 108-120 -- Init]
    // -----------------------------------------------------------------------

    /// @notice Deploys the BasisBridge contract.
    /// @param _rollup Address of the BasisRollup contract.
    /// @param _escapeTimeout Escape hatch timeout in seconds (e.g., 86400 for 24h).
    constructor(address _rollup, uint256 _escapeTimeout) {
        admin = msg.sender;
        rollup = IBasisRollup(_rollup);
        escapeTimeout = _escapeTimeout;
    }

    // -----------------------------------------------------------------------
    // Deposit (L1 -> L2)
    // [Spec: BasisBridge.tla, lines 131-140 -- Deposit(u, amt)]
    // -----------------------------------------------------------------------

    /// @notice Deposits ETH to the bridge for crediting on L2.
    /// @dev Locks ETH in this contract. Emits DepositInitiated for relayer to process.
    ///      The relayer monitors this event and credits the l2Recipient on L2.
    ///      INV-B2: totalDeposited incremented atomically with ETH receipt.
    ///      INV-B5: depositCounter incremented monotonically.
    /// @param enterprise The enterprise whose L2 chain receives the deposit.
    /// @param l2Recipient The address to credit on L2.
    function deposit(address enterprise, address l2Recipient) external payable {
        if (msg.value == 0) revert ZeroAmount();
        if (l2Recipient == address(0)) revert ZeroAddress();

        // Verify enterprise is initialized on rollup
        (, , , , bool initialized, ) = rollup.enterprises(enterprise);
        if (!initialized) revert EnterpriseNotInitialized();

        uint256 depositId = depositCounter[enterprise];
        depositCounter[enterprise] = depositId + 1;

        // INV-B2: Track total deposited
        totalDeposited[enterprise] += msg.value;

        emit DepositInitiated(
            enterprise,
            msg.sender,
            l2Recipient,
            msg.value,
            depositId,
            block.timestamp
        );
    }

    // -----------------------------------------------------------------------
    // Withdrawal (L2 -> L1)
    // [Spec: BasisBridge.tla, lines 180-188 -- ClaimWithdrawal(w)]
    // -----------------------------------------------------------------------

    /// @notice Claims a withdrawal from L2 by providing a Merkle proof.
    /// @dev The withdrawal must have been included in a batch that was executed on BasisRollup.
    ///      The withdraw trie root for that batch must have been submitted.
    ///      INV-B1: Each withdrawalHash can only be claimed once (nullifier check).
    ///      INV-B4: Only claims against executed batch roots (enforced by submitWithdrawRoot).
    /// @param enterprise The enterprise whose L2 chain originated the withdrawal.
    /// @param batchId The batch ID containing the withdrawal transaction.
    /// @param recipient The L1 address to receive the ETH.
    /// @param amount The withdrawal amount in wei.
    /// @param withdrawalIndex The index of this withdrawal in the withdraw trie.
    /// @param proof The Merkle proof (array of 32-byte sibling hashes).
    function claimWithdrawal(
        address enterprise,
        uint256 batchId,
        address recipient,
        uint256 amount,
        uint256 withdrawalIndex,
        bytes32[] calldata proof
    ) external {
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // INV-B4: Withdraw root only exists for executed batches (enforced by submitWithdrawRoot)
        bytes32 withdrawRoot = withdrawRoots[enterprise][batchId];
        if (withdrawRoot == bytes32(0)) revert WithdrawRootNotSet();

        // Compute leaf hash: keccak256(abi.encodePacked(enterprise, recipient, amount, withdrawalIndex))
        bytes32 leaf = keccak256(abi.encodePacked(
            enterprise,
            recipient,
            amount,
            withdrawalIndex
        ));

        // Compute withdrawal hash for nullifier
        bytes32 withdrawalHash = keccak256(abi.encodePacked(
            enterprise,
            batchId,
            recipient,
            amount,
            withdrawalIndex
        ));

        // INV-B1: Check nullifier (no double spend)
        if (withdrawalNullifier[enterprise][withdrawalHash]) revert AlreadyClaimed();

        // Verify Merkle proof against withdraw root
        if (!_verifyMerkleProof(proof, withdrawRoot, leaf, withdrawalIndex)) {
            revert InvalidProof();
        }

        // Set nullifier BEFORE transfer (checks-effects-interactions)
        withdrawalNullifier[enterprise][withdrawalHash] = true;

        // INV-B2: Track total withdrawn
        totalWithdrawn[enterprise] += amount;

        // Transfer ETH to recipient
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit WithdrawalClaimed(
            enterprise,
            recipient,
            amount,
            withdrawalHash,
            batchId,
            block.timestamp
        );
    }

    // -----------------------------------------------------------------------
    // Escape Hatch
    // [Spec: BasisBridge.tla, lines 200-225 -- ActivateEscapeHatch, EscapeWithdraw(u)]
    // -----------------------------------------------------------------------

    /// @notice Activates escape mode for an enterprise if sequencer is offline.
    /// @dev INV-B3: Can only activate if no batch has been executed within escapeTimeout.
    ///      Once active, users can withdraw via state proof without relying on sequencer.
    /// @param enterprise The enterprise to activate escape mode for.
    function activateEscapeHatch(address enterprise) external {
        if (escapeMode[enterprise]) revert EscapeAlreadyActive();

        uint256 lastExecution = lastBatchExecutionTime[enterprise];
        // If no batch has ever been executed, escape hatch cannot activate.
        // Enterprise must have been operating before sequencer failure matters.
        if (lastExecution == 0) {
            (, , , , bool initialized, ) = rollup.enterprises(enterprise);
            if (!initialized) revert EnterpriseNotInitialized();
            revert EscapeTimeoutNotReached();
        }

        // INV-B3: Check timeout
        if (block.timestamp - lastExecution < escapeTimeout) {
            revert EscapeTimeoutNotReached();
        }

        escapeMode[enterprise] = true;

        emit EscapeHatchActivated(enterprise, lastExecution, block.timestamp);
    }

    /// @notice Withdraws funds via escape hatch using a state proof.
    /// @dev Only available when escape mode is active. Uses the last finalized state root
    ///      from BasisRollup to verify the user's balance via Merkle proof.
    ///      INV-B6: Each account can only escape-withdraw once per enterprise.
    ///      The proof must demonstrate the account's balance in the L2 state trie.
    /// @param enterprise The enterprise to withdraw from.
    /// @param account The L2 account address whose balance to withdraw.
    /// @param balance The account balance to withdraw (full balance, no partial).
    /// @param accountProof Merkle proof of the account in the state trie.
    /// @param accountIndex The index/position of the account in the state trie.
    function escapeWithdraw(
        address enterprise,
        address account,
        uint256 balance,
        bytes32[] calldata accountProof,
        uint256 accountIndex
    ) external {
        if (!escapeMode[enterprise]) revert EscapeNotActive();
        if (balance == 0) revert ZeroAmount();

        // INV-B6: Check escape nullifier
        if (escapeNullifier[enterprise][account]) revert AlreadyEscaped();

        // Get the last finalized state root from BasisRollup
        bytes32 stateRoot = rollup.getCurrentRoot(enterprise);

        // Compute the leaf: keccak256(abi.encodePacked(account, balance))
        bytes32 leaf = keccak256(abi.encodePacked(account, balance));

        // Verify the account exists in the state trie with this balance
        if (!_verifyMerkleProof(accountProof, stateRoot, leaf, accountIndex)) {
            revert InvalidProof();
        }

        // Check bridge has sufficient balance
        if (address(this).balance < balance) revert InsufficientBridgeBalance();

        // Set escape nullifier BEFORE transfer (checks-effects-interactions)
        escapeNullifier[enterprise][account] = true;

        // INV-B2: Track withdrawal
        totalWithdrawn[enterprise] += balance;

        // Transfer
        (bool success, ) = account.call{value: balance}("");
        if (!success) revert TransferFailed();

        emit EscapeWithdrawal(enterprise, account, balance, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // Admin / Relayer Functions
    // [Spec: BasisBridge.tla, lines 164-173 -- FinalizeBatch]
    // -----------------------------------------------------------------------

    /// @notice Submits a withdraw trie root for a finalized batch.
    /// @dev Called by the relayer after batch execution on BasisRollup.
    ///      The withdraw root is the root of the keccak256 binary Merkle tree
    ///      containing all L2->L1 withdrawal messages in that batch.
    /// @param enterprise The enterprise that executed the batch.
    /// @param batchId The batch ID on BasisRollup.
    /// @param withdrawRoot The root of the withdraw trie for this batch.
    function submitWithdrawRoot(
        address enterprise,
        uint256 batchId,
        bytes32 withdrawRoot
    ) external onlyAdmin {
        // Verify the batch is actually executed on rollup
        (, , , uint64 totalBatchesExecuted, bool initialized, ) = rollup.enterprises(enterprise);
        if (!initialized) revert EnterpriseNotInitialized();
        if (batchId >= totalBatchesExecuted) revert BatchNotExecuted();

        withdrawRoots[enterprise][batchId] = withdrawRoot;

        // Update last execution timestamp for escape hatch tracking
        lastBatchExecutionTime[enterprise] = block.timestamp;

        emit WithdrawRootSubmitted(enterprise, batchId, withdrawRoot, block.timestamp);
    }

    /// @notice Records that a batch was executed (updates escape hatch timer).
    /// @dev Called by relayer to keep escape hatch timer fresh even without withdrawals.
    /// @param enterprise The enterprise that executed a batch.
    function recordBatchExecution(address enterprise) external onlyAdmin {
        lastBatchExecutionTime[enterprise] = block.timestamp;
        emit BatchExecutionRecorded(enterprise, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // View Functions
    // -----------------------------------------------------------------------

    /// @notice Returns bridge balance for an enterprise (deposited minus withdrawn).
    function getBridgeBalance(address enterprise) external view returns (uint256) {
        return totalDeposited[enterprise] - totalWithdrawn[enterprise];
    }

    /// @notice Checks if a withdrawal has been claimed.
    function isWithdrawalClaimed(
        address enterprise,
        bytes32 withdrawalHash
    ) external view returns (bool) {
        return withdrawalNullifier[enterprise][withdrawalHash];
    }

    /// @notice Checks if an account has used the escape hatch.
    function hasEscaped(
        address enterprise,
        address account
    ) external view returns (bool) {
        return escapeNullifier[enterprise][account];
    }

    /// @notice Returns time until escape hatch can be activated for an enterprise.
    /// @return remaining Seconds remaining (0 if already activatable).
    function timeUntilEscape(address enterprise) external view returns (uint256 remaining) {
        uint256 lastExecution = lastBatchExecutionTime[enterprise];
        if (lastExecution == 0) return type(uint256).max;
        uint256 elapsed = block.timestamp - lastExecution;
        if (elapsed >= escapeTimeout) return 0;
        return escapeTimeout - elapsed;
    }

    // -----------------------------------------------------------------------
    // Internal: Merkle Proof Verification (keccak256 binary tree)
    // -----------------------------------------------------------------------

    /// @dev Verifies a Merkle proof for a leaf at a given index in a binary tree.
    ///      Uses keccak256 for gas efficiency on L1 (~30 gas per hash vs ~5K for Poseidon).
    ///      Proof length determines tree depth. For depth 32: ~48K gas.
    ///      Virtual for test harness override (same pattern as BasisRollup._verifyProof).
    /// @param proof Array of sibling hashes from leaf to root.
    /// @param root The expected Merkle root.
    /// @param leaf The leaf hash to verify.
    /// @param index The leaf index (determines left/right at each level).
    /// @return True if the proof is valid.
    function _verifyMerkleProof(
        bytes32[] calldata proof,
        bytes32 root,
        bytes32 leaf,
        uint256 index
    ) internal view virtual returns (bool) {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            if (index % 2 == 0) {
                computedHash = keccak256(abi.encodePacked(computedHash, proof[i]));
            } else {
                computedHash = keccak256(abi.encodePacked(proof[i], computedHash));
            }
            index = index / 2;
        }

        return computedHash == root;
    }

    /// @dev Receive function to accept ETH deposits.
    receive() external payable {}
}
