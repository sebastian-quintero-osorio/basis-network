package da

import (
	"fmt"
	"time"

	ethcrypto "github.com/ethereum/go-ethereum/crypto"
)

// ProduceCertificate aggregates attestations into a DACCertificate.
// Enforces CertificateSoundness: valid cert requires >= threshold attestations.
// [Spec: ProduceCertificate(b) -- guards: certState[b] = "none", |attested[b]| >= Threshold]
func (c *Committee) ProduceCertificate(batchID uint64, attestations []Attestation) (*DACCertificate, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.certState[batchID] != CertNone {
		return nil, fmt.Errorf("%w: batch %d, state %s", ErrCertificateExists, batchID, c.certState[batchID])
	}

	if len(attestations) < c.Config.Threshold {
		return nil, fmt.Errorf("%w: have %d, need %d", ErrInsufficientAttestations, len(attestations), c.Config.Threshold)
	}

	// Verify each attestation and build signer bitmap.
	var bitmap uint8
	seenSigners := make(map[NodeID]bool, len(attestations))
	memberMap := c.memberMap()

	for _, att := range attestations {
		// Check signer is a committee member.
		if _, isMember := memberMap[att.NodeID]; !isMember {
			return nil, fmt.Errorf("%w: node %d", ErrNotCommitteeMember, att.NodeID)
		}

		// Check no duplicate signers.
		if seenSigners[att.NodeID] {
			return nil, fmt.Errorf("%w: node %d", ErrDuplicateSigner, att.NodeID)
		}

		// Verify signature.
		node := c.Nodes[int(att.NodeID)]
		if !VerifyAttestation(&att, node.PublicKey) {
			return nil, fmt.Errorf("%w: node %d", ErrInvalidSignature, att.NodeID)
		}

		seenSigners[att.NodeID] = true
		bitmap |= 1 << uint(att.NodeID)
	}

	cert := &DACCertificate{
		BatchID:      batchID,
		DataHash:     attestations[0].DataHash,
		Attestations: attestations,
		SignerBitmap: bitmap,
		Timestamp:    time.Now(),
	}

	c.certState[batchID] = CertValid
	c.certs[batchID] = cert
	return cert, nil
}

// VerifyCertificate checks that a certificate has sufficient valid signatures
// from committee members. Returns nil if valid, error otherwise.
// [Spec: CertificateSoundness invariant -- valid cert => |attested| >= Threshold]
func (c *Committee) VerifyCertificate(cert *DACCertificate) error {
	if len(cert.Attestations) < c.Config.Threshold {
		return fmt.Errorf("%w: have %d, need %d",
			ErrInsufficientAttestations, len(cert.Attestations), c.Config.Threshold)
	}

	seenSigners := make(map[NodeID]bool, len(cert.Attestations))
	memberMap := c.memberMap()
	validCount := 0

	for _, att := range cert.Attestations {
		if _, isMember := memberMap[att.NodeID]; !isMember {
			continue
		}
		if seenSigners[att.NodeID] {
			continue
		}

		node := c.Nodes[int(att.NodeID)]
		if VerifyAttestation(&att, node.PublicKey) {
			validCount++
			seenSigners[att.NodeID] = true
		}
	}

	if validCount < c.Config.Threshold {
		return fmt.Errorf("%w: %d valid of %d required",
			ErrInsufficientAttestations, validCount, c.Config.Threshold)
	}
	return nil
}

// GetCertificate returns the stored certificate for a batch.
func (c *Committee) GetCertificate(batchID uint64) (*DACCertificate, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	cert, exists := c.certs[batchID]
	if !exists {
		return nil, fmt.Errorf("%w: batch %d", ErrNoCertificate, batchID)
	}
	return cert, nil
}

// GetCertState returns the certificate state for a batch.
func (c *Committee) GetCertState(batchID uint64) CertState {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.certState[batchID]
}

// CertificateSignerAddresses returns the Ethereum addresses of certificate signers.
// Used for on-chain verification against the BasisDAC contract.
func CertificateSignerAddresses(cert *DACCertificate) ([]string, error) {
	addresses := make([]string, 0, len(cert.Attestations))
	for _, att := range cert.Attestations {
		pubKey, err := RecoverSigner(&att)
		if err != nil {
			return nil, fmt.Errorf("recover signer for node %d: %w", att.NodeID, err)
		}
		addr := ethcrypto.PubkeyToAddress(*pubKey)
		addresses = append(addresses, addr.Hex())
	}
	return addresses, nil
}

// memberMap builds a lookup map of committee member NodeIDs.
func (c *Committee) memberMap() map[NodeID]bool {
	m := make(map[NodeID]bool, len(c.Nodes))
	for _, node := range c.Nodes {
		m[node.ID] = true
	}
	return m
}
