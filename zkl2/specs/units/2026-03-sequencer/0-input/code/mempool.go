package sequencer

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

// Mempool implements a FIFO transaction pool for the enterprise sequencer.
// Zero-fee model means no priority ordering -- transactions are ordered strictly
// by arrival time (SeqNum). This is simpler than Geth's txpool which uses
// gas price priority.
type Mempool struct {
	mu       sync.Mutex
	txs      []Transaction // FIFO queue (append at tail, drain from head)
	capacity int
	seqGen   atomic.Uint64
	metrics  *Metrics
}

// NewMempool creates a FIFO mempool with the given capacity.
func NewMempool(capacity int, metrics *Metrics) *Mempool {
	return &Mempool{
		txs:      make([]Transaction, 0, capacity),
		capacity: capacity,
		metrics:  metrics,
	}
}

// Add inserts a transaction into the mempool.
// Returns error if mempool is full.
func (mp *Mempool) Add(tx Transaction) error {
	mp.mu.Lock()
	defer mp.mu.Unlock()

	if len(mp.txs) >= mp.capacity {
		mp.metrics.mu.Lock()
		mp.metrics.TxDropped++
		mp.metrics.mu.Unlock()
		return fmt.Errorf("mempool full: capacity %d", mp.capacity)
	}

	tx.Timestamp = time.Now()
	tx.SeqNum = mp.seqGen.Add(1)

	mp.txs = append(mp.txs, tx)

	mp.metrics.mu.Lock()
	mp.metrics.TxInserted++
	if len(mp.txs) > mp.metrics.MempoolHighWatermark {
		mp.metrics.MempoolHighWatermark = len(mp.txs)
	}
	mp.metrics.mu.Unlock()

	return nil
}

// AddBatch inserts multiple transactions atomically.
func (mp *Mempool) AddBatch(txs []Transaction) (int, int) {
	mp.mu.Lock()
	defer mp.mu.Unlock()

	added := 0
	dropped := 0
	now := time.Now()

	for i := range txs {
		if len(mp.txs) >= mp.capacity {
			dropped += len(txs) - i
			break
		}
		txs[i].Timestamp = now
		txs[i].SeqNum = mp.seqGen.Add(1)
		mp.txs = append(mp.txs, txs[i])
		added++
	}

	mp.metrics.mu.Lock()
	mp.metrics.TxInserted += added
	mp.metrics.TxDropped += dropped
	if len(mp.txs) > mp.metrics.MempoolHighWatermark {
		mp.metrics.MempoolHighWatermark = len(mp.txs)
	}
	mp.metrics.mu.Unlock()

	return added, dropped
}

// Drain removes up to maxTx transactions from the front of the mempool,
// respecting the gas limit. Returns transactions in FIFO order.
func (mp *Mempool) Drain(maxTx int, gasLimit uint64, defaultGas uint64) []Transaction {
	mp.mu.Lock()
	defer mp.mu.Unlock()

	if len(mp.txs) == 0 {
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

	// Remove drained transactions from queue
	mp.txs = mp.txs[len(result):]

	return result
}

// Len returns the current mempool size.
func (mp *Mempool) Len() int {
	mp.mu.Lock()
	defer mp.mu.Unlock()
	return len(mp.txs)
}

// Pending returns a snapshot of pending transaction count (lock-free approximation).
func (mp *Mempool) Pending() int {
	mp.mu.Lock()
	defer mp.mu.Unlock()
	return len(mp.txs)
}
