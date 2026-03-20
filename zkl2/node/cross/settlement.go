package cross

import (
	"fmt"
	"log/slog"

	"github.com/ethereum/go-ethereum/common"
)

// ---------------------------------------------------------------------------
// Settlement Coordinator
// ---------------------------------------------------------------------------

// SettlementCoordinator orchestrates end-to-end cross-enterprise transactions.
// It drives the 4-phase protocol:
//
//	Phase 1: Source spoke prepares message
//	Phase 2: Hub verifies message
//	Phase 3: Destination spoke responds
//	Phase 4: Hub settles atomically
//
// The coordinator is a convenience layer -- each phase can also be invoked
// independently through Hub and Spoke methods.
//
// [Spec: HubAndSpoke.tla, full protocol lifecycle]
type SettlementCoordinator struct {
	hub    *Hub
	spokes map[common.Address]*Spoke
	logger *slog.Logger
}

// NewSettlementCoordinator creates a coordinator with the given hub and spoke set.
func NewSettlementCoordinator(hub *Hub, spokes map[common.Address]*Spoke, logger *slog.Logger) (*SettlementCoordinator, error) {
	if hub == nil {
		return nil, fmt.Errorf("cross: nil hub")
	}
	if len(spokes) < 2 {
		return nil, fmt.Errorf("cross: need at least 2 spokes for cross-enterprise communication")
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &SettlementCoordinator{
		hub:    hub,
		spokes: spokes,
		logger: logger,
	}, nil
}

// SettlementResult captures the outcome of an end-to-end cross-enterprise transaction.
type SettlementResult struct {
	// MessageID is the unique identifier for this cross-enterprise message.
	MessageID [32]byte

	// FinalStatus is the terminal status of the message.
	FinalStatus MessageStatus

	// SourceRootBefore is the source enterprise's root before settlement.
	SourceRootBefore [32]byte

	// SourceRootAfter is the source enterprise's root after settlement.
	SourceRootAfter [32]byte

	// DestRootBefore is the destination enterprise's root before settlement.
	DestRootBefore [32]byte

	// DestRootAfter is the destination enterprise's root after settlement.
	DestRootAfter [32]byte

	// Error is non-nil if the settlement failed at any phase.
	Error error

	// FailedPhase indicates which phase failed (0 if success).
	FailedPhase int
}

// ExecuteCrossEnterpriseTx drives the full 4-phase cross-enterprise transaction.
// Both source and destination proofs are valid (honest enterprise scenario).
//
// Returns a SettlementResult describing the outcome, including root changes.
func (sc *SettlementCoordinator) ExecuteCrossEnterpriseTx(
	source, dest common.Address,
	commitment [32]byte,
) (*SettlementResult, error) {
	return sc.ExecuteCrossEnterpriseTxWithProofs(source, dest, commitment, true, true)
}

// ExecuteCrossEnterpriseTxWithProofs drives the full 4-phase protocol with explicit
// proof validity for both source and destination. This allows testing adversarial
// scenarios where one or both proofs are invalid.
func (sc *SettlementCoordinator) ExecuteCrossEnterpriseTxWithProofs(
	source, dest common.Address,
	commitment [32]byte,
	sourceProofValid bool,
	destProofValid bool,
) (*SettlementResult, error) {
	result := &SettlementResult{}

	// Validate enterprises have spokes.
	sourceSpoke, ok := sc.spokes[source]
	if !ok {
		return nil, fmt.Errorf("cross: no spoke for source enterprise %s", source.Hex())
	}
	destSpoke, ok := sc.spokes[dest]
	if !ok {
		return nil, fmt.Errorf("cross: no spoke for dest enterprise %s", dest.Hex())
	}

	// Record pre-settlement roots.
	result.SourceRootBefore = sc.hub.GetStateRoot(source)
	result.DestRootBefore = sc.hub.GetStateRoot(dest)

	// Phase 1: Source prepares message.
	msgID, err := sourceSpoke.PrepareMessage(dest, commitment, sourceProofValid)
	if err != nil {
		result.Error = err
		result.FailedPhase = 1
		result.FinalStatus = StatusFailed
		return result, nil
	}
	result.MessageID = msgID

	// Phase 2: Hub verifies.
	if err := sc.hub.VerifyMessage(msgID); err != nil {
		result.Error = err
		result.FailedPhase = 2
		result.FinalStatus = StatusFailed
		result.SourceRootAfter = sc.hub.GetStateRoot(source)
		result.DestRootAfter = sc.hub.GetStateRoot(dest)
		return result, nil
	}

	// Phase 3: Destination responds.
	if err := destSpoke.RespondToMessage(msgID, destProofValid); err != nil {
		result.Error = err
		result.FailedPhase = 3
		result.FinalStatus = StatusFailed
		result.SourceRootAfter = sc.hub.GetStateRoot(source)
		result.DestRootAfter = sc.hub.GetStateRoot(dest)
		return result, nil
	}

	// Phase 4: Hub settles atomically.
	if err := sc.hub.SettleMessage(msgID); err != nil {
		result.Error = err
		result.FailedPhase = 4
		result.FinalStatus = StatusFailed
		result.SourceRootAfter = sc.hub.GetStateRoot(source)
		result.DestRootAfter = sc.hub.GetStateRoot(dest)
		return result, nil
	}

	// Success.
	result.FinalStatus = StatusSettled
	result.SourceRootAfter = sc.hub.GetStateRoot(source)
	result.DestRootAfter = sc.hub.GetStateRoot(dest)

	sc.logger.Info("cross-enterprise tx settled",
		"msgID", fmt.Sprintf("%x", msgID[:8]),
		"source", source.Hex()[:10],
		"dest", dest.Hex()[:10],
	)
	return result, nil
}
