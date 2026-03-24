// Package sequencer implements the enterprise L2 sequencer for Basis Network zkEVM.
//
// The sequencer is a single-operator block producer that:
//   - Maintains a FIFO mempool for regular transactions
//   - Manages an Arbitrum-style forced inclusion queue for L1-submitted transactions
//   - Produces L2 blocks at configurable intervals
//   - Integrates with the EVM executor for transaction execution
//
// The implementation is derived from the formally verified TLA+ specification.
// All safety invariants (NoDoubleInclusion, ForcedInclusionDeadline, FIFOWithinBlock,
// ForcedBeforeMempool, IncludedWereSubmitted) are enforced structurally by the
// queue-based design and verified by adversarial tests.
//
// [Spec: zkl2/specs/units/2026-03-sequencer/1-formalization/v0-analysis/specs/Sequencer/Sequencer.tla]
package sequencer

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"math/big"
	"time"
)

// -----------------------------------------------------------------------------
// Transaction types
// [Spec: Txs set -- regular transaction identifiers]
// -----------------------------------------------------------------------------

// TxHash is a 32-byte transaction identifier.
type TxHash [32]byte

// Address is a 20-byte account address.
type Address [20]byte

// Transaction represents an L2 transaction submitted to the sequencer mempool.
// Each transaction receives a monotonic SeqNum upon insertion, which determines
// FIFO ordering within blocks.
//
// [Spec: Txs set elements; submitOrder maps tx -> global sequence number]
type Transaction struct {
	Hash      TxHash    // Unique transaction identifier
	From      Address   // Sender address
	To        *Address  // Recipient address (nil for contract creation)
	Nonce     uint64    // Sender nonce
	Data      []byte    // Calldata
	GasLimit  uint64    // Gas limit (metering only, zero-fee model)
	Value     *big.Int  // Transfer value (wei) -- full 256-bit precision
	Timestamp time.Time // Arrival time at sequencer
	SeqNum    uint64    // Monotonic sequence number assigned by mempool (FIFO key)
}

// ComputeTxHash produces a deterministic hash for a transaction from its identifying fields.
func ComputeTxHash(from Address, nonce uint64, data []byte) TxHash {
	h := sha256.New()
	h.Write(from[:])
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], nonce)
	h.Write(buf[:])
	h.Write(data)
	return TxHash(h.Sum(nil))
}

// -----------------------------------------------------------------------------
// Forced transaction types
// [Spec: ForcedTxs set -- forced transaction identifiers submitted via L1]
// [Spec: forcedSubmitBlock -- maps forced tx to block number at submission]
// -----------------------------------------------------------------------------

// ForcedTransaction represents a transaction submitted via L1 for forced inclusion on L2.
// The sequencer must include forced transactions in FIFO order within
// ForcedDeadlineBlocks of their submission.
//
// [Spec: ForcedTxs set; forcedSubmitBlock[ftx] records submission block number]
type ForcedTransaction struct {
	Tx             Transaction // The wrapped L2 transaction
	L1BlockNumber  uint64      // L1 block where the forced tx was submitted
	SubmitBlockNum uint64      // L2 block number at time of submission (for deadline)
}

// -----------------------------------------------------------------------------
// Block types
// [Spec: blocks variable -- Seq(Seq(AllTxIds)), produced blocks]
// [Spec: blockNum variable -- Nat, blocks produced so far]
// -----------------------------------------------------------------------------

// BlockState represents the lifecycle state of an L2 block.
//
// Lifecycle: pending -> sealed -> committed -> proved -> finalized
// The sequencer is responsible for pending -> sealed transitions.
// Downstream components handle commit/prove/finalize.
type BlockState int

const (
	BlockPending   BlockState = iota // Transactions being collected
	BlockSealed                      // Block closed, tx selection complete
	BlockCommitted                   // Batch data posted to L1
	BlockProved                      // ZK proof verified on L1
	BlockFinalized                   // L1 state root accepted
)

// String returns the human-readable block state name.
func (s BlockState) String() string {
	switch s {
	case BlockPending:
		return "pending"
	case BlockSealed:
		return "sealed"
	case BlockCommitted:
		return "committed"
	case BlockProved:
		return "proved"
	case BlockFinalized:
		return "finalized"
	default:
		return fmt.Sprintf("unknown(%d)", s)
	}
}

