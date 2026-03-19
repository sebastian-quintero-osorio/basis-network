// Package sequencer implements an enterprise L2 sequencer prototype for
// benchmarking block production, mempool throughput, and forced inclusion.
package sequencer

import (
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"sync"
	"time"
)

// Transaction represents an L2 transaction submitted to the sequencer.
type Transaction struct {
	Hash      [32]byte  // Unique transaction identifier
	From      [20]byte  // Sender address
	To        [20]byte  // Recipient address
	Nonce     uint64    // Sender nonce
	Data      []byte    // Calldata
	GasLimit  uint64    // Gas limit (metering only, zero-fee)
	Value     uint64    // Transfer value (wei)
	Timestamp time.Time // Arrival time at sequencer (for FIFO ordering)
	SeqNum    uint64    // Monotonic sequence number assigned by mempool
}

// TxHash computes a deterministic hash for a transaction.
func TxHash(from [20]byte, nonce uint64, data []byte) [32]byte {
	h := sha256.New()
	h.Write(from[:])
	binary.Write(h, binary.BigEndian, nonce)
	h.Write(data)
	return [32]byte(h.Sum(nil))
}

// ForcedTransaction represents a transaction submitted via L1 for forced inclusion.
type ForcedTransaction struct {
	Tx            Transaction
	L1BlockNumber uint64    // L1 block where the forced tx was submitted
	L1Timestamp   time.Time // L1 block timestamp
	Deadline      time.Time // Must be included by this time (L1Timestamp + MaxDelay)
}

// Block represents an L2 block produced by the sequencer.
type Block struct {
	Number       uint64         // L2 block number
	ParentHash   [32]byte       // Hash of parent block
	Timestamp    time.Time      // Block production timestamp
	Transactions []Transaction  // Ordered transactions in block
	GasUsed      uint64         // Total gas consumed
	GasLimit     uint64         // Block gas limit
	SealedAt     time.Time      // When block was sealed
	ProducedInNs int64          // Block production duration in nanoseconds
}

// BlockHash computes the block hash.
func (b *Block) BlockHash() [32]byte {
	h := sha256.New()
	binary.Write(h, binary.BigEndian, b.Number)
	h.Write(b.ParentHash[:])
	binary.Write(h, binary.BigEndian, b.Timestamp.UnixNano())
	for _, tx := range b.Transactions {
		h.Write(tx.Hash[:])
	}
	return [32]byte(h.Sum(nil))
}

// BlockState represents the lifecycle state of a block.
type BlockState int

const (
	BlockPending   BlockState = iota // Transactions being collected
	BlockSealed                      // Block closed, tx selection complete
	BlockCommitted                   // Batch data posted to L1
	BlockProved                      // ZK proof verified on L1
	BlockFinalized                   // L1 state root accepted
)

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

// SequencerConfig holds configuration for the sequencer.
type SequencerConfig struct {
	BlockTimeMs          int64  // Target block production interval (ms)
	BlockGasLimit        uint64 // Maximum gas per block
	MaxTxPerBlock        int    // Maximum transactions per block
	MempoolCapacity      int    // Maximum pending transactions
	ForcedInclusionDelay time.Duration // Max delay for forced transactions
	DefaultTxGas         uint64 // Default gas per transaction (for simulation)
}

// DefaultConfig returns production-like defaults.
func DefaultConfig() SequencerConfig {
	return SequencerConfig{
		BlockTimeMs:          1000,          // 1 second blocks
		BlockGasLimit:        10_000_000,    // 10M gas limit
		MaxTxPerBlock:        500,           // Up to 500 tx/block
		MempoolCapacity:      10_000,        // 10K pending tx
		ForcedInclusionDelay: 24 * time.Hour, // 24h forced inclusion window
		DefaultTxGas:         21_000,        // Simple transfer gas
	}
}

// Metrics holds sequencer performance metrics.
type Metrics struct {
	mu sync.Mutex

	// Block production
	BlocksProduced        int
	TotalBlockProductionNs int64
	EmptyBlocks           int

	// Mempool
	TxInserted            int
	TxIncluded            int
	TxDropped             int
	MempoolHighWatermark  int

	// Forced inclusion
	ForcedTxSubmitted     int
	ForcedTxIncluded      int
	ForcedTxExpired       int
	MaxForcedLatencyNs    int64

	// Ordering
	FIFOViolations        int
	TotalOrderingChecks   int
}

// AvgBlockProductionMs returns average block production time.
func (m *Metrics) AvgBlockProductionMs() float64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.BlocksProduced == 0 {
		return 0
	}
	return float64(m.TotalBlockProductionNs) / float64(m.BlocksProduced) / 1e6
}

// FIFOAccuracy returns the percentage of correctly ordered transactions.
func (m *Metrics) FIFOAccuracy() float64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.TotalOrderingChecks == 0 {
		return 100.0
	}
	return 100.0 * float64(m.TotalOrderingChecks-m.FIFOViolations) / float64(m.TotalOrderingChecks)
}

// BlockFillRatio returns the average block fill ratio.
func (m *Metrics) BlockFillRatio(gasLimit uint64) float64 {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.BlocksProduced == 0 || m.BlocksProduced == m.EmptyBlocks {
		return 0
	}
	totalGasUsed := uint64(m.TxIncluded) * 21_000 // Approximate
	nonEmptyBlocks := m.BlocksProduced - m.EmptyBlocks
	if nonEmptyBlocks == 0 {
		return 0
	}
	avgGasPerBlock := float64(totalGasUsed) / float64(nonEmptyBlocks)
	return avgGasPerBlock / float64(gasLimit) * 100.0
}
