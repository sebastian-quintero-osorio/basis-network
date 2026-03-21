// Package sync implements the L1 synchronizer for the Basis L2 node.
//
// The synchronizer polls the Basis Network L1 (Avalanche Subnet-EVM) for
// events emitted by the deployed settlement contracts. It detects:
//
//   - Forced inclusion transactions (from BasisRollup)
//   - Bridge deposit events (from BasisBridge)
//   - DAC attestation events (from BasisDAC)
//   - Enterprise registration changes (from EnterpriseRegistry)
//
// Events are forwarded to the appropriate node components (sequencer for
// forced inclusion, bridge relayer for deposits, etc.).
//
// [Spec: POST_ROADMAP_TODO Section 2.5]
package sync

import (
	"context"
	"fmt"
	"log/slog"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// Config holds the L1 synchronizer configuration.
type Config struct {
	// L1RPCURL is the JSON-RPC endpoint for the Basis Network L1.
	L1RPCURL string

	// PollInterval is the interval between L1 block scans.
	PollInterval time.Duration

	// Contracts holds the deployed L1 contract addresses.
	Contracts ContractAddresses

	// StartBlock is the L1 block number to start scanning from.
	// Use 0 to scan from the latest block.
	StartBlock uint64
}

// ContractAddresses holds the deployed L1 contract addresses to monitor.
type ContractAddresses struct {
	BasisRollup        common.Address
	BasisBridge        common.Address
	BasisDAC           common.Address
	EnterpriseRegistry common.Address
}

// DefaultConfig returns a synchronizer config with safe defaults.
func DefaultConfig() Config {
	return Config{
		L1RPCURL:     "https://rpc.basisnetwork.com.co",
		PollInterval: 5 * time.Second,
		StartBlock:   0,
	}
}

// L1Event represents a parsed event from an L1 contract.
type L1Event struct {
	// Type identifies the event category.
	Type EventType

	// BlockNumber is the L1 block containing this event.
	BlockNumber uint64

	// TxHash is the L1 transaction hash that emitted this event.
	TxHash common.Hash

	// Contract is the L1 contract that emitted the event.
	Contract common.Address

	// Data holds event-specific parsed data.
	Data interface{}
}

// EventType classifies L1 events.
type EventType int

const (
	// EventForcedInclusion is a forced transaction submitted to BasisRollup.
	EventForcedInclusion EventType = iota

	// EventDeposit is a deposit (L1 -> L2) on BasisBridge.
	EventDeposit

	// EventDACAttestation is a DAC attestation on BasisDAC.
	EventDACAttestation

	// EventEnterpriseRegistered is a new enterprise registration.
	EventEnterpriseRegistered
)

// String returns the human-readable name of an event type.
func (e EventType) String() string {
	switch e {
	case EventForcedInclusion:
		return "ForcedInclusion"
	case EventDeposit:
		return "Deposit"
	case EventDACAttestation:
		return "DACAttestation"
	case EventEnterpriseRegistered:
		return "EnterpriseRegistered"
	default:
		return fmt.Sprintf("Unknown(%d)", int(e))
	}
}

// ForcedInclusionData holds the parsed data from a forced inclusion event.
type ForcedInclusionData struct {
	Enterprise common.Address
	TxData     []byte
	Deadline   uint64
}

// DepositData holds the parsed data from a deposit event.
type DepositData struct {
	From   common.Address
	To     common.Address
	Amount *big.Int
	Nonce  uint64
}

// EventHandler processes L1 events. Implementations are provided by the
// components that need to react to L1 state changes.
type EventHandler func(event L1Event)

// Synchronizer polls L1 for contract events and dispatches them to handlers.
type Synchronizer struct {
	config       Config
	logger       *slog.Logger
	handlers     map[EventType][]EventHandler
	lastBlock    uint64
	stopCh       chan struct{}

	// Event topic signatures (Keccak256 of event signatures).
	topicForcedInclusion    common.Hash
	topicDeposit            common.Hash
	topicDACAttestation     common.Hash
	topicEnterpriseRegister common.Hash
}

// New creates a new L1 synchronizer.
func New(config Config, logger *slog.Logger) *Synchronizer {
	if logger == nil {
		logger = slog.Default()
	}
	return &Synchronizer{
		config:    config,
		logger:    logger,
		handlers:  make(map[EventType][]EventHandler),
		lastBlock: config.StartBlock,
		stopCh:    make(chan struct{}),

		// Precompute event topic hashes.
		topicForcedInclusion:    crypto.Keccak256Hash([]byte("ForcedInclusion(address,bytes,uint256)")),
		topicDeposit:            crypto.Keccak256Hash([]byte("Deposit(address,address,uint256,uint256)")),
		topicDACAttestation:     crypto.Keccak256Hash([]byte("AttestationSubmitted(uint256,address,bytes32)")),
		topicEnterpriseRegister: crypto.Keccak256Hash([]byte("EnterpriseRegistered(address,string,bytes)")),
	}
}

// OnEvent registers a handler for a specific event type.
// Multiple handlers can be registered for the same event type.
func (s *Synchronizer) OnEvent(eventType EventType, handler EventHandler) {
	s.handlers[eventType] = append(s.handlers[eventType], handler)
}

// Start begins the L1 polling loop. Call Stop to terminate.
func (s *Synchronizer) Start(ctx context.Context) error {
	s.logger.Info("L1 synchronizer started",
		"rpc", s.config.L1RPCURL,
		"poll_interval", s.config.PollInterval,
		"start_block", s.lastBlock,
		"rollup", s.config.Contracts.BasisRollup.Hex(),
		"bridge", s.config.Contracts.BasisBridge.Hex(),
	)

	go s.pollLoop(ctx)
	return nil
}

// Stop terminates the polling loop.
func (s *Synchronizer) Stop() {
	close(s.stopCh)
	s.logger.Info("L1 synchronizer stopped", "last_block", s.lastBlock)
}

// LastBlock returns the last L1 block that was scanned.
func (s *Synchronizer) LastBlock() uint64 {
	return s.lastBlock
}

// pollLoop runs the periodic L1 block scanning.
func (s *Synchronizer) pollLoop(ctx context.Context) {
	ticker := time.NewTicker(s.config.PollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-s.stopCh:
			return
		case <-ticker.C:
			if err := s.scanNewBlocks(ctx); err != nil {
				s.logger.Error("L1 scan failed", "error", err, "last_block", s.lastBlock)
			}
		}
	}
}

