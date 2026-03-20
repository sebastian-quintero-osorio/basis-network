package cross

import (
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// ---------------------------------------------------------------------------
// Message ID Computation
// ---------------------------------------------------------------------------

// ComputeMessageID computes a deterministic message identifier from the
// directed pair and nonce: keccak256(source || dest || nonce).
// This mirrors on-chain ID computation in BasisHub.sol.
func ComputeMessageID(source, dest common.Address, nonce uint64) [32]byte {
	data := make([]byte, 0, 72) // 20 + 20 + 32
	data = append(data, source.Bytes()...)
	data = append(data, dest.Bytes()...)

	// Encode nonce as 32-byte big-endian (matches abi.encodePacked uint256)
	var nonceBuf [32]byte
	nonceBuf[24] = byte(nonce >> 56)
	nonceBuf[25] = byte(nonce >> 48)
	nonceBuf[26] = byte(nonce >> 40)
	nonceBuf[27] = byte(nonce >> 32)
	nonceBuf[28] = byte(nonce >> 24)
	nonceBuf[29] = byte(nonce >> 16)
	nonceBuf[30] = byte(nonce >> 8)
	nonceBuf[31] = byte(nonce)
	data = append(data, nonceBuf[:]...)

	return crypto.Keccak256Hash(data)
}

// ---------------------------------------------------------------------------
// Message Construction
// ---------------------------------------------------------------------------

// NewPreparedMessage creates a new cross-enterprise message in the Prepared state.
// This is the Phase 1 output: the source enterprise has computed a commitment and
// ZK proof. The proof validity is determined by the caller (the enterprise's prover).
//
// [Spec: HubAndSpoke.tla, PrepareMessage action]
func NewPreparedMessage(
	source, dest common.Address,
	nonce uint64,
	sourceProofValid bool,
	sourceStateRoot [32]byte,
	commitment [32]byte,
	blockHeight uint64,
) (*CrossEnterpriseMessage, error) {
	pair := EnterprisePair{Source: source, Dest: dest}
	if err := pair.Validate(); err != nil {
		return nil, err
	}
	if nonce == 0 {
		return nil, ErrNonceReplay
	}

	id := ComputeMessageID(source, dest, nonce)

	return &CrossEnterpriseMessage{
		ID:               id,
		Source:           source,
		Dest:             dest,
		Nonce:            nonce,
		SourceProofValid: sourceProofValid,
		DestProofValid:   false,
		SourceStateRoot:  sourceStateRoot,
		DestStateRoot:    [32]byte{},
		Status:           StatusPrepared,
		CreatedAtBlock:   blockHeight,
		Commitment:       commitment,
	}, nil
}

// ---------------------------------------------------------------------------
// Message Validation
// ---------------------------------------------------------------------------

// ValidateMessage checks structural validity of a cross-enterprise message.
// This does NOT check protocol state (nonce freshness, root currency, etc.);
// those checks are performed by the Hub during verification.
func ValidateMessage(msg *CrossEnterpriseMessage) error {
	if msg == nil {
		return ErrMessageNotFound
	}
	pair := EnterprisePair{Source: msg.Source, Dest: msg.Dest}
	if err := pair.Validate(); err != nil {
		return err
	}
	if msg.Nonce == 0 {
		return ErrNonceReplay
	}
	if msg.Status == 0 {
		return ErrInvalidTransition
	}
	expectedID := ComputeMessageID(msg.Source, msg.Dest, msg.Nonce)
	if msg.ID != expectedID {
		return ErrMessageNotFound
	}
	return nil
}

// ComputePairHash computes the keccak256 hash of a directed enterprise pair.
// Used as mapping key in Solidity: keccak256(abi.encodePacked(source, dest)).
func ComputePairHash(source, dest common.Address) [32]byte {
	data := make([]byte, 0, 40)
	data = append(data, source.Bytes()...)
	data = append(data, dest.Bytes()...)
	return crypto.Keccak256Hash(data)
}
