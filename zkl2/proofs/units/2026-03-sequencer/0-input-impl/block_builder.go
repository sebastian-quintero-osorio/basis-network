package sequencer

import (
	"fmt"
	"log/slog"
	"time"
)

// BlockBuilder assembles L2 blocks from the mempool and forced inclusion queue.
//
// Block assembly follows the protocol specified in the TLA+ ProduceBlock action:
//  1. Drain forced transactions from front of queue (FIFO, must include expired)
//  2. Fill remaining capacity from mempool (FIFO)
//  3. Seal block: compute hash, set metadata
//
// Invariant enforcement:
//   - ForcedBeforeMempool: forced txs are concatenated before mempool txs
//   - FIFOWithinBlock: both queues are FIFO, Take-from-front preserves order
//   - NoDoubleInclusion: drained txs are removed from source queues
//   - IncludedWereSubmitted: only txs from known queues enter the block
//   - ForcedInclusionDeadline: minRequired forces inclusion of expired forced txs
//
// [Spec: ProduceBlock action in Sequencer.tla]
// [Spec: zkl2/specs/units/2026-03-sequencer/1-formalization/v0-analysis/specs/Sequencer/Sequencer.tla]
type BlockBuilder struct {
	config      Config
	mempool     *Mempool
	forcedQueue *ForcedInclusionQueue
	logger      *slog.Logger
}

// NewBlockBuilder creates a BlockBuilder wired to the given mempool and forced queue.
func NewBlockBuilder(config Config, mempool *Mempool, forcedQueue *ForcedInclusionQueue, logger *slog.Logger) *BlockBuilder {
	if logger == nil {
		logger = slog.Default()
	}
	return &BlockBuilder{
		config:      config,
		mempool:     mempool,
		forcedQueue: forcedQueue,
		logger:      logger,
	}
}

// BuildBlock assembles a block at the given block number with the given parent hash.
// The cooperative flag controls whether the sequencer voluntarily includes non-expired
// forced transactions (cooperative=true) or only includes expired ones (cooperative=false).
//
// Returns the assembled block in BlockSealed state.
//
// [Spec: ProduceBlock -- forcedPart \o mempoolPart, forced-first ordering]
func (bb *BlockBuilder) BuildBlock(blockNum uint64, parentHash TxHash, cooperative bool) *L2Block {
	start := time.Now()

	// Step 1: Drain forced inclusion queue.
	// Forced transactions get absolute priority -- included at the top of the block.
	// [Spec: forcedPart == Take(forcedQueue, numForced)]
	forcedTxs := bb.forcedQueue.DrainForBlock(blockNum, bb.config.MaxTxPerBlock, cooperative)

	gasUsed := uint64(0)
	blockTxs := make([]Transaction, 0, bb.config.MaxTxPerBlock)

	for i := range forcedTxs {
		txGas := forcedTxs[i].Tx.GasLimit
		if txGas == 0 {
			txGas = bb.config.DefaultTxGas
		}
		if gasUsed+txGas > bb.config.BlockGasLimit {
			break
		}
		blockTxs = append(blockTxs, forcedTxs[i].Tx)
		gasUsed += txGas
	}

	// Step 2: Fill remaining space from mempool (FIFO order).
	// [Spec: mempoolPart == Take(mempool, mempoolCount)]
	// [Spec: remainCap == MaxTxPerBlock - numForced]
	remainingGas := bb.config.BlockGasLimit - gasUsed
	remainingSlots := bb.config.MaxTxPerBlock - len(blockTxs)
	if remainingSlots > 0 && remainingGas > 0 {
		mempoolTxs := bb.mempool.Drain(remainingSlots, remainingGas, bb.config.DefaultTxGas)
		blockTxs = append(blockTxs, mempoolTxs...)
		for i := range mempoolTxs {
			g := mempoolTxs[i].GasLimit
			if g == 0 {
				g = bb.config.DefaultTxGas
			}
			gasUsed += g
		}
	}

	// Step 3: Assemble and seal block.
	// [Spec: blocks' = Append(blocks, blockContent), blockNum' = blockNum + 1]
	now := time.Now()
	block := &L2Block{
		Number:       blockNum,
		ParentHash:   parentHash,
		Timestamp:    start,
		Transactions: blockTxs,
		GasUsed:      gasUsed,
		GasLimit:     bb.config.BlockGasLimit,
		State:        BlockSealed,
		SealedAt:     now,
		ProductionNs: now.Sub(start).Nanoseconds(),
	}

	bb.logger.Info("block built",
		"block_num", blockNum,
		"tx_count", len(blockTxs),
		"forced_count", len(forcedTxs),
		"gas_used", gasUsed,
		"production_ns", block.ProductionNs,
		"empty", block.IsEmpty(),
	)

	return block
}

// ValidateBlockInvariants checks that a produced block satisfies the TLA+ safety invariants.
// This is intended for testing and diagnostic use, not for the hot path.
//
// Returns nil if all invariants hold, or an error describing the first violation.
func ValidateBlockInvariants(block *L2Block, forcedHashes map[TxHash]struct{}, mempoolHashes map[TxHash]struct{}) error {
	// ForcedBeforeMempool: no regular tx precedes a forced tx.
	// [Spec: ~ \E i, j \in 1..Len(block) : i < j /\ block[i] \in Txs /\ block[j] \in ForcedTxs]
	lastForcedIdx := -1
	firstMempoolIdx := -1
	for i := range block.Transactions {
		_, isForced := forcedHashes[block.Transactions[i].Hash]
		if isForced {
			lastForcedIdx = i
		} else if firstMempoolIdx == -1 {
			firstMempoolIdx = i
		}
	}
	if lastForcedIdx >= 0 && firstMempoolIdx >= 0 && firstMempoolIdx < lastForcedIdx {
		return fmt.Errorf("ForcedBeforeMempool violated: mempool tx at index %d precedes forced tx at index %d",
			firstMempoolIdx, lastForcedIdx)
	}

	// FIFOWithinBlock: within each category, SeqNum is strictly increasing.
	// [Spec: submitOrder[block[i]] < submitOrder[block[j]] for i < j within same category]
	var lastForcedSeq, lastMempoolSeq uint64
	for i := range block.Transactions {
		_, isForced := forcedHashes[block.Transactions[i].Hash]
		seq := block.Transactions[i].SeqNum
		if isForced {
			if seq != 0 && lastForcedSeq != 0 && seq <= lastForcedSeq {
				return fmt.Errorf("FIFOWithinBlock violated (forced): seq %d <= %d at index %d", seq, lastForcedSeq, i)
			}
			lastForcedSeq = seq
		} else {
			if seq != 0 && lastMempoolSeq != 0 && seq <= lastMempoolSeq {
				return fmt.Errorf("FIFOWithinBlock violated (mempool): seq %d <= %d at index %d", seq, lastMempoolSeq, i)
			}
			lastMempoolSeq = seq
		}
	}

	// IncludedWereSubmitted: every tx must come from either forced or mempool.
	// [Spec: included \subseteq (submitted \union forcedSubmitted)]
	for i := range block.Transactions {
		h := block.Transactions[i].Hash
		_, inForced := forcedHashes[h]
		_, inMempool := mempoolHashes[h]
		if !inForced && !inMempool {
			return fmt.Errorf("IncludedWereSubmitted violated: tx %x not in any source", h[:8])
		}
	}

	return nil
}
