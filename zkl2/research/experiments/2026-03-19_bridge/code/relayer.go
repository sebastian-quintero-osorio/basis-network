// Package relayer implements the bridge relayer for BasisBridge L1<->L2.
//
// The relayer monitors events on both L1 (BasisBridge.sol) and L2 (bridge module)
// to process deposits and withdrawals. It serves as the off-chain component that
// connects the two layers.
//
// Architecture:
//
//	L1 (BasisBridge.sol)                    L2 (Bridge Module)
//	    |                                       |
//	    | DepositInitiated event                | WithdrawalInitiated event
//	    |                                       |
//	    v                                       v
//	  [Relayer]  ---- deposit ----->  [L2 Bridge: credit balance]
//	  [Relayer]  <--- withdrawal ---  [L2 Bridge: burn/lock + withdraw trie]
//	  [Relayer]  ---- submitWithdrawRoot --->  [BasisBridge: enable claims]
//
// The relayer is enterprise-operated and runs alongside the sequencer.
// Failure of the relayer does NOT lock funds -- the escape hatch guarantees
// users can withdraw via L1 Merkle proofs after the timeout.
package relayer

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"log/slog"
	"math/big"
	"sync"
	"time"
)

// Config holds relayer configuration.
type Config struct {
	// L1 connection
	L1RPCURL       string
	BridgeAddress  string
	RollupAddress  string

	// L2 connection
	L2RPCURL string

	// Enterprise identity
	EnterpriseAddress string

	// Polling intervals
	L1PollInterval time.Duration
	L2PollInterval time.Duration

	// Retry policy
	MaxRetries     int
	RetryBackoff   time.Duration
	MaxBackoff     time.Duration

	// Processing
	BatchSize int
}

// DefaultConfig returns sensible defaults for Basis Network.
func DefaultConfig() Config {
	return Config{
		L1PollInterval: 2 * time.Second,   // Match Avalanche block time
		L2PollInterval: 1 * time.Second,    // Match L2 block time
		MaxRetries:     5,
		RetryBackoff:   1 * time.Second,
		MaxBackoff:     30 * time.Second,
		BatchSize:      100,
	}
}

// DepositEvent represents a deposit from L1 to L2.
type DepositEvent struct {
	Enterprise  string
	Depositor   string
	L2Recipient string
	Amount      *big.Int
	DepositID   uint64
	Timestamp   uint64
	L1TxHash    string
	L1Block     uint64
}

// WithdrawalEvent represents a withdrawal request from L2 to L1.
type WithdrawalEvent struct {
	Enterprise      string
	Recipient       string
	Amount          *big.Int
	WithdrawalIndex uint64
	L2Block         uint64
	L2TxHash        string
}

// WithdrawTrieEntry is a leaf in the withdraw trie.
type WithdrawTrieEntry struct {
	Enterprise      string
	Recipient       string
	Amount          *big.Int
	WithdrawalIndex uint64
}

// WithdrawTrie is a keccak256 binary Merkle tree for L2->L1 withdrawals.
type WithdrawTrie struct {
	mu     sync.RWMutex
	leaves [][]byte
	depth  int
}

// NewWithdrawTrie creates a new withdraw trie with the given depth.
func NewWithdrawTrie(depth int) *WithdrawTrie {
	return &WithdrawTrie{
		depth:  depth,
		leaves: make([][]byte, 0),
	}
}

// AppendLeaf adds a withdrawal leaf to the trie.
func (wt *WithdrawTrie) AppendLeaf(entry WithdrawTrieEntry) uint64 {
	wt.mu.Lock()
	defer wt.mu.Unlock()

	// Compute leaf hash: keccak256(enterprise || recipient || amount || index)
	// Using sha256 as stand-in for keccak256 in this prototype
	leaf := computeLeafHash(entry)
	index := uint64(len(wt.leaves))
	wt.leaves = append(wt.leaves, leaf)
	return index
}

