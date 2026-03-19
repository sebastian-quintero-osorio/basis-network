package sequencer

import (
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"
)

// Mempool implements a FIFO transaction pool for the enterprise sequencer.
//
// Zero-fee model means no priority ordering -- transactions are ordered strictly
// by arrival time via a monotonic sequence number (SeqNum). This is simpler than
// Geth's txpool which uses gas price priority.
//
// Thread safety: all public methods are safe for concurrent use via sync.Mutex.
//
// [Spec: mempool variable -- Seq(Txs), FIFO queue of pending regular transactions]
// [Spec: SubmitTx(tx) -- Append(mempool, tx), assigns submitOrder]
// [Spec: zkl2/specs/units/2026-03-sequencer/1-formalization/v0-analysis/specs/Sequencer/Sequencer.tla]
type Mempool struct {
	mu       sync.Mutex
	txs      []Transaction
	seen     map[TxHash]struct{} // Deduplication: prevents double-submission
	capacity int
	seqGen   atomic.Uint64
	logger   *slog.Logger
}

// NewMempool creates a FIFO mempool with the given capacity.
func NewMempool(capacity int, logger *slog.Logger) *Mempool {
	if logger == nil {
		logger = slog.Default()
	}
	return &Mempool{
		txs:      make([]Transaction, 0, min(capacity, 4096)),
		seen:     make(map[TxHash]struct{}, min(capacity, 4096)),
		capacity: capacity,
		logger:   logger,
	}
}

// Add inserts a transaction into the mempool. The transaction receives a monotonic
// sequence number that determines FIFO ordering within blocks.
//
// Returns ErrMempoolFull if the mempool is at capacity.
// Duplicate transactions (same hash) are silently ignored and return nil.
//
// [Spec: SubmitTx(tx) -- tx \notin DOMAIN submitOrder, Append(mempool, tx)]
func (mp *Mempool) Add(tx Transaction) error {
	mp.mu.Lock()
	defer mp.mu.Unlock()

	// Deduplication: ignore already-seen transactions.
	// [Spec: tx \notin DOMAIN submitOrder -- not previously submitted]
	if _, exists := mp.seen[tx.Hash]; exists {
		return nil
	}

	if len(mp.txs) >= mp.capacity {
		return fmt.Errorf("%w: capacity %d", ErrMempoolFull, mp.capacity)
	}

	tx.Timestamp = time.Now()
	tx.SeqNum = mp.seqGen.Add(1)

	mp.txs = append(mp.txs, tx)
	mp.seen[tx.Hash] = struct{}{}

	mp.logger.Debug("mempool: transaction added",
		"tx_hash", fmt.Sprintf("%x", tx.Hash[:8]),
		"seq_num", tx.SeqNum,
		"pending", len(mp.txs),
	)

	return nil
}

// AddBatch inserts multiple transactions atomically. Returns the number of
// transactions added and dropped (due to capacity).
func (mp *Mempool) AddBatch(txs []Transaction) (added int, dropped int) {
	mp.mu.Lock()
	defer mp.mu.Unlock()

	now := time.Now()
	for i := range txs {
		if _, exists := mp.seen[txs[i].Hash]; exists {
			continue
		}
		if len(mp.txs) >= mp.capacity {
			dropped += len(txs) - i
			break
		}
		txs[i].Timestamp = now
		txs[i].SeqNum = mp.seqGen.Add(1)
		mp.txs = append(mp.txs, txs[i])
		mp.seen[txs[i].Hash] = struct{}{}
		added++
	}

	if added > 0 {
		mp.logger.Debug("mempool: batch added",
			"added", added,
			"dropped", dropped,
			"pending", len(mp.txs),
		)
	}

	return added, dropped
}

// Drain removes up to maxTx transactions from the front of the mempool,
// respecting the gas limit. Returns transactions in FIFO order.
//
// Drained transactions are removed from the mempool and their deduplication
// entries are cleaned up. This ensures NoDoubleInclusion: once drained,
// a transaction cannot re-enter the mempool.
//
// [Spec: Take(mempool, mempoolCount) -- takes from front, then Drop removes them]
func (mp *Mempool) Drain(maxTx int, gasLimit uint64, defaultGas uint64) []Transaction {
	mp.mu.Lock()
	defer mp.mu.Unlock()

	if len(mp.txs) == 0 || maxTx <= 0 {
		return nil
	}

	n := len(mp.txs)
	if n > maxTx {
		n = maxTx
	}

	result := make([]Transaction, 0, n)
	gasUsed := uint64(0)

	for i := 0; i < n; i++ {
		txGas := mp.txs[i].GasLimit
		if txGas == 0 {
			txGas = defaultGas
		}
		if gasUsed+txGas > gasLimit {
			break
		}
		result = append(result, mp.txs[i])
		gasUsed += txGas
	}

	// Remove drained transactions from the front.
	// [Spec: mempool' = Drop(mempool, mempoolCount)]
	drained := len(result)
	copy(mp.txs, mp.txs[drained:])
	mp.txs = mp.txs[:len(mp.txs)-drained]

	return result
}

// Len returns the current number of pending transactions.
func (mp *Mempool) Len() int {
	mp.mu.Lock()
	defer mp.mu.Unlock()
	return len(mp.txs)
}

// RemoveIncluded removes transactions that were included in a block from
// the deduplication set. This allows the hash to be resubmitted in the future
// (relevant for nonce-bumped replacements).
func (mp *Mempool) RemoveIncluded(txs []Transaction) {
	mp.mu.Lock()
	defer mp.mu.Unlock()
	for i := range txs {
		delete(mp.seen, txs[i].Hash)
	}
}
