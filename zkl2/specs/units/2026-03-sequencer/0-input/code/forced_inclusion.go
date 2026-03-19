package sequencer

import (
	"sync"
	"time"
)

// ForcedInclusionQueue implements an Arbitrum-style FIFO queue for forced
// transactions submitted via L1. The sequencer must include these transactions
// in FIFO order -- it cannot selectively skip transactions.
//
// Design rationale (from literature review):
// - Arbitrum DelayedInbox: FIFO ordering, 24h deadline, ~50K gas to submit
// - Polygon CDK: forceBatch() with 5-day timeout, mapping-based storage
// - OP Stack: depositTransaction() with 12h sequencing window
//
// We adopt Arbitrum's model because:
// 1. FIFO prevents selective censorship (delaying one = delaying all)
// 2. 24h deadline is reasonable for enterprise context
// 3. Simple queue interface maps cleanly to Go implementation
type ForcedInclusionQueue struct {
	mu       sync.Mutex
	queue    []ForcedTransaction // FIFO queue
	maxDelay time.Duration
	metrics  *Metrics
}

// NewForcedInclusionQueue creates a forced inclusion queue with the given deadline.
func NewForcedInclusionQueue(maxDelay time.Duration, metrics *Metrics) *ForcedInclusionQueue {
	return &ForcedInclusionQueue{
		queue:    make([]ForcedTransaction, 0, 100),
		maxDelay: maxDelay,
		metrics:  metrics,
	}
}

// Submit adds a forced transaction to the queue (simulates L1 submission).
func (fq *ForcedInclusionQueue) Submit(tx Transaction, l1BlockNumber uint64) {
	fq.mu.Lock()
	defer fq.mu.Unlock()

	now := time.Now()
	forced := ForcedTransaction{
		Tx:            tx,
		L1BlockNumber: l1BlockNumber,
		L1Timestamp:   now,
		Deadline:      now.Add(fq.maxDelay),
	}

	fq.queue = append(fq.queue, forced)

	fq.metrics.mu.Lock()
	fq.metrics.ForcedTxSubmitted++
	fq.metrics.mu.Unlock()
}

// DrainDue returns forced transactions that must be included now.
// A forced transaction is "due" if:
// 1. It is at the front of the queue (FIFO -- cannot skip)
// 2. Either: (a) the sequencer voluntarily includes it, or
//            (b) the deadline has passed
//
// For the experiment, we check if deadline has passed OR if the sequencer
// is cooperating (includeAll=true simulates cooperative behavior).
func (fq *ForcedInclusionQueue) DrainDue(now time.Time, includeAll bool) []ForcedTransaction {
	fq.mu.Lock()
	defer fq.mu.Unlock()

	if len(fq.queue) == 0 {
		return nil
	}

	var result []ForcedTransaction

	for len(fq.queue) > 0 {
		front := fq.queue[0]

		if includeAll || now.After(front.Deadline) {
			result = append(result, front)
			fq.queue = fq.queue[1:]

			fq.metrics.mu.Lock()
			fq.metrics.ForcedTxIncluded++
			latency := now.Sub(front.L1Timestamp).Nanoseconds()
			if latency > fq.metrics.MaxForcedLatencyNs {
				fq.metrics.MaxForcedLatencyNs = latency
			}
			fq.metrics.mu.Unlock()
		} else {
			// FIFO: cannot skip to later items
			break
		}
	}

	return result
}

// Len returns the current queue size.
func (fq *ForcedInclusionQueue) Len() int {
	fq.mu.Lock()
	defer fq.mu.Unlock()
	return len(fq.queue)
}

// HasOverdue returns true if any forced transaction has passed its deadline.
func (fq *ForcedInclusionQueue) HasOverdue(now time.Time) bool {
	fq.mu.Lock()
	defer fq.mu.Unlock()

	if len(fq.queue) == 0 {
		return false
	}
	return now.After(fq.queue[0].Deadline)
}
