package sequencer

import (
	"fmt"
	"log/slog"
	"sync"
)

// ForcedInclusionQueue implements an Arbitrum-style FIFO queue for forced
// transactions submitted via L1.
//
// The sequencer must include forced transactions in FIFO order -- it cannot
// selectively skip transactions. A forced transaction submitted at L2 block B
// must be included by block B + ForcedDeadlineBlocks. If the deadline passes,
// the sequencer MUST include the transaction in the next block it produces.
//
// Design rationale (from literature review):
//   - Arbitrum DelayedInbox: FIFO ordering, 24h deadline, ~50K gas to submit
//   - Polygon CDK: forceBatch() with 5-day timeout, mapping-based storage
//   - OP Stack: depositTransaction() with 12h sequencing window
//
// We adopt Arbitrum's model because:
//  1. FIFO prevents selective censorship (delaying one = delaying all)
//  2. Configurable deadline suits enterprise context
//  3. Simple queue interface maps cleanly to implementation
//
// [Spec: forcedQueue variable -- Seq(ForcedTxs), FIFO queue of forced transactions]
// [Spec: SubmitForcedTx(ftx) -- Append(forcedQueue, ftx)]
// [Spec: ForcedInclusionDeadline invariant -- blockNum > submitBlock + deadline => included]
// [Spec: zkl2/specs/units/2026-03-sequencer/1-formalization/v0-analysis/specs/Sequencer/Sequencer.tla]
type ForcedInclusionQueue struct {
	mu             sync.Mutex
	queue          []ForcedTransaction
	deadlineBlocks uint64
	logger         *slog.Logger
}

// NewForcedInclusionQueue creates a forced inclusion queue.
// deadlineBlocks is the number of L2 blocks within which a forced tx must be included.
//
// [Spec: ForcedDeadlineBlocks constant]
func NewForcedInclusionQueue(deadlineBlocks uint64, logger *slog.Logger) *ForcedInclusionQueue {
	if logger == nil {
		logger = slog.Default()
	}
	return &ForcedInclusionQueue{
		queue:          make([]ForcedTransaction, 0, 128),
		deadlineBlocks: deadlineBlocks,
		logger:         logger,
	}
}

// Submit adds a forced transaction to the queue. The currentBlockNum is the
// current L2 block number at submission time, used for deadline enforcement.
//
// [Spec: SubmitForcedTx(ftx) -- Append(forcedQueue, ftx), forcedSubmitBlock @@ (ftx :> blockNum)]
func (fq *ForcedInclusionQueue) Submit(tx Transaction, l1BlockNumber uint64, currentBlockNum uint64) {
	fq.mu.Lock()
	defer fq.mu.Unlock()

	forced := ForcedTransaction{
		Tx:             tx,
		L1BlockNumber:  l1BlockNumber,
		SubmitBlockNum: currentBlockNum,
	}

	fq.queue = append(fq.queue, forced)

	fq.logger.Debug("forced: transaction submitted",
		"tx_hash", fmt.Sprintf("%x", tx.Hash[:8]),
		"l1_block", l1BlockNumber,
		"submit_block", currentBlockNum,
		"deadline_block", currentBlockNum+fq.deadlineBlocks,
		"queue_len", len(fq.queue),
	)
}

// DrainForBlock returns forced transactions that should be included in the block
// at the given blockNum.
//
// The sequencer has two modes:
//   - Cooperative: includes all queued forced txs (up to maxCount)
//   - Non-cooperative: includes only expired forced txs (those past deadline)
//
// In both modes, FIFO ordering is enforced: the sequencer cannot skip queue items.
// Delaying the front of the queue delays ALL subsequent items.
//
// minRequired counts the maximal prefix of consecutive expired forced txs.
// The sequencer MUST include at least minRequired. It MAY include more (cooperative).
//
// [Spec: ProduceBlock -- IsExpired(i), minRequired, numForced >= minRequired]
// [Spec: forcedQueue' = Drop(forcedQueue, numForced)]
func (fq *ForcedInclusionQueue) DrainForBlock(blockNum uint64, maxCount int, cooperative bool) []ForcedTransaction {
	fq.mu.Lock()
	defer fq.mu.Unlock()

	if len(fq.queue) == 0 || maxCount <= 0 {
		return nil
	}

	// Count the maximal prefix of consecutive expired forced txs.
	// [Spec: minRequired == Cardinality({i \in 1..Len(forcedQueue) : \A j \in 1..i : IsExpired(j)})]
	minRequired := 0
	for i := 0; i < len(fq.queue); i++ {
		if blockNum >= fq.queue[i].SubmitBlockNum+fq.deadlineBlocks {
			minRequired = i + 1
		} else {
			break // FIFO: once a non-expired item is found, stop counting
		}
	}

	// Determine how many to drain.
	// [Spec: \E numForced \in 0..Len(forcedQueue) : numForced >= minRequired]
	numToDrain := minRequired
	if cooperative {
		// Cooperative sequencer includes all available (up to maxCount)
		numToDrain = len(fq.queue)
	}
	if numToDrain > maxCount {
		numToDrain = maxCount
	}
	// Always include at least minRequired (deadline enforcement)
	if numToDrain < minRequired {
		numToDrain = minRequired
	}

	if numToDrain == 0 {
		return nil
	}

	// Take from front of queue (FIFO).
	// [Spec: Take(forcedQueue, numForced)]
	result := make([]ForcedTransaction, numToDrain)
	copy(result, fq.queue[:numToDrain])

	// Remove drained items.
	// [Spec: forcedQueue' = Drop(forcedQueue, numForced)]
	fq.queue = fq.queue[numToDrain:]

	fq.logger.Debug("forced: drained for block",
		"block_num", blockNum,
		"min_required", minRequired,
		"drained", numToDrain,
		"remaining", len(fq.queue),
		"cooperative", cooperative,
	)

	return result
}

// Len returns the current queue size.
func (fq *ForcedInclusionQueue) Len() int {
	fq.mu.Lock()
	defer fq.mu.Unlock()
	return len(fq.queue)
}

// HasOverdue returns true if the front of the queue has passed its deadline
// at the given block number.
//
// [Spec: IsExpired(1) -- blockNum >= forcedSubmitBlock[forcedQueue[1]] + ForcedDeadlineBlocks]
func (fq *ForcedInclusionQueue) HasOverdue(blockNum uint64) bool {
	fq.mu.Lock()
	defer fq.mu.Unlock()
	if len(fq.queue) == 0 {
		return false
	}
	return blockNum >= fq.queue[0].SubmitBlockNum+fq.deadlineBlocks
}

// PeekDeadline returns the deadline block number of the front item, or 0 if empty.
func (fq *ForcedInclusionQueue) PeekDeadline() uint64 {
	fq.mu.Lock()
	defer fq.mu.Unlock()
	if len(fq.queue) == 0 {
		return 0
	}
	return fq.queue[0].SubmitBlockNum + fq.deadlineBlocks
}
