// Package cross implements the hub-and-spoke cross-enterprise communication protocol
// for Basis Network L2. The hub (L1 smart contract) routes messages between enterprise
// spokes (L2 chains), verifies ZK proofs, enforces replay protection, and settles
// cross-enterprise transactions atomically.
//
// [Spec: zkl2/specs/units/2026-03-hub-and-spoke/HubAndSpoke.tla]
package cross

import (
	"errors"
	"fmt"
	"sync"

	"github.com/ethereum/go-ethereum/common"
)

// ---------------------------------------------------------------------------
// Message Status (TLA+ MsgStatuses)
// ---------------------------------------------------------------------------

// MessageStatus represents the lifecycle state of a cross-enterprise message.
// [Spec: HubAndSpoke.tla, MsgStatuses]
//
// Lifecycle:
//
//	prepared -> hub_verified -> responded -> settled
//	                                     \-> failed
//	                        \-> failed
//	         \-> failed
//	prepared/hub_verified/responded -> timed_out
type MessageStatus uint8

const (
	// StatusPrepared indicates Phase 1 complete: source has commitment + ZK proof.
	StatusPrepared MessageStatus = iota + 1
	// StatusHubVerified indicates Phase 2 complete: hub verified registration, root, proof, nonce.
	StatusHubVerified
	// StatusResponded indicates Phase 3 complete: destination has response proof.
	StatusResponded
	// StatusSettled indicates Phase 4 complete: atomic settlement (both roots updated).
	StatusSettled
	// StatusTimedOut indicates timeout expired: transaction rolled back (no root changes).
	StatusTimedOut
	// StatusFailed indicates verification failed: invalid proof, stale root, or duplicate nonce.
	StatusFailed
)

// terminalStatuses is the set of statuses from which no further transitions are possible.
// [Spec: HubAndSpoke.tla, TerminalStatuses]
var terminalStatuses = map[MessageStatus]bool{
	StatusSettled:  true,
	StatusTimedOut: true,
	StatusFailed:   true,
}

// IsTerminal reports whether the status is a terminal state.
func (s MessageStatus) IsTerminal() bool {
	return terminalStatuses[s]
}

// String returns the human-readable name of the message status.
func (s MessageStatus) String() string {
	switch s {
	case StatusPrepared:
		return "prepared"
	case StatusHubVerified:
		return "hub_verified"
	case StatusResponded:
		return "responded"
	case StatusSettled:
		return "settled"
	case StatusTimedOut:
		return "timed_out"
	case StatusFailed:
		return "failed"
	default:
		return fmt.Sprintf("unknown(%d)", s)
	}
}

// ---------------------------------------------------------------------------
// Enterprise Pair (TLA+ DirectedPairs)
// ---------------------------------------------------------------------------

// EnterprisePair represents a directed enterprise pair (source -> destination).
// Self-pairs (source == dest) are excluded by construction.
// [Spec: HubAndSpoke.tla, DirectedPairs]
type EnterprisePair struct {
	Source common.Address
	Dest   common.Address
}

// Validate checks that the pair is well-formed (source != dest, neither zero).
func (p EnterprisePair) Validate() error {
	if p.Source == (common.Address{}) {
		return ErrZeroAddress
	}
	if p.Dest == (common.Address{}) {
		return ErrZeroAddress
	}
	if p.Source == p.Dest {
		return ErrSelfMessage
	}
	return nil
}

// ---------------------------------------------------------------------------
// Cross-Enterprise Message (TLA+ message domain)
// ---------------------------------------------------------------------------

// CrossEnterpriseMessage represents a cross-enterprise message record.
// [Spec: HubAndSpoke.tla, message domain definition]
//
// CRITICAL (Isolation -- INV-CE5): Messages carry proof validity (boolean) and
// state root references, NEVER raw private enterprise data. This structurally
// encodes the privacy guarantee from ZK proofs: Poseidon(data) reveals nothing
// about data (128-bit preimage resistance), and a valid ZK proof reveals nothing
// about the witness (zero-knowledge property of PLONK/Groth16).
type CrossEnterpriseMessage struct {
	// ID is the deterministic message identifier: keccak256(source, dest, nonce).
	ID [32]byte

	// Source is the originating enterprise address (public, registered on L1).
	Source common.Address

	// Dest is the destination enterprise address (public, registered on L1).
	Dest common.Address

	// Nonce is the per-directed-pair replay protection nonce (1-indexed).
	// [Spec: HubAndSpoke.tla, msg.nonce]
	Nonce uint64

	// SourceProofValid indicates whether the source's ZK proof is cryptographically valid.
	// This is the ONLY information about the source's private state that crosses boundaries.
	// [Spec: HubAndSpoke.tla, msg.sourceProofValid]
	SourceProofValid bool

	// DestProofValid indicates whether the destination's response proof is valid.
	// [Spec: HubAndSpoke.tla, msg.destProofValid]
	DestProofValid bool

	// SourceStateRoot is the source enterprise's L1 state root at preparation time.
	// [Spec: HubAndSpoke.tla, msg.sourceRootVersion]
	SourceStateRoot [32]byte

	// DestStateRoot is the destination enterprise's L1 state root at response time.
	// Zero if no response has been submitted yet.
	// [Spec: HubAndSpoke.tla, msg.destRootVersion]
	DestStateRoot [32]byte

	// Status is the current lifecycle state of the message.
	// [Spec: HubAndSpoke.tla, msg.status]
	Status MessageStatus

	// CreatedAtBlock is the L1 block height when the message was prepared.
	// [Spec: HubAndSpoke.tla, msg.createdAt]
	CreatedAtBlock uint64

	// Commitment is the Poseidon commitment from the source enterprise.
	// Opaque to the hub -- reveals nothing about private data.
	Commitment [32]byte

	// ResponseCommitment is the Poseidon commitment from the destination enterprise.
	// Zero if no response has been submitted yet.
	ResponseCommitment [32]byte
}

