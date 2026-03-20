package cross

import (
	"fmt"
	"log/slog"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// ---------------------------------------------------------------------------
// Spoke -- Enterprise-Side Protocol
// ---------------------------------------------------------------------------

// Spoke implements the enterprise-side (L2 spoke) of the cross-enterprise protocol.
// Each enterprise operates its own Spoke instance. The spoke prepares cross-enterprise
// messages (Phase 1) and generates responses (Phase 3).
//
// The spoke holds a reference to the hub for submitting messages and reading state.
// In production, this communicates with the L1 contract via JSON-RPC.
//
// [Spec: HubAndSpoke.tla, PrepareMessage + RespondToMessage]
type Spoke struct {
	enterprise common.Address
	hub        *Hub
	logger     *slog.Logger
}

// NewSpoke creates a new Spoke for the given enterprise, connected to the specified hub.
func NewSpoke(enterprise common.Address, hub *Hub, logger *slog.Logger) (*Spoke, error) {
	if enterprise == (common.Address{}) {
		return nil, ErrZeroAddress
	}
	if hub == nil {
		return nil, fmt.Errorf("cross: nil hub")
	}
	if logger == nil {
		logger = slog.Default()
	}
	return &Spoke{
		enterprise: enterprise,
		hub:        hub,
		logger:     logger,
	}, nil
}

// Enterprise returns this spoke's enterprise address.
func (s *Spoke) Enterprise() common.Address {
	return s.enterprise
}

// ---------------------------------------------------------------------------
// Phase 1: Message Preparation
// ---------------------------------------------------------------------------

// PrepareMessage creates a cross-enterprise message to the destination enterprise.
// The source enterprise computes:
//   - commitment = Poseidon(claimType, enterprise_id, data_hash, nonce)
//   - ZK proof that commitment is consistent with source's current state root
//
// The proof may be valid (true) or invalid (false), modeling both honest and
// adversarial enterprises. This nondeterminism allows testing scenarios where
// a malicious enterprise submits an invalid proof.
//
// Returns the message ID for tracking.
//
// [Spec: HubAndSpoke.tla, PrepareMessage]
func (s *Spoke) PrepareMessage(dest common.Address, commitment [32]byte, proofValid bool) ([32]byte, error) {
	if dest == (common.Address{}) {
		return [32]byte{}, ErrZeroAddress
	}
	if s.enterprise == dest {
		return [32]byte{}, ErrSelfMessage
	}

	pair := EnterprisePair{Source: s.enterprise, Dest: dest}

	// Allocate nonce from per-pair counter.
	s.hub.state.mu.Lock()
	nonce := s.hub.state.MsgCounters[pair] + 1
	s.hub.state.MsgCounters[pair] = nonce
	sourceRoot := s.hub.state.StateRoots[s.enterprise]
	blockHeight := s.hub.state.BlockHeight
	s.hub.state.mu.Unlock()

	msg, err := NewPreparedMessage(
		s.enterprise, dest, nonce, proofValid, sourceRoot, commitment, blockHeight,
	)
	if err != nil {
		return [32]byte{}, fmt.Errorf("cross: prepare message: %w", err)
	}

	if err := s.hub.RegisterPreparedMessage(msg); err != nil {
		return [32]byte{}, fmt.Errorf("cross: register prepared message: %w", err)
	}

	s.logger.Info("message prepared",
		"msgID", fmt.Sprintf("%x", msg.ID[:8]),
		"dest", dest.Hex()[:10],
		"nonce", nonce,
		"proofValid", proofValid,
	)
	return msg.ID, nil
}

// ---------------------------------------------------------------------------
// Phase 3: Response
// ---------------------------------------------------------------------------

// RespondToMessage generates a response to a hub-verified message addressed
// to this enterprise. The destination enterprise computes a symmetric response:
//   - responseCommitment = Poseidon(response_type, dest_id, response_data_hash, nonce)
//   - ZK proof that response is consistent with dest's current state root
//
// The response proof may be valid or invalid (nondeterministic), modeling
// adversarial destination enterprises.
//
// [Spec: HubAndSpoke.tla, RespondToMessage]
func (s *Spoke) RespondToMessage(msgID [32]byte, responseProofValid bool) error {
	// Read current state root for this enterprise.
	s.hub.state.mu.RLock()
	destRoot := s.hub.state.StateRoots[s.enterprise]
	s.hub.state.mu.RUnlock()

	// Compute a deterministic response commitment.
	responseCommitment := computeResponseCommitment(s.enterprise, msgID)

	if err := s.hub.RegisterResponse(msgID, responseProofValid, destRoot, responseCommitment); err != nil {
		return fmt.Errorf("cross: respond to message: %w", err)
	}

	s.logger.Info("response submitted",
		"msgID", fmt.Sprintf("%x", msgID[:8]),
		"proofValid", responseProofValid,
	)
	return nil
}

// computeResponseCommitment generates a deterministic commitment for a response.
// In production, this would be Poseidon(response_type, dest_id, response_data_hash, nonce).
// For the Go model, we use keccak256 as a stand-in.
func computeResponseCommitment(enterprise common.Address, msgID [32]byte) [32]byte {
	data := make([]byte, 0, 52)
	data = append(data, enterprise.Bytes()...)
	data = append(data, msgID[:]...)
	return crypto.Keccak256Hash(data)
}
