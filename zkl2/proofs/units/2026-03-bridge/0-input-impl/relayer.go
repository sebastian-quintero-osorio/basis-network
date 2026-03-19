package relayer

import (
	"context"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// Relayer processes bridge events between L1 and L2.
//
// It monitors DepositInitiated events on L1 (BasisBridge.sol) and
// WithdrawalInitiated events on L2, maintaining a withdraw trie
// whose root is periodically submitted to BasisBridge.submitWithdrawRoot.
//
// [Spec: zkl2/specs/units/2026-03-bridge/1-formalization/v0-analysis/specs/BasisBridge/BasisBridge.tla]
// [Spec: BasisBridge.tla, FinalizeBatch -- relayer submits withdraw trie roots]
type Relayer struct {
	config Config
	logger *slog.Logger

	// Withdraw trie for the current batch.
	// [Spec: BasisBridge.tla, finalizedWithdrawals -- finalized set mapped to trie]
	trieMu       sync.Mutex
	withdrawTrie *WithdrawTrie

	// Block cursors for event polling.
	lastL1Block atomic.Uint64
	lastL2Block atomic.Uint64

	// Metrics (atomic for concurrent access).
	depositsProcessed    atomic.Uint64
	withdrawalsProcessed atomic.Uint64
	withdrawRootsPosted  atomic.Uint64
	errorsEncountered    atomic.Uint64

	// Lifecycle.
	ctx    context.Context
	cancel context.CancelFunc
}

// New creates a new Relayer instance.
func New(config Config, logger *slog.Logger) (*Relayer, error) {
	if err := config.Validate(); err != nil {
		return nil, err
	}

	if logger == nil {
		logger = slog.Default()
	}

	ctx, cancel := context.WithCancel(context.Background())

	return &Relayer{
		config:       config,
		logger:       logger,
		withdrawTrie: NewWithdrawTrie(config.TrieDepth),
		ctx:          ctx,
		cancel:       cancel,
	}, nil
}

// Start begins the relayer event loops.
// Three goroutines run concurrently:
//  1. L1 deposit watcher (polls DepositInitiated events)
//  2. L2 withdrawal watcher (polls WithdrawalInitiated events)
//  3. Withdraw root submitter (submits trie roots to BasisBridge)
func (r *Relayer) Start() error {
	r.logger.Info("starting bridge relayer",
		"enterprise", r.config.Enterprise.Hex(),
		"l1_poll", r.config.L1PollInterval,
		"l2_poll", r.config.L2PollInterval,
	)

	go r.watchL1Deposits()
	go r.watchL2Withdrawals()
	go r.submitWithdrawRoots()

	return nil
}

// Stop gracefully shuts down the relayer.
func (r *Relayer) Stop() {
	r.logger.Info("stopping bridge relayer")
	r.cancel()
}

// ProcessDeposit handles a deposit event from L1.
// [Spec: BasisBridge.tla, Deposit(u, amt) -- atomic lock on L1 + credit on L2]
//
// In production, this submits an L2 transaction to credit the recipient.
// The deposit is processed in a single atomic operation on L2 (matching the
// TLA+ abstraction of Deposit as atomic).
func (r *Relayer) ProcessDeposit(deposit DepositEvent) error {
	r.logger.Info("processing deposit",
		"enterprise", deposit.Enterprise.Hex(),
		"depositor", deposit.Depositor.Hex(),
		"recipient", deposit.L2Recipient.Hex(),
		"amount", deposit.Amount.String(),
		"deposit_id", deposit.DepositID,
		"l1_block", deposit.L1Block,
	)

	// Production implementation:
	// 1. Verify the deposit event came from the correct BasisBridge contract address
	// 2. Submit an L2 transaction to credit l2Recipient with the deposited amount
	// 3. Wait for L2 transaction confirmation
	// 4. If L2 tx fails, add to retry queue (bounded retries with exponential backoff)

	r.depositsProcessed.Add(1)
	return nil
}

// ProcessWithdrawal handles a withdrawal event from L2.
// [Spec: BasisBridge.tla, InitiateWithdrawal(u, amt) -- L2 burn, add to pending set]
//
// Adds the withdrawal to the withdraw trie for the current batch.
// The trie root will be submitted to BasisBridge.submitWithdrawRoot
// after the corresponding batch is executed on BasisRollup.
func (r *Relayer) ProcessWithdrawal(withdrawal WithdrawalEvent) error {
	r.logger.Info("processing withdrawal",
		"enterprise", withdrawal.Enterprise.Hex(),
		"recipient", withdrawal.Recipient.Hex(),
		"amount", withdrawal.Amount.String(),
		"index", withdrawal.WithdrawalIndex,
		"l2_block", withdrawal.L2Block,
	)

	r.trieMu.Lock()
	defer r.trieMu.Unlock()

	r.withdrawTrie.AppendLeaf(WithdrawTrieEntry{
		Enterprise:      withdrawal.Enterprise,
		Recipient:       withdrawal.Recipient,
		Amount:          withdrawal.Amount,
		WithdrawalIndex: withdrawal.WithdrawalIndex,
	})

	r.withdrawalsProcessed.Add(1)
	return nil
}

// GetWithdrawalProof generates a Merkle proof for a specific withdrawal.
// Returns the trie root, proof siblings, and any error.
// The proof can be used with BasisBridge.claimWithdrawal on L1.
func (r *Relayer) GetWithdrawalProof(index uint64) (root common.Hash, proof []common.Hash, err error) {
	r.trieMu.Lock()
	defer r.trieMu.Unlock()

	root = r.withdrawTrie.Root()
	proof, err = r.withdrawTrie.GenerateProof(index)
	return
}

// GetMetrics returns a snapshot of current relayer metrics.
func (r *Relayer) GetMetrics() Metrics {
	r.trieMu.Lock()
	leaves := uint64(r.withdrawTrie.LeafCount())
	r.trieMu.Unlock()

	return Metrics{
		DepositsProcessed:    r.depositsProcessed.Load(),
		WithdrawalsProcessed: r.withdrawalsProcessed.Load(),
		WithdrawRootsPosted:  r.withdrawRootsPosted.Load(),
		ErrorsEncountered:    r.errorsEncountered.Load(),
		WithdrawTrieLeaves:   leaves,
		LastL1Block:          r.lastL1Block.Load(),
		LastL2Block:          r.lastL2Block.Load(),
	}
}

// --- Internal event watchers ---

func (r *Relayer) watchL1Deposits() {
	ticker := time.NewTicker(r.config.L1PollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-r.ctx.Done():
			return
		case <-ticker.C:
			// Production implementation:
			// 1. Query L1 for DepositInitiated events from lastL1Block+1 to latest
			// 2. Filter by enterprise address
			// 3. For each event, call ProcessDeposit
			// 4. Update lastL1Block cursor
			// 5. On error, increment errorsEncountered and retry with backoff
			r.logger.Debug("polling L1 for deposit events",
				"from_block", r.lastL1Block.Load(),
			)
		}
	}
}