// Pair returns the directed enterprise pair for this message.
func (m *CrossEnterpriseMessage) Pair() EnterprisePair {
	return EnterprisePair{Source: m.Source, Dest: m.Dest}
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// Config holds cross-enterprise protocol configuration.
type Config struct {
	// TimeoutBlocks is the number of L1 blocks before a pending message times out.
	// After this many blocks, either party can unilaterally trigger a timeout.
	// [Spec: HubAndSpoke.tla, TimeoutBlocks]
	TimeoutBlocks uint64
}

// DefaultConfig returns the default cross-enterprise protocol configuration.
// TimeoutBlocks = 450 (~15 minutes at ~2s/block on Avalanche).
func DefaultConfig() Config {
	return Config{
		TimeoutBlocks: 450,
	}
}

// Validate checks that the configuration is well-formed.
func (c Config) Validate() error {
	if c.TimeoutBlocks == 0 {
		return errors.New("cross: TimeoutBlocks must be > 0")
	}
	return nil
}

// ---------------------------------------------------------------------------
// State Root Provider (interface to BasisRollup)
// ---------------------------------------------------------------------------

// StateRootProvider reads the current on-chain state root for an enterprise.
// In production, this reads from BasisRollup.getCurrentRoot(). In tests, it
// can be replaced with a mock.
type StateRootProvider interface {
	GetCurrentRoot(enterprise common.Address) ([32]byte, error)
}

// EnterpriseRegistry checks whether an enterprise is registered on L1.
// In production, this reads from IEnterpriseRegistry.isAuthorized(). In tests,
// it can be replaced with a mock.
type EnterpriseRegistry interface {
	IsRegistered(enterprise common.Address) bool
}

// ProofVerifier verifies ZK proofs for cross-enterprise messages.
// The hub never generates proofs (INV-CE10 HubNeutrality); it only verifies.
type ProofVerifier interface {
	VerifyProof(proof []byte, publicSignals []byte) bool
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

var (
	// ErrZeroAddress indicates an enterprise address is the zero address.
	ErrZeroAddress = errors.New("cross: zero address")

	// ErrSelfMessage indicates a message where source == dest.
	ErrSelfMessage = errors.New("cross: source and destination must differ")

	// ErrNotRegistered indicates an enterprise is not registered on L1.
	ErrNotRegistered = errors.New("cross: enterprise not registered")

	// ErrStaleStateRoot indicates the message's state root does not match the current on-chain root.
	ErrStaleStateRoot = errors.New("cross: stale state root")

	// ErrInvalidProof indicates a ZK proof failed verification.
	ErrInvalidProof = errors.New("cross: invalid ZK proof")

	// ErrNonceReplay indicates a nonce has already been consumed for this directed pair.
	ErrNonceReplay = errors.New("cross: nonce already consumed (replay)")

	// ErrMessageNotFound indicates the requested message does not exist.
	ErrMessageNotFound = errors.New("cross: message not found")

	// ErrInvalidTransition indicates an invalid message status transition.
	ErrInvalidTransition = errors.New("cross: invalid status transition")

	// ErrTimeoutNotReached indicates a timeout was attempted before the deadline.
	ErrTimeoutNotReached = errors.New("cross: timeout deadline not reached")

	// ErrSettlementFailed indicates atomic settlement failed (proof or root check).
	ErrSettlementFailed = errors.New("cross: settlement conditions not met")
)

// ---------------------------------------------------------------------------
// Hub State (TLA+ variables mirrored in Go)
// ---------------------------------------------------------------------------

// HubState holds the mutable protocol state of the hub. This mirrors the
// TLA+ variables: messages, usedNonces, msgCounter, stateRoots, blockHeight.
// Thread-safe via sync.RWMutex.
type HubState struct {
	mu sync.RWMutex

	// Messages is the set of all cross-enterprise message records.
	// [Spec: HubAndSpoke.tla, messages]
	Messages map[[32]byte]*CrossEnterpriseMessage

	// UsedNonces tracks consumed nonces per directed enterprise pair.
	// A nonce is consumed when a message passes hub verification (Phase 2).
	// [Spec: HubAndSpoke.tla, usedNonces]
	UsedNonces map[EnterprisePair]map[uint64]bool

	// MsgCounters tracks the next nonce to allocate per directed pair.
	// [Spec: HubAndSpoke.tla, msgCounter]
	MsgCounters map[EnterprisePair]uint64

	// StateRoots tracks the current state root per enterprise.
	// Updated via external state root provider or direct calls.
	// [Spec: HubAndSpoke.tla, stateRoots]
	StateRoots map[common.Address][32]byte

	// BlockHeight is the current L1 block height.
	// [Spec: HubAndSpoke.tla, blockHeight]
	BlockHeight uint64
}

// NewHubState creates an initialized, empty hub state.
func NewHubState() *HubState {
	return &HubState{
		Messages:    make(map[[32]byte]*CrossEnterpriseMessage),
		UsedNonces:  make(map[EnterprisePair]map[uint64]bool),
		MsgCounters: make(map[EnterprisePair]uint64),
		StateRoots:  make(map[common.Address][32]byte),
		BlockHeight: 1,
	}
}
