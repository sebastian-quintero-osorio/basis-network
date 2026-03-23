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

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
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
// Connects to L1 via ethclient, queries eth_blockNumber for the latest block,
// then uses eth_getLogs with topic filters to retrieve events from monitored
// contracts in the range [lastBlock+1, latestBlock].
func (s *Synchronizer) scanNewBlocks(ctx context.Context) error {
	// Connect to L1
	client, err := ethclient.DialContext(ctx, s.config.L1RPCURL)
	if err != nil {
		return fmt.Errorf("L1 dial: %w", err)
	}
	defer client.Close()

	// Get latest L1 block number
	latestBlock, err := client.BlockNumber(ctx)
	if err != nil {
		return fmt.Errorf("eth_blockNumber: %w", err)
	}

	// No new blocks since last scan
	if latestBlock <= s.lastBlock {
		return nil
	}

	fromBlock := s.lastBlock + 1
	toBlock := latestBlock

	// Cap scan range to prevent oversized queries
	const maxBlockRange = 1000
	if toBlock-fromBlock > maxBlockRange {
		toBlock = fromBlock + maxBlockRange
	}

	// Build filter query for all monitored contract addresses and topics
	addresses := []common.Address{}
	if s.config.Contracts.BasisRollup != (common.Address{}) {
		addresses = append(addresses, s.config.Contracts.BasisRollup)
	}
	if s.config.Contracts.BasisBridge != (common.Address{}) {
		addresses = append(addresses, s.config.Contracts.BasisBridge)
	}
	if s.config.Contracts.BasisDAC != (common.Address{}) {
		addresses = append(addresses, s.config.Contracts.BasisDAC)
	}
	if s.config.Contracts.EnterpriseRegistry != (common.Address{}) {
		addresses = append(addresses, s.config.Contracts.EnterpriseRegistry)
	}

	if len(addresses) == 0 {
		s.lastBlock = toBlock
		return nil
	}

	query := ethereum.FilterQuery{
		FromBlock: new(big.Int).SetUint64(fromBlock),
		ToBlock:   new(big.Int).SetUint64(toBlock),
		Addresses: addresses,
		Topics: [][]common.Hash{{
			s.topicForcedInclusion,
			s.topicDeposit,
			s.topicDACAttestation,
			s.topicEnterpriseRegister,
		}},
	}

	logs, err := client.FilterLogs(ctx, query)
	if err != nil {
		return fmt.Errorf("eth_getLogs [%d, %d]: %w", fromBlock, toBlock, err)
	}

	s.logger.Debug("scanned L1 blocks",
		"from", fromBlock,
		"to", toBlock,
		"logs", len(logs),
	)

	// Parse and dispatch each log
	for _, log := range logs {
		if len(log.Topics) == 0 {
			continue
		}

		topic := log.Topics[0]

		switch topic {
		case s.topicForcedInclusion:
			event := L1Event{
				Type:        EventForcedInclusion,
				BlockNumber: log.BlockNumber,
				TxHash:      log.TxHash,
				Contract:    log.Address,
			}
			// Parse forced inclusion data from log
			if len(log.Topics) >= 2 {
				event.Data = ForcedInclusionData{
					Enterprise: common.BytesToAddress(log.Topics[1].Bytes()),
					TxData:     log.Data,
				}
			}
			s.dispatchEvent(event)

		case s.topicDeposit:
			event := L1Event{
				Type:        EventDeposit,
				BlockNumber: log.BlockNumber,
				TxHash:      log.TxHash,
				Contract:    log.Address,
			}
			// Parse deposit data from indexed topics
			if len(log.Topics) >= 3 && len(log.Data) >= 64 {
				amount := new(big.Int).SetBytes(log.Data[:32])
				nonce := new(big.Int).SetBytes(log.Data[32:64]).Uint64()
				event.Data = DepositData{
					From:   common.BytesToAddress(log.Topics[1].Bytes()),
					To:     common.BytesToAddress(log.Topics[2].Bytes()),
					Amount: amount,
					Nonce:  nonce,
				}
			}
			s.dispatchEvent(event)

		case s.topicDACAttestation:
			event := L1Event{
				Type:        EventDACAttestation,
				BlockNumber: log.BlockNumber,
				TxHash:      log.TxHash,
				Contract:    log.Address,
			}
			s.dispatchEvent(event)

		case s.topicEnterpriseRegister:
			event := L1Event{
				Type:        EventEnterpriseRegistered,
				BlockNumber: log.BlockNumber,
				TxHash:      log.TxHash,
				Contract:    log.Address,
			}
			s.dispatchEvent(event)
		}
	}

	s.lastBlock = toBlock
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
