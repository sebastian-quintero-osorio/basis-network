package da

import (
	"crypto/ecdsa"
	"encoding/binary"
	"fmt"
	"time"

	ethcrypto "github.com/ethereum/go-ethereum/crypto"
)

// signAttestation creates an ECDSA secp256k1 attestation signature.
// The message format is keccak256(batchID || dataHash) for Solidity ecrecover compatibility.
// [Spec: NodeAttest action -- node signs attestation after KZG verification]
func signAttestation(privKey *ecdsa.PrivateKey, nodeID NodeID, batchID uint64, dataHash [32]byte) (*Attestation, error) {
	digest := attestationDigest(batchID, dataHash)

	sig, err := ethcrypto.Sign(digest, privKey)
	if err != nil {
		return nil, fmt.Errorf("ecdsa sign: %w", err)
	}

	// Convert V from 0/1 to 27/28 for Ethereum ecrecover compatibility.
	sig[64] += 27

	return &Attestation{
		NodeID:    nodeID,
		BatchID:   batchID,
		DataHash:  dataHash,
		Signature: sig,
		Timestamp: time.Now(),
	}, nil
}

// VerifyAttestation checks that an attestation signature is valid for the given public key.
func VerifyAttestation(att *Attestation, pubKey *ecdsa.PublicKey) bool {
	digest := attestationDigest(att.BatchID, att.DataHash)

	// Convert signature back: remove V byte for VerifySignature.
	if len(att.Signature) != 65 {
		return false
	}

	pubKeyBytes := ethcrypto.FromECDSAPub(pubKey)
	return ethcrypto.VerifySignature(pubKeyBytes, digest, att.Signature[:64])
}

// RecoverSigner recovers the signer's public key from an attestation signature.
// Returns the Ethereum address of the signer for on-chain verification.
func RecoverSigner(att *Attestation) (*ecdsa.PublicKey, error) {
	digest := attestationDigest(att.BatchID, att.DataHash)

	// Convert V back to 0/1 for SigToPub.
	sig := make([]byte, 65)
	copy(sig, att.Signature)
	sig[64] -= 27

	pubKey, err := ethcrypto.SigToPub(digest, sig)
	if err != nil {
		return nil, fmt.Errorf("recover signer: %w", err)
	}
	return pubKey, nil
}

// attestationDigest computes the message hash for attestation signing.
// Format: keccak256(uint64(batchID) || bytes32(dataHash))
// This matches the Solidity verification: keccak256(abi.encodePacked(batchID, dataHash))
func attestationDigest(batchID uint64, dataHash [32]byte) []byte {
	msg := make([]byte, 8+32)
	binary.BigEndian.PutUint64(msg[:8], batchID)
	copy(msg[8:], dataHash[:])
	return ethcrypto.Keccak256(msg)
}