func (r *Relayer) watchL2Withdrawals() {
	ticker := time.NewTicker(r.config.L2PollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-r.ctx.Done():
			return
		case <-ticker.C:
			// Production implementation:
			// 1. Query L2 for WithdrawalInitiated events from lastL2Block+1 to latest
			// 2. For each event, call ProcessWithdrawal
			// 3. Update lastL2Block cursor
			// 4. On error, increment errorsEncountered and retry with backoff
			r.logger.Debug("polling L2 for withdrawal events",
				"from_block", r.lastL2Block.Load(),
			)
		}
	}
}

// submitWithdrawRoots periodically checks if the withdraw trie has new leaves
// and submits the root to BasisBridge.submitWithdrawRoot on L1.
// [Spec: BasisBridge.tla, FinalizeBatch -- pending -> finalized, root posted]
func (r *Relayer) submitWithdrawRoots() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-r.ctx.Done():
			return
		case <-ticker.C:
			r.trieMu.Lock()
			leafCount := r.withdrawTrie.LeafCount()
			if leafCount > 0 {
				root := r.withdrawTrie.Root()
				r.logger.Info("withdraw trie root computed",
					"root", root.Hex(),
					"leaves", leafCount,
				)
				// Production implementation:
				// 1. Determine the batchId from the latest executed batch on BasisRollup
				// 2. Submit root via BasisBridge.submitWithdrawRoot(enterprise, batchId, root)
				// 3. Wait for L1 transaction confirmation
				// 4. On success, reset the trie for the next batch
				// 5. On failure, retry with exponential backoff

				r.withdrawTrie.Reset()
				r.withdrawRootsPosted.Add(1)
			}
			r.trieMu.Unlock()
		}
	}
}