// L2Block represents a produced L2 block.
//
// [Spec: blocks[i] -- Seq(AllTxIds), ordered transaction sequence in block i]
type L2Block struct {
	Number       uint64        // L2 block number
	ParentHash   TxHash        // Hash of parent block
	Timestamp    time.Time     // Block production start timestamp
	Transactions []Transaction // Ordered transactions (forced first, then mempool)
	GasUsed      uint64        // Total gas consumed
	GasLimit     uint64        // Block gas limit
	State        BlockState    // Current lifecycle state
	SealedAt     time.Time     // When block was sealed
	ProductionNs int64         // Block production duration in nanoseconds
}

// BlockHash computes the block hash from its contents.
func (b *L2Block) BlockHash() TxHash {
	h := sha256.New()
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], b.Number)
	h.Write(buf[:])
	h.Write(b.ParentHash[:])
	binary.BigEndian.PutUint64(buf[:], uint64(b.Timestamp.UnixNano()))
	h.Write(buf[:])
	for i := range b.Transactions {
		h.Write(b.Transactions[i].Hash[:])
	}
	return TxHash(h.Sum(nil))
}

// TxCount returns the number of transactions in the block.
func (b *L2Block) TxCount() int {
	return len(b.Transactions)
}

// IsEmpty returns true if the block contains no transactions.
func (b *L2Block) IsEmpty() bool {
	return len(b.Transactions) == 0
}

// -----------------------------------------------------------------------------
// Configuration
// -----------------------------------------------------------------------------

// Config holds configuration for the sequencer.
//
// [Spec: CONSTANTS -- MaxTxPerBlock, MaxBlocks, ForcedDeadlineBlocks]
type Config struct {
	// BlockInterval is the target block production interval.
	BlockInterval time.Duration

	// BlockGasLimit is the maximum gas per block.
	// [Spec: abstracted -- model uses MaxTxPerBlock as sole capacity bound]
	BlockGasLimit uint64

	// MaxTxPerBlock is the maximum transactions per block.
	// [Spec: MaxTxPerBlock constant]
	MaxTxPerBlock int

	// MempoolCapacity is the maximum pending transactions in the mempool.
	MempoolCapacity int

	// ForcedDeadlineBlocks is the number of L2 blocks within which a forced
	// transaction must be included after submission.
	// [Spec: ForcedDeadlineBlocks constant]
	ForcedDeadlineBlocks uint64

	// DefaultTxGas is the default gas per transaction when GasLimit is 0.
	DefaultTxGas uint64
}

// DefaultConfig returns production defaults for the enterprise sequencer.
//
// Block time: 1s, gas limit: 10M, max 500 tx/block, 10K mempool,
// 24h forced inclusion (at 1s blocks = 86400 blocks), 21K default gas.
func DefaultConfig() Config {
	return Config{
		BlockInterval:        1 * time.Second,
		BlockGasLimit:        10_000_000,
		MaxTxPerBlock:        500,
		MempoolCapacity:      10_000,
		ForcedDeadlineBlocks: 86_400, // 24h at 1s blocks
		DefaultTxGas:         21_000,
	}
}

// Validate checks that configuration values are within acceptable bounds.
func (c Config) Validate() error {
	if c.BlockInterval <= 0 {
		return errors.New("sequencer: block interval must be positive")
	}
	if c.BlockGasLimit == 0 {
		return errors.New("sequencer: block gas limit must be positive")
	}
	if c.MaxTxPerBlock <= 0 {
		return errors.New("sequencer: max tx per block must be positive")
	}
	if c.MempoolCapacity <= 0 {
		return errors.New("sequencer: mempool capacity must be positive")
	}
	if c.ForcedDeadlineBlocks == 0 {
		return errors.New("sequencer: forced deadline blocks must be positive")
	}
	if c.DefaultTxGas == 0 {
		return errors.New("sequencer: default tx gas must be positive")
	}
	return nil
}

// -----------------------------------------------------------------------------
// Errors
// -----------------------------------------------------------------------------

var (
	// ErrMempoolFull is returned when the mempool has reached capacity.
	ErrMempoolFull = errors.New("sequencer: mempool full")

	// ErrSequencerStopped is returned when operations are attempted on a stopped sequencer.
	ErrSequencerStopped = errors.New("sequencer: stopped")

	// ErrInvalidConfig is returned when sequencer configuration is invalid.
	ErrInvalidConfig = errors.New("sequencer: invalid configuration")
)
