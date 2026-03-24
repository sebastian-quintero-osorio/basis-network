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
// [Spec: zkl2/specs/units/2026-03-bridge/1-formalization/v0-analysis/specs/BasisBridge/BasisBridge.tla]
package bridge

import (
	"errors"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// Config holds relayer configuration.
// [Spec: BasisBridge.tla -- enterprise-operated relayer alongside sequencer]
type Config struct {
	// L1 connection
	L1RPCURL      string
	BridgeAddress common.Address
	RollupAddress common.Address

	// L2 connection
	L2RPCURL string

	// Enterprise identity
	Enterprise common.Address

	// Polling intervals
	L1PollInterval time.Duration
	L2PollInterval time.Duration

	// Retry policy
	MaxRetries   int
	RetryBackoff time.Duration
	MaxBackoff   time.Duration

	// Processing
	TrieDepth int
}

// DefaultConfig returns sensible defaults for Basis Network.
func DefaultConfig() Config {
	return Config{
		L1PollInterval: 2 * time.Second,  // Match Avalanche sub-2s block time
		L2PollInterval: 1 * time.Second,  // Match L2 block time
		MaxRetries:     5,
		RetryBackoff:   1 * time.Second,
		MaxBackoff:     30 * time.Second,
		TrieDepth:      32,
	}
}

// Validate checks that required fields are set.
func (c Config) Validate() error {
	if c.Enterprise == (common.Address{}) {
		return ErrMissingEnterprise
	}
	if c.L1PollInterval <= 0 {
		return ErrInvalidPollInterval
	}
	if c.L2PollInterval <= 0 {
		return ErrInvalidPollInterval
	}
	if c.TrieDepth <= 0 || c.TrieDepth > 256 {
		return ErrInvalidTrieDepth
	}
	return nil
}

// DepositEvent represents a deposit from L1 to L2.
// [Spec: BasisBridge.tla, Deposit(u, amt) -- L1 lock + L2 credit]
type DepositEvent struct {
	Enterprise  common.Address
	Depositor   common.Address
	L2Recipient common.Address
	Amount      *big.Int
	DepositID   uint64
	Timestamp   uint64
	L1TxHash    common.Hash
	L1Block     uint64
}

// WithdrawalEvent represents a withdrawal request from L2 to L1.
// [Spec: BasisBridge.tla, InitiateWithdrawal(u, amt) -- L2 burn + pending set]
type WithdrawalEvent struct {
	Enterprise      common.Address
	Recipient       common.Address
	Amount          *big.Int
	WithdrawalIndex uint64
	L2Block         uint64
	L2TxHash        common.Hash
}

// WithdrawTrieEntry is a leaf in the withdraw trie.
// Encoded as: keccak256(abi.encodePacked(enterprise, recipient, amount, withdrawalIndex))
// Must match BasisBridge.sol claimWithdrawal leaf computation.
type WithdrawTrieEntry struct {
	Enterprise      common.Address
	Recipient       common.Address
	Amount          *big.Int
	WithdrawalIndex uint64
}

// Metrics holds operational counters for the relayer.
type Metrics struct {
	DepositsProcessed    uint64
	WithdrawalsProcessed uint64
	WithdrawRootsPosted  uint64
	ErrorsEncountered    uint64
	WithdrawTrieLeaves   uint64
	LastL1Block          uint64
	LastL2Block          uint64
}

// DepositHandler is called when a deposit needs to be credited on L2.
// The node provides this callback to connect the relayer to the L2 StateDB.
type DepositHandler func(recipient common.Address, amount *big.Int, depositID uint64) error

// WithdrawalHandler is called when a withdrawal needs to burn balance on L2.
// Returns error if the user has insufficient balance.
type WithdrawalHandler func(sender common.Address, amount *big.Int) error

// WithdrawRootSubmitter submits a withdraw trie root to BasisBridge.sol on L1.
// Called after a batch is executed on BasisRollup.
type WithdrawRootSubmitter func(root common.Hash, leafCount uint64) error

// Sentinel errors for relayer operations.
var (
	ErrMissingEnterprise   = errors.New("enterprise address is required")
	ErrInvalidPollInterval = errors.New("poll interval must be positive")
	ErrInvalidTrieDepth    = errors.New("trie depth must be between 1 and 256")
	ErrRelayerStopped      = errors.New("relayer has been stopped")
	ErrTrieIndexOutOfRange = errors.New("trie index out of range")
)