// Root computes the Merkle root of the trie.
func (wt *WithdrawTrie) Root() []byte {
	wt.mu.RLock()
	defer wt.mu.RUnlock()

	if len(wt.leaves) == 0 {
		return make([]byte, 32) // Zero root for empty trie
	}

	// Pad leaves to next power of 2
	n := nextPowerOf2(len(wt.leaves))
	nodes := make([][]byte, n)
	for i := range nodes {
		if i < len(wt.leaves) {
			nodes[i] = wt.leaves[i]
		} else {
			nodes[i] = make([]byte, 32) // Zero leaf
		}
	}

	// Build tree bottom-up
	for len(nodes) > 1 {
		next := make([][]byte, len(nodes)/2)
		for i := 0; i < len(nodes); i += 2 {
			next[i/2] = hashPair(nodes[i], nodes[i+1])
		}
		nodes = next
	}

	return nodes[0]
}

// GenerateProof generates a Merkle proof for the leaf at the given index.
func (wt *WithdrawTrie) GenerateProof(index uint64) ([][]byte, error) {
	wt.mu.RLock()
	defer wt.mu.RUnlock()

	if int(index) >= len(wt.leaves) {
		return nil, fmt.Errorf("index %d out of range (trie has %d leaves)", index, len(wt.leaves))
	}

	// Pad leaves to next power of 2
	n := nextPowerOf2(len(wt.leaves))
	nodes := make([][]byte, n)
	for i := range nodes {
		if i < len(wt.leaves) {
			nodes[i] = wt.leaves[i]
		} else {
			nodes[i] = make([]byte, 32)
		}
	}

	proof := make([][]byte, 0)
	idx := index

	// Build proof from leaf to root
	for len(nodes) > 1 {
		// Sibling index
		var sibling uint64
		if idx%2 == 0 {
			sibling = idx + 1
		} else {
			sibling = idx - 1
		}

		if int(sibling) < len(nodes) {
			proof = append(proof, nodes[sibling])
		} else {
			proof = append(proof, make([]byte, 32))
		}

		// Move up
		next := make([][]byte, len(nodes)/2)
		for i := 0; i < len(nodes); i += 2 {
			next[i/2] = hashPair(nodes[i], nodes[i+1])
		}
		nodes = next
		idx = idx / 2
	}

	return proof, nil
}

// LeafCount returns the number of leaves in the trie.
func (wt *WithdrawTrie) LeafCount() int {
	wt.mu.RLock()
	defer wt.mu.RUnlock()
	return len(wt.leaves)
}

// Relayer processes bridge events between L1 and L2.
type Relayer struct {
	config Config
	logger *slog.Logger

	// Withdraw tries per batch
	mu           sync.Mutex
	withdrawTrie *WithdrawTrie

	// Metrics
	depositsProcessed    uint64
	withdrawalsProcessed uint64
	errorsEncountered    uint64

	// Lifecycle
	ctx    context.Context
	cancel context.CancelFunc
}

// New creates a new Relayer instance.
func New(config Config, logger *slog.Logger) *Relayer {
	ctx, cancel := context.WithCancel(context.Background())
	return &Relayer{
		config:       config,
		logger:       logger,
		withdrawTrie: NewWithdrawTrie(32),
		ctx:          ctx,
		cancel:       cancel,
	}
}

// Start begins the relayer event loop.
func (r *Relayer) Start() error {
	r.logger.Info("starting bridge relayer",
		"enterprise", r.config.EnterpriseAddress,
		"l1_poll", r.config.L1PollInterval,
		"l2_poll", r.config.L2PollInterval,
	)

	// Start L1 event watcher (deposits)
	go r.watchL1Deposits()

	// Start L2 event watcher (withdrawals)
	go r.watchL2Withdrawals()

	// Start batch submission loop
	go r.submitWithdrawRoots()

	return nil
}

// Stop gracefully shuts down the relayer.
func (r *Relayer) Stop() {
	r.logger.Info("stopping bridge relayer")
	r.cancel()
}

// ProcessDeposit handles a deposit event from L1.
// In production: sends a transaction to L2 to credit the recipient.
func (r *Relayer) ProcessDeposit(deposit DepositEvent) error {
	r.logger.Info("processing deposit",
		"enterprise", deposit.Enterprise,
		"depositor", deposit.Depositor,
		"recipient", deposit.L2Recipient,
		"amount", deposit.Amount.String(),
		"deposit_id", deposit.DepositID,
	)

	// In production:
	// 1. Verify the deposit event came from the correct BasisBridge contract
	// 2. Submit an L2 transaction to credit l2Recipient with the deposited amount
	// 3. Include the deposit in the forced inclusion queue if needed
	// 4. Wait for L2 transaction confirmation

	r.depositsProcessed++
	return nil
}

