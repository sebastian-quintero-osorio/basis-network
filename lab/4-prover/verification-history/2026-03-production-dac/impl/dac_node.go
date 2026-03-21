package da

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"fmt"
)

// NewDACNode creates a new DAC node with the given identity and ECDSA key pair.
// The node starts in online state with empty storage.
func NewDACNode(id NodeID, privKey *ecdsa.PrivateKey) *DACNode {
	return &DACNode{
		ID:         id,
		PrivateKey: privKey,
		PublicKey:  &privKey.PublicKey,
		online:     true,
		stored:     make(map[uint64]*NodePackage),
		verified:   make(map[uint64]bool),
		attested:   make(map[uint64]bool),
	}
}

// IsOnline returns whether the node is currently operational.
// [Spec: nodeOnline[n] variable]
func (n *DACNode) IsOnline() bool {
	n.mu.RLock()
	defer n.mu.RUnlock()
	return n.online
}

// SetOnline brings the node back online. Persistent storage is preserved.
// [Spec: NodeRecover(n) action -- node comes back, chunks/shares remain]
func (n *DACNode) SetOnline() {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.online = true
}

// SetOffline takes the node offline (crash, partition, adversarial shutdown).
// [Spec: NodeFail(n) action -- node goes offline]
func (n *DACNode) SetOffline() {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.online = false
}

// Receive stores a dispersal package. Requires the node to be online.
// [Spec: DistributeChunks action -- distributedTo[b] <- {n : nodeOnline[n]}]
func (n *DACNode) Receive(pkg *NodePackage) error {
	n.mu.Lock()
	defer n.mu.Unlock()

	if !n.online {
		return fmt.Errorf("%w: node %d", ErrNodeOffline, n.ID)
	}
	n.stored[pkg.BatchID] = pkg
	return nil
}

// Verify checks the RS chunk integrity against its hash (KZG verification gate).
// A node must verify before it can attest. Corrupted chunks fail this check.
// [Spec: VerifyChunk(n, b) action -- guards: online, distributed, not verified, not corrupted]
func (n *DACNode) Verify(batchID uint64) error {
	n.mu.Lock()
	defer n.mu.Unlock()

	if !n.online {
		return fmt.Errorf("%w: node %d", ErrNodeOffline, n.ID)
	}

	pkg, exists := n.stored[batchID]
	if !exists {
		return fmt.Errorf("%w: node %d, batch %d", ErrNodeNotDistributed, n.ID, batchID)
	}

	if n.verified[batchID] {
		return fmt.Errorf("%w: node %d, batch %d", ErrAlreadyVerified, n.ID, batchID)
	}

	// Verify chunk data against its claimed hash.
	// This models the KZG polynomial commitment verification from the TLA+ spec:
	// corrupted chunks produce a hash mismatch and fail this gate.
	computedHash := sha256.Sum256(pkg.Chunk.Data)
	if computedHash != pkg.Chunk.DataHash {
		return fmt.Errorf("%w: node %d, batch %d", ErrChunkVerificationFailed, n.ID, batchID)
	}

	n.verified[batchID] = true
	return nil
}

// Attest creates a signed attestation for a batch. Requires prior verification.
// [Spec: NodeAttest(n, b) -- guards: online, verified (KZG gate), not attested, cert=none]
func (n *DACNode) Attest(batchID uint64) (*Attestation, error) {
	n.mu.Lock()
	defer n.mu.Unlock()

	if !n.online {
		return nil, fmt.Errorf("%w: node %d", ErrNodeOffline, n.ID)
	}

	pkg, exists := n.stored[batchID]
	if !exists {
		return nil, fmt.Errorf("%w: node %d, batch %d", ErrNodeNotDistributed, n.ID, batchID)
	}

	// AttestationIntegrity invariant: only verified nodes can attest.
	if !n.verified[batchID] {
		return nil, fmt.Errorf("%w: node %d, batch %d", ErrNodeNotVerified, n.ID, batchID)
	}

	// Double-attestation prevention.
	if n.attested[batchID] {
		return nil, fmt.Errorf("%w: node %d, batch %d", ErrAlreadyAttested, n.ID, batchID)
	}

	att, err := signAttestation(n.PrivateKey, n.ID, batchID, pkg.DataHash)
	if err != nil {
		return nil, fmt.Errorf("sign attestation: %w", err)
	}

	n.attested[batchID] = true
	return att, nil
}

// GetChunk returns the stored RS chunk for a batch, if available.
func (n *DACNode) GetChunk(batchID uint64) ([]byte, error) {
	n.mu.RLock()
	defer n.mu.RUnlock()

	if !n.online {
		return nil, fmt.Errorf("%w: node %d", ErrNodeOffline, n.ID)
	}

	pkg, exists := n.stored[batchID]
	if !exists {
		return nil, fmt.Errorf("%w: node %d, batch %d", ErrNodeNotDistributed, n.ID, batchID)
	}

	// Return a copy to prevent external mutation.
	chunk := make([]byte, len(pkg.Chunk.Data))
	copy(chunk, pkg.Chunk.Data)
	return chunk, nil
}

// GetKeyShare returns the Shamir share for a batch, if available.
func (n *DACNode) GetKeyShare(batchID uint64) (*ShamirShare, error) {
	n.mu.RLock()
	defer n.mu.RUnlock()

	if !n.online {
		return nil, fmt.Errorf("%w: node %d", ErrNodeOffline, n.ID)
	}

	pkg, exists := n.stored[batchID]
	if !exists {
		return nil, fmt.Errorf("%w: node %d, batch %d", ErrNodeNotDistributed, n.ID, batchID)
	}

	return &pkg.KeyShare, nil
}

// HasPackage returns whether the node has stored data for a batch.
func (n *DACNode) HasPackage(batchID uint64) bool {
	n.mu.RLock()
	defer n.mu.RUnlock()
	_, exists := n.stored[batchID]
	return exists
}

// HasVerified returns whether the node has verified the chunk for a batch.
func (n *DACNode) HasVerified(batchID uint64) bool {
	n.mu.RLock()
	defer n.mu.RUnlock()
	return n.verified[batchID]
}

// HasAttested returns whether the node has attested for a batch.
func (n *DACNode) HasAttested(batchID uint64) bool {
	n.mu.RLock()
	defer n.mu.RUnlock()
	return n.attested[batchID]
}

// CorruptChunk simulates adversarial corruption of stored data.
// Used for adversarial testing only.
// [Spec: CorruptChunk(n, b) action -- malicious node corrupts stored RS chunk]
func (n *DACNode) CorruptChunk(batchID uint64) error {
	n.mu.Lock()
	defer n.mu.Unlock()

	pkg, exists := n.stored[batchID]
	if !exists {
		return fmt.Errorf("%w: node %d, batch %d", ErrNodeNotDistributed, n.ID, batchID)
	}

	// Flip bytes in the stored chunk data to simulate corruption.
	if len(pkg.Chunk.Data) > 0 {
		pkg.Chunk.Data[0] ^= 0xFF
		pkg.Chunk.Data[len(pkg.Chunk.Data)-1] ^= 0xFF
	}

	return nil
}
