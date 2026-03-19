package sequencer

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"
)

// Sequencer is the single-operator block producer for an enterprise L2 chain.
//
// It implements the block production loop:
//  1. Wait for block interval tick
//  2. Delegate to BlockBuilder to assemble the block
//  3. Record the sealed block and advance state
//
// Block lifecycle managed by the sequencer: pending -> sealed.
// Downstream components (batch submitter, prover, finalizer) handle
// sealed -> committed -> proved -> finalized.
//
// [Spec: Init + Next + Fairness -- WF_vars(ProduceBlock)]
// [Spec: zkl2/specs/units/2026-03-sequencer/1-formalization/v0-analysis/specs/Sequencer/Sequencer.tla]
type Sequencer struct {
	mu sync.Mutex

	config  Config
	mempool *Mempool
	forced  *ForcedInclusionQueue
	builder *BlockBuilder
	logger  *slog.Logger

	// State
	// [Spec: blockNum -- current block number]
	blockNumber uint64
	// [Spec: implicit -- hash chain linking blocks]
	lastHash TxHash
	// [Spec: blocks -- Seq(Seq(AllTxIds))]
	blocks []*L2Block

	// Lifecycle
	running bool
	stopCh  chan struct{}
	done    chan struct{}
}

// New creates a new Sequencer with the given configuration.
// Returns an error if the configuration is invalid.
//
// [Spec: Init -- mempool = <<>>, forcedQueue = <<>>, blocks = <<>>, blockNum = 0]
func New(config Config, logger *slog.Logger) (*Sequencer, error) {
	if err := config.Validate(); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrInvalidConfig, err)
	}
	if logger == nil {
		logger = slog.Default()
	}

	mempool := NewMempool(config.MempoolCapacity, logger)
	forced := NewForcedInclusionQueue(config.ForcedDeadlineBlocks, logger)
	builder := NewBlockBuilder(config, mempool, forced, logger)

	return &Sequencer{
		config:  config,
		mempool: mempool,
		forced:  forced,
		builder: builder,
		logger:  logger,
		blocks:  make([]*L2Block, 0, 1024),
		stopCh:  make(chan struct{}),
		done:    make(chan struct{}),
	}, nil
}

// Mempool returns the sequencer's mempool for transaction submission.
func (s *Sequencer) Mempool() *Mempool {
	return s.mempool
}

// ForcedQueue returns the forced inclusion queue.
func (s *Sequencer) ForcedQueue() *ForcedInclusionQueue {
	return s.forced
}

// BlockNumber returns the current block number (number of blocks produced).
func (s *Sequencer) BlockNumber() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.blockNumber
}

// ProduceBlock produces a single L2 block synchronously.
// This is the core function that delegates to BlockBuilder.
//
// [Spec: ProduceBlock action -- blockNum < MaxBlocks, assemble, seal, advance]
func (s *Sequencer) ProduceBlock() *L2Block {
	s.mu.Lock()
	defer s.mu.Unlock()

	block := s.builder.BuildBlock(s.blockNumber, s.lastHash, true)

	s.lastHash = block.BlockHash()
	s.blockNumber++
	s.blocks = append(s.blocks, block)

	return block
}

// SealBlock is an alias for ProduceBlock that makes the lifecycle transition
// explicit: pending -> sealed. The block is returned in BlockSealed state.
func (s *Sequencer) SealBlock() *L2Block {
	return s.ProduceBlock()
}

// StartSequencer starts the block production loop. Blocks are produced at the
// configured interval until the context is cancelled or Stop is called.
//
// This method blocks until the sequencer is stopped. Run it in a goroutine.
//
// [Spec: Fairness == WF_vars(ProduceBlock) -- block production continues when enabled]
func (s *Sequencer) StartSequencer(ctx context.Context) {
	s.mu.Lock()
	if s.running {
		s.mu.Unlock()
		return
	}
	s.running = true
	s.done = make(chan struct{})
	s.mu.Unlock()

	s.logger.Info("sequencer started",
		"block_interval", s.config.BlockInterval,
		"max_tx_per_block", s.config.MaxTxPerBlock,
		"gas_limit", s.config.BlockGasLimit,
		"forced_deadline_blocks", s.config.ForcedDeadlineBlocks,
	)

	ticker := time.NewTicker(s.config.BlockInterval)
	defer ticker.Stop()
	defer close(s.done)

	for {
		select {
		case <-ticker.C:
			block := s.ProduceBlock()
			if !block.IsEmpty() {
				s.logger.Info("block produced",
					"number", block.Number,
					"tx_count", block.TxCount(),
					"gas_used", block.GasUsed,
					"production_ns", block.ProductionNs,
				)
			}
		case <-ctx.Done():
			s.logger.Info("sequencer stopping: context cancelled")
			s.mu.Lock()
			s.running = false
			s.mu.Unlock()
			return
		case <-s.stopCh:
			s.logger.Info("sequencer stopping: stop signal received")
			s.mu.Lock()
			s.running = false
			s.mu.Unlock()
			return
		}
	}
}

// Stop halts the block production loop. Safe to call multiple times.
func (s *Sequencer) Stop() {
	s.mu.Lock()
	if !s.running {
		s.mu.Unlock()
		return
	}
	s.mu.Unlock()

	select {
	case s.stopCh <- struct{}{}:
	default:
	}

	// Wait for the production loop to finish.
	<-s.done
}

// Blocks returns a copy of all produced blocks.
func (s *Sequencer) Blocks() []*L2Block {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make([]*L2Block, len(s.blocks))
	copy(result, s.blocks)
	return result
}

// GetBlock returns the block at the given number, or nil if not found.
func (s *Sequencer) GetBlock(num uint64) *L2Block {
	s.mu.Lock()
	defer s.mu.Unlock()
	if num >= uint64(len(s.blocks)) {
		return nil
	}
	return s.blocks[num]
}

// Stats returns a snapshot of sequencer statistics.
func (s *Sequencer) Stats() SequencerStats {
	s.mu.Lock()
	defer s.mu.Unlock()

	totalTx := 0
	totalGas := uint64(0)
	emptyBlocks := 0
	totalProductionNs := int64(0)

	for _, b := range s.blocks {
		totalTx += b.TxCount()
		totalGas += b.GasUsed
		totalProductionNs += b.ProductionNs
		if b.IsEmpty() {
			emptyBlocks++
		}
	}

	return SequencerStats{
		BlocksProduced:    len(s.blocks),
		TotalTxIncluded:   totalTx,
		TotalGasUsed:      totalGas,
		EmptyBlocks:       emptyBlocks,
		MempoolPending:    s.mempool.Len(),
		ForcedQueueLen:    s.forced.Len(),
		AvgProductionNs:   safeDivInt64(totalProductionNs, int64(len(s.blocks))),
		TotalProductionNs: totalProductionNs,
	}
}

// SequencerStats holds a snapshot of sequencer metrics.
type SequencerStats struct {
	BlocksProduced    int
	TotalTxIncluded   int
	TotalGasUsed      uint64
	EmptyBlocks       int
	MempoolPending    int
	ForcedQueueLen    int
	AvgProductionNs   int64
	TotalProductionNs int64
}

func safeDivInt64(a, b int64) int64 {
	if b == 0 {
		return 0
	}
	return a / b
}