// ProcessWithdrawal handles a withdrawal event from L2.
// Adds the withdrawal to the withdraw trie for the current batch.
func (r *Relayer) ProcessWithdrawal(withdrawal WithdrawalEvent) error {
	r.logger.Info("processing withdrawal",
		"enterprise", withdrawal.Enterprise,
		"recipient", withdrawal.Recipient,
		"amount", withdrawal.Amount.String(),
		"index", withdrawal.WithdrawalIndex,
	)

	r.mu.Lock()
	defer r.mu.Unlock()

	// Add to withdraw trie
	r.withdrawTrie.AppendLeaf(WithdrawTrieEntry{
		Enterprise:      withdrawal.Enterprise,
		Recipient:       withdrawal.Recipient,
		Amount:          withdrawal.Amount,
		WithdrawalIndex: withdrawal.WithdrawalIndex,
	})

	r.withdrawalsProcessed++
	return nil
}

// GetWithdrawalProof generates a Merkle proof for a specific withdrawal.
func (r *Relayer) GetWithdrawalProof(index uint64) (root []byte, proof [][]byte, err error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	root = r.withdrawTrie.Root()
	proof, err = r.withdrawTrie.GenerateProof(index)
	return
}

// Metrics returns current relayer metrics.
func (r *Relayer) Metrics() RelayerMetrics {
	return RelayerMetrics{
		DepositsProcessed:    r.depositsProcessed,
		WithdrawalsProcessed: r.withdrawalsProcessed,
		ErrorsEncountered:    r.errorsEncountered,
		WithdrawTrieLeaves:   uint64(r.withdrawTrie.LeafCount()),
	}
}

// RelayerMetrics holds operational metrics.
type RelayerMetrics struct {
	DepositsProcessed    uint64
	WithdrawalsProcessed uint64
	ErrorsEncountered    uint64
	WithdrawTrieLeaves   uint64
}

// --- Internal methods ---

func (r *Relayer) watchL1Deposits() {
	ticker := time.NewTicker(r.config.L1PollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-r.ctx.Done():
			return
		case <-ticker.C:
			// In production: query L1 for DepositInitiated events
			// Filter by enterprise address
			// Process each new deposit
			r.logger.Debug("polling L1 for deposit events")
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
			// In production: query L2 for WithdrawalInitiated events
			// Add each withdrawal to the withdraw trie
			r.logger.Debug("polling L2 for withdrawal events")
		}
	}
}

func (r *Relayer) submitWithdrawRoots() {
	// In production: after each batch is executed on BasisRollup,
	// compute the withdraw trie root and submit it via
	// BasisBridge.submitWithdrawRoot(enterprise, batchId, root)
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-r.ctx.Done():
			return
		case <-ticker.C:
			r.mu.Lock()
			if r.withdrawTrie.LeafCount() > 0 {
				root := r.withdrawTrie.Root()
				r.logger.Info("withdraw trie root computed",
					"root", fmt.Sprintf("%x", root),
					"leaves", r.withdrawTrie.LeafCount(),
				)
				// In production: submit root to BasisBridge.sol
				// Reset trie for next batch
				r.withdrawTrie = NewWithdrawTrie(32)
			}
			r.mu.Unlock()
		}
	}
}

// --- Utility functions ---

func computeLeafHash(entry WithdrawTrieEntry) []byte {
	// keccak256(abi.encodePacked(enterprise, recipient, amount, withdrawalIndex))
	// Using sha256 as stand-in in this prototype
	h := sha256.New()
	h.Write([]byte(entry.Enterprise))
	h.Write([]byte(entry.Recipient))
	if entry.Amount != nil {
		h.Write(entry.Amount.Bytes())
	}
	buf := make([]byte, 8)
	binary.BigEndian.PutUint64(buf, entry.WithdrawalIndex)
	h.Write(buf)
	return h.Sum(nil)
}

func hashPair(left, right []byte) []byte {
	h := sha256.New()
	h.Write(left)
	h.Write(right)
	return h.Sum(nil)
}

func nextPowerOf2(n int) int {
	if n <= 1 {
		return 1
	}
	p := 1
	for p < n {
		p *= 2
	}
	return p
}
