package sequencer

import (
	"fmt"
	"sync"
	"time"
)

// Sequencer is the single-operator block producer for an enterprise L2.
// It implements the block production loop:
//
//	1. Check forced inclusion queue for due transactions
//	2. Drain mempool for pending transactions (FIFO)
//	3. Assemble block (forced first, then mempool, respecting gas limit)
//	4. Seal block and advance state
//
// Block lifecycle: pending -> sealed -> committed -> proved -> finalized
// (This experiment covers pending -> sealed. Commit/prove/finalize are
// handled by downstream pipeline components.)
type Sequencer struct {
	mu      sync.Mutex
	config  SequencerConfig
	mempool *Mempool
	forced  *ForcedInclusionQueue
	metrics *Metrics

	// State
	blockNumber  uint64
	lastHash     [32]byte
	blocks       []Block
	running      bool
	stopCh       chan struct{}

	// Simulated L1 state
	l1BlockNumber uint64
}

// New creates a new Sequencer with the given configuration.
func New(config SequencerConfig) *Sequencer {
	metrics := &Metrics{}
	return &Sequencer{
		config:  config,
		mempool: NewMempool(config.MempoolCapacity, metrics),
		forced:  NewForcedInclusionQueue(config.ForcedInclusionDelay, metrics),
		metrics: metrics,
		blocks:  make([]Block, 0, 1000),
		stopCh:  make(chan struct{}),
	}
}

// Mempool returns the sequencer's mempool.
func (s *Sequencer) Mempool() *Mempool {
	return s.mempool
}

// ForcedQueue returns the forced inclusion queue.
func (s *Sequencer) ForcedQueue() *ForcedInclusionQueue {
	return s.forced
}

// Metrics returns the sequencer's metrics.
func (s *Sequencer) Metrics() *Metrics {
	return s.metrics
}

// ProduceBlock produces a single L2 block synchronously.
// This is the core function benchmarked in the experiment.
func (s *Sequencer) ProduceBlock() *Block {
	start := time.Now()

	s.mu.Lock()
	defer s.mu.Unlock()

	// Step 1: Drain forced inclusion queue (cooperative mode)
	// Forced transactions get priority -- included at the top of the block
	forcedTxs := s.forced.DrainDue(start, true)

	gasUsed := uint64(0)
	var blockTxs []Transaction

	for _, ftx := range forcedTxs {
		txGas := ftx.Tx.GasLimit
		if txGas == 0 {
			txGas = s.config.DefaultTxGas
		}
		if gasUsed+txGas > s.config.BlockGasLimit {
			break
		}
		blockTxs = append(blockTxs, ftx.Tx)
		gasUsed += txGas
	}

	// Step 2: Fill remaining space from mempool (FIFO order)
	remainingGas := s.config.BlockGasLimit - gasUsed
	remainingSlots := s.config.MaxTxPerBlock - len(blockTxs)
	if remainingSlots > 0 && remainingGas > 0 {
		mempoolTxs := s.mempool.Drain(remainingSlots, remainingGas, s.config.DefaultTxGas)
		blockTxs = append(blockTxs, mempoolTxs...)
		for _, tx := range mempoolTxs {
			g := tx.GasLimit
			if g == 0 {
				g = s.config.DefaultTxGas
			}
			gasUsed += g
		}
	}

	// Step 3: Assemble and seal block
	now := time.Now()
	block := Block{
		Number:       s.blockNumber,
		ParentHash:   s.lastHash,
		Timestamp:    start,
		Transactions: blockTxs,
		GasUsed:      gasUsed,
		GasLimit:     s.config.BlockGasLimit,
		SealedAt:     now,
		ProducedInNs: now.Sub(start).Nanoseconds(),
	}

	s.lastHash = block.BlockHash()
	s.blockNumber++
	s.blocks = append(s.blocks, block)

	// Step 4: Update metrics
	s.metrics.mu.Lock()
	s.metrics.BlocksProduced++
	s.metrics.TotalBlockProductionNs += block.ProducedInNs
	s.metrics.TxIncluded += len(blockTxs)
	if len(blockTxs) == 0 {
		s.metrics.EmptyBlocks++
	}

	// Check FIFO ordering
	for i := 1; i < len(blockTxs); i++ {
		s.metrics.TotalOrderingChecks++
		if blockTxs[i].SeqNum < blockTxs[i-1].SeqNum {
			s.metrics.FIFOViolations++
		}
	}
	s.metrics.mu.Unlock()

	return &block
}

// Run starts the block production loop. Blocks are produced at the configured
// interval until Stop is called.
func (s *Sequencer) Run() {
	s.running = true
	ticker := time.NewTicker(time.Duration(s.config.BlockTimeMs) * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			s.ProduceBlock()
		case <-s.stopCh:
			return
		}
	}
}

// Stop halts the block production loop.
func (s *Sequencer) Stop() {
	s.running = false
	close(s.stopCh)
}

// Blocks returns all produced blocks.
func (s *Sequencer) Blocks() []Block {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make([]Block, len(s.blocks))
	copy(result, s.blocks)
	return result
}

// PrintSummary outputs a formatted summary of sequencer metrics.
func (s *Sequencer) PrintSummary() string {
	m := s.metrics
	m.mu.Lock()
	defer m.mu.Unlock()

	return fmt.Sprintf(`=== Sequencer Benchmark Results ===
Block Production:
  Blocks produced:    %d
  Empty blocks:       %d
  Avg production:     %.3f ms
  Total production:   %.3f ms

Mempool:
  TX inserted:        %d
  TX included:        %d
  TX dropped:         %d
  High watermark:     %d

Forced Inclusion:
  TX submitted:       %d
  TX included:        %d
  TX expired:         %d
  Max latency:        %.3f ms

Ordering:
  FIFO checks:        %d
  FIFO violations:    %d
  FIFO accuracy:      %.2f%%
`,
		m.BlocksProduced,
		m.EmptyBlocks,
		float64(m.TotalBlockProductionNs)/float64(max(m.BlocksProduced, 1))/1e6,
		float64(m.TotalBlockProductionNs)/1e6,
		m.TxInserted,
		m.TxIncluded,
		m.TxDropped,
		m.MempoolHighWatermark,
		m.ForcedTxSubmitted,
		m.ForcedTxIncluded,
		m.ForcedTxExpired,
		float64(m.MaxForcedLatencyNs)/1e6,
		m.TotalOrderingChecks,
		m.FIFOViolations,
		func() float64 {
			if m.TotalOrderingChecks == 0 {
				return 100.0
			}
			return 100.0 * float64(m.TotalOrderingChecks-m.FIFOViolations) / float64(m.TotalOrderingChecks)
		}(),
	)
}