// scanNewBlocks queries L1 for new blocks since lastBlock and processes events.
//
// In production, this would use eth_getLogs with a block range and topic filters
// to efficiently retrieve events from the monitored contracts. The current
// implementation increments the block counter and logs the scan attempt.
//
// Full implementation requires:
//   - ethclient.Dial to connect to L1
//   - ethereum.FilterQuery with contract addresses and topics
//   - Log parsing for each event type
//   - Dispatching parsed events to registered handlers
func (s *Synchronizer) scanNewBlocks(ctx context.Context) error {
	// Increment scan position.
	// In production, query eth_blockNumber to get the latest L1 block,
	// then eth_getLogs for the range [lastBlock+1, latestBlock].
	s.lastBlock++

	s.logger.Debug("scanned L1 block",
		"block", s.lastBlock,
		"handlers", len(s.handlers),
	)

	return nil
}

// dispatchEvent sends an event to all registered handlers for its type.
func (s *Synchronizer) dispatchEvent(event L1Event) {
	handlers, ok := s.handlers[event.Type]
	if !ok {
		return
	}

	s.logger.Info("dispatching L1 event",
		"type", event.Type.String(),
		"block", event.BlockNumber,
		"tx", event.TxHash.Hex()[:10],
	)

	for _, handler := range handlers {
		handler(event)
	}
}
