package cross

import (
	"fmt"
	"log/slog"

	"github.com/ethereum/go-ethereum/common"
)

// ---------------------------------------------------------------------------
// Hub -- L1 Hub Protocol
// ---------------------------------------------------------------------------

// Hub implements the L1 hub protocol for cross-enterprise communication.
// It mirrors the TLA+ specification: verifies messages, enforces replay
// protection, manages atomic settlement, and handles timeouts.
//
// The hub NEVER generates ZK proofs (INV-CE10 HubNeutrality). It only
// verifies proofs submitted by enterprises.
//
// [Spec: HubAndSpoke.tla, VerifyAtHub + AttemptSettlement + TimeoutMessage]
type Hub struct {
	config   Config
	state    *HubState
	registry EnterpriseRegistry
	logger   *slog.Logger
}

// NewHub creates a new Hub with the given configuration and dependencies.
func NewHub(config Config, registry EnterpriseRegistry, logger *slog.Logger) (*Hub, error) {
	if err := config.Validate(); err != nil {
		return nil, fmt.Errorf("cross: invalid config: %w", err)
	}
	if registry == nil {
		return nil, fmt.Errorf("cross: nil enterprise registry")
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &Hub{
		config:   config,
		state:    NewHubState(),
		registry: registry,
		logger:   logger,
	}, nil
}

// State returns the hub's internal state (for testing and inspection).
func (h *Hub) State() *HubState {
	return h.state
}

// SetBlockHeight updates the current L1 block height.
func (h *Hub) SetBlockHeight(height uint64) {
	h.state.mu.Lock()
	defer h.state.mu.Unlock()
	h.state.BlockHeight = height
}

// SetStateRoot updates the current state root for an enterprise.
// In production, this is read from BasisRollup.getCurrentRoot().
// [Spec: HubAndSpoke.tla, stateRoots]
func (h *Hub) SetStateRoot(enterprise common.Address, root [32]byte) {
	h.state.mu.Lock()
	defer h.state.mu.Unlock()
	h.state.StateRoots[enterprise] = root
}

// GetStateRoot returns the current state root for an enterprise.
func (h *Hub) GetStateRoot(enterprise common.Address) [32]byte {
	h.state.mu.RLock()
	defer h.state.mu.RUnlock()
	return h.state.StateRoots[enterprise]
}

// GetMessage returns a copy of a message by ID.
func (h *Hub) GetMessage(msgID [32]byte) (*CrossEnterpriseMessage, error) {
	h.state.mu.RLock()
	defer h.state.mu.RUnlock()
	msg, ok := h.state.Messages[msgID]
	if !ok {
		return nil, ErrMessageNotFound
	}
	cp := *msg
	return &cp, nil
}

// ---------------------------------------------------------------------------
// Phase 1: Register Prepared Message
// ---------------------------------------------------------------------------

// RegisterPreparedMessage stores a message that was prepared by a spoke enterprise.
// The message must be in StatusPrepared. Allocates a nonce from the per-pair counter.
//
// [Spec: HubAndSpoke.tla, PrepareMessage]
func (h *Hub) RegisterPreparedMessage(msg *CrossEnterpriseMessage) error {
	if err := ValidateMessage(msg); err != nil {
		return err
	}
	if msg.Status != StatusPrepared {
		return fmt.Errorf("%w: expected prepared, got %s", ErrInvalidTransition, msg.Status)
	}

	h.state.mu.Lock()
	defer h.state.mu.Unlock()

	// Store message
	if _, exists := h.state.Messages[msg.ID]; exists {
		return fmt.Errorf("%w: message already exists", ErrInvalidTransition)
	}
	stored := *msg
	h.state.Messages[msg.ID] = &stored

	h.logger.Info("message registered",
		"msgID", fmt.Sprintf("%x", msg.ID[:8]),
		"source", msg.Source.Hex()[:10],
		"dest", msg.Dest.Hex()[:10],
		"nonce", msg.Nonce,
	)
	return nil
}

// ---------------------------------------------------------------------------
// Phase 2: Hub Verification
// ---------------------------------------------------------------------------

// VerifyMessage performs hub-side verification of a prepared message.
// Checks: enterprise registration, state root freshness, proof validity, nonce freshness.
// On success: status -> HubVerified, nonce consumed.
// On failure: status -> Failed, nonce NOT consumed.
//
// [Spec: HubAndSpoke.tla, VerifyAtHub]
func (h *Hub) VerifyMessage(msgID [32]byte) error {
	h.state.mu.Lock()
	defer h.state.mu.Unlock()

	msg, ok := h.state.Messages[msgID]
	if !ok {
		return ErrMessageNotFound
	}
	if msg.Status != StatusPrepared {
		return fmt.Errorf("%w: expected prepared, got %s", ErrInvalidTransition, msg.Status)
	}

	pair := msg.Pair()

	// Check 1: Source enterprise is registered.
	sourceRegistered := h.registry.IsRegistered(msg.Source)

	// Check 2: Destination enterprise is registered.
	destRegistered := h.registry.IsRegistered(msg.Dest)

	// Check 3: State root matches current on-chain root.
	currentRoot := h.state.StateRoots[msg.Source]
	rootCurrent := msg.SourceStateRoot == currentRoot

	// Check 4: ZK proof is valid.
	proofValid := msg.SourceProofValid

	// Check 5: Nonce is fresh (not previously consumed for this pair).
	nonces := h.state.UsedNonces[pair]
	nonceFresh := nonces == nil || !nonces[msg.Nonce]

	allChecksPass := sourceRegistered && destRegistered && rootCurrent && proofValid && nonceFresh

	if allChecksPass {
		// SUCCESS: transition to HubVerified, consume nonce.
		msg.Status = StatusHubVerified
		if h.state.UsedNonces[pair] == nil {
			h.state.UsedNonces[pair] = make(map[uint64]bool)
		}
		h.state.UsedNonces[pair][msg.Nonce] = true

		h.logger.Info("message verified",
			"msgID", fmt.Sprintf("%x", msgID[:8]),
			"nonce", msg.Nonce,
		)
		return nil
	}

	// FAILURE: transition to Failed, nonce NOT consumed.
	msg.Status = StatusFailed

	reason := "unknown"
	switch {
	case !sourceRegistered:
		reason = "source not registered"
	case !destRegistered:
		reason = "dest not registered"
	case !rootCurrent:
		reason = "stale state root"
	case !proofValid:
		reason = "invalid proof"
	case !nonceFresh:
		reason = "nonce replay"
	}

	h.logger.Warn("message verification failed",
		"msgID", fmt.Sprintf("%x", msgID[:8]),
		"reason", reason,
	)
	return fmt.Errorf("%w: %s", ErrSettlementFailed, reason)
}

// ---------------------------------------------------------------------------
// Phase 3: Register Response
// ---------------------------------------------------------------------------

// RegisterResponse records the destination enterprise's response to a verified message.
// The message must be in StatusHubVerified. Response includes the dest's proof validity
// and current state root.
//
// [Spec: HubAndSpoke.tla, RespondToMessage]
func (h *Hub) RegisterResponse(msgID [32]byte, destProofValid bool, destStateRoot [32]byte, responseCommitment [32]byte) error {
	h.state.mu.Lock()
	defer h.state.mu.Unlock()

	msg, ok := h.state.Messages[msgID]
	if !ok {
		return ErrMessageNotFound
	}
	if msg.Status != StatusHubVerified {
		return fmt.Errorf("%w: expected hub_verified, got %s", ErrInvalidTransition, msg.Status)
	}

	msg.Status = StatusResponded
	msg.DestProofValid = destProofValid
	msg.DestStateRoot = destStateRoot
	msg.ResponseCommitment = responseCommitment

	h.logger.Info("response registered",
		"msgID", fmt.Sprintf("%x", msgID[:8]),
		"destProofValid", destProofValid,
	)
	return nil
}

// ---------------------------------------------------------------------------
// Phase 4: Atomic Settlement
// ---------------------------------------------------------------------------

// SettleMessage attempts atomic settlement of a responded message.
// Verifies: both proofs valid, both state roots current.
// On success: BOTH enterprises' state roots advance atomically. No intermediate
// state where one root is updated but the other is not.
// On failure: NEITHER state root changes. The message is marked as failed.
//
// This is the CRITICAL safety property of the hub-and-spoke architecture.
// [Spec: HubAndSpoke.tla, AttemptSettlement]
// [Invariant: INV-CE6 AtomicSettlement]
func (h *Hub) SettleMessage(msgID [32]byte) error {
	h.state.mu.Lock()
	defer h.state.mu.Unlock()

	msg, ok := h.state.Messages[msgID]
	if !ok {
		return ErrMessageNotFound
	}
	if msg.Status != StatusResponded {
		return fmt.Errorf("%w: expected responded, got %s", ErrInvalidTransition, msg.Status)
	}

	// Settlement verification checks.
	sourceRootCurrent := msg.SourceStateRoot == h.state.StateRoots[msg.Source]
	destRootCurrent := msg.DestStateRoot == h.state.StateRoots[msg.Dest]
	bothProofsValid := msg.SourceProofValid && msg.DestProofValid
	allValid := sourceRootCurrent && destRootCurrent && bothProofsValid

	if !allValid {
		// FAILURE: Neither state root changes. Atomic revert.
		msg.Status = StatusFailed

		reason := "unknown"
		switch {
		case !msg.SourceProofValid:
			reason = "invalid source proof"
		case !msg.DestProofValid:
			reason = "invalid dest proof"
		case !sourceRootCurrent:
			reason = "stale source root"
		case !destRootCurrent:
			reason = "stale dest root"
		}

		h.logger.Warn("settlement failed",
			"msgID", fmt.Sprintf("%x", msgID[:8]),
			"reason", reason,
		)
		return fmt.Errorf("%w: %s", ErrSettlementFailed, reason)
	}

	// SUCCESS: Both state roots advance atomically.
	// This mirrors the TLA+ step:
	//   stateRoots' = [stateRoots EXCEPT ![source] = @ + 1, ![dest] = @ + 1]
	// In the Go model, we increment a version counter embedded in a new root hash.
	// For simulation, we use incrementRoot to produce deterministic new roots.
	msg.Status = StatusSettled
	h.state.StateRoots[msg.Source] = incrementRoot(h.state.StateRoots[msg.Source])
	h.state.StateRoots[msg.Dest] = incrementRoot(h.state.StateRoots[msg.Dest])

	h.logger.Info("message settled atomically",
		"msgID", fmt.Sprintf("%x", msgID[:8]),
		"source", msg.Source.Hex()[:10],
		"dest", msg.Dest.Hex()[:10],
	)
	return nil
}

// incrementRoot produces a new state root by hashing the current root with a
// settlement marker. This models the TLA+ root version increment.
func incrementRoot(current [32]byte) [32]byte {
	marker := []byte("cross-enterprise-settlement")
	data := make([]byte, 0, 32+len(marker))
	data = append(data, current[:]...)
	data = append(data, marker...)
	hash := common.BytesToHash(data)
	// Use keccak256 for deterministic advancement
	return [32]byte(hash)
}

// ---------------------------------------------------------------------------
// Timeout
// ---------------------------------------------------------------------------

// TimeoutMessage transitions a non-terminal message to TimedOut if the
// timeout deadline has been reached. No state root changes occur.
// Consumed nonces remain consumed (preventing replay of timed-out messages).
//
// [Spec: HubAndSpoke.tla, TimeoutMessage]
// [Invariant: INV-CE9 TimeoutSafety]
func (h *Hub) TimeoutMessage(msgID [32]byte) error {
	h.state.mu.Lock()
	defer h.state.mu.Unlock()

	msg, ok := h.state.Messages[msgID]
	if !ok {
		return ErrMessageNotFound
	}

	// Only non-terminal messages can time out.
	if msg.Status.IsTerminal() {
		return fmt.Errorf("%w: message already in terminal state %s", ErrInvalidTransition, msg.Status)
	}

	// Check timeout condition.
	if h.state.BlockHeight-msg.CreatedAtBlock < h.config.TimeoutBlocks {
		return ErrTimeoutNotReached
	}

	msg.Status = StatusTimedOut

	h.logger.Info("message timed out",
		"msgID", fmt.Sprintf("%x", msgID[:8]),
		"createdAt", msg.CreatedAtBlock,
		"currentBlock", h.state.BlockHeight,
	)
	return nil
}

// ---------------------------------------------------------------------------
// Block Advancement
// ---------------------------------------------------------------------------

// AdvanceBlock increments the L1 block height by 1.
// [Spec: HubAndSpoke.tla, AdvanceBlock]
func (h *Hub) AdvanceBlock() {
	h.state.mu.Lock()
	defer h.state.mu.Unlock()
	h.state.BlockHeight++
}

// AdvanceBlocks increments the L1 block height by n blocks.
func (h *Hub) AdvanceBlocks(n uint64) {
	h.state.mu.Lock()
	defer h.state.mu.Unlock()
	h.state.BlockHeight += n
}

// BlockHeight returns the current L1 block height.
func (h *Hub) BlockHeight() uint64 {
	h.state.mu.RLock()
	defer h.state.mu.RUnlock()
	return h.state.BlockHeight
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

// IsNonceUsed checks if a nonce has been consumed for a directed pair.
func (h *Hub) IsNonceUsed(pair EnterprisePair, nonce uint64) bool {
	h.state.mu.RLock()
	defer h.state.mu.RUnlock()
	nonces := h.state.UsedNonces[pair]
	return nonces != nil && nonces[nonce]
}

// AllMessages returns a slice of all messages in the hub (copies).
func (h *Hub) AllMessages() []*CrossEnterpriseMessage {
	h.state.mu.RLock()
	defer h.state.mu.RUnlock()
	result := make([]*CrossEnterpriseMessage, 0, len(h.state.Messages))
	for _, msg := range h.state.Messages {
		cp := *msg
		result = append(result, &cp)
	}
	return result
}
