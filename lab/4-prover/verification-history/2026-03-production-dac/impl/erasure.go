package da

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"io"
	"math/big"

	"github.com/klauspost/reedsolomon"
)

// bn254Prime is the BN254 scalar field order. AES keys are reduced modulo this prime
// to ensure compatibility with Shamir secret sharing over GF(bn254Prime).
// 254 bits of key entropy -- more than sufficient for AES-256-GCM.
// [Spec: Shamir sharing operates over this finite field]
var bn254Prime = new(big.Int).SetBytes([]byte{
	0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
	0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
	0x28, 0x33, 0xe8, 0x48, 0x79, 0xb9, 0x70, 0x91,
	0x43, 0xe1, 0xf5, 0x93, 0xf0, 0x00, 0x00, 0x01,
})

// RSEncoder wraps Reed-Solomon encoding with AES-256-GCM encryption.
// [Spec: Disperse action -- encrypt(AES-256-GCM) -> RS-encode(5,7)]
type RSEncoder struct {
	dataShards   int
	parityShards int
	rs           reedsolomon.Encoder
}

// NewRSEncoder creates a new erasure encoder with the given shard configuration.
func NewRSEncoder(dataShards, parityShards int) (*RSEncoder, error) {
	rs, err := reedsolomon.New(dataShards, parityShards)
	if err != nil {
		return nil, fmt.Errorf("create rs encoder: %w", err)
	}
	return &RSEncoder{
		dataShards:   dataShards,
		parityShards: parityShards,
		rs:           rs,
	}, nil
}

// Encode encrypts data with AES-256-GCM and RS-encodes the ciphertext into n shards.
// Returns the encoded chunks, the AES key (to be Shamir-shared), and any error.
// [Spec: First two steps of Disperse -- encrypt then RS-encode]
func (e *RSEncoder) Encode(data []byte) (*EncodeResult, []byte, error) {
	// Generate random AES-256 key, reduced modulo BN254 prime for Shamir compatibility.
	rawKey := make([]byte, AESKeySize)
	if _, err := io.ReadFull(rand.Reader, rawKey); err != nil {
		return nil, nil, fmt.Errorf("generate aes key: %w", err)
	}
	keyInt := new(big.Int).SetBytes(rawKey)
	keyInt.Mod(keyInt, bn254Prime)
	key := make([]byte, AESKeySize)
	keyBytes := keyInt.Bytes()
	copy(key[AESKeySize-len(keyBytes):], keyBytes)

	// Hash original plaintext for integrity verification at recovery.
	dataHash := sha256.Sum256(data)

	// Encrypt with AES-256-GCM.
	ciphertext, err := encryptAESGCM(key, data)
	if err != nil {
		return nil, nil, fmt.Errorf("aes-gcm encrypt: %w", err)
	}
	cipherHash := sha256.Sum256(ciphertext)

	// Split ciphertext into k data shards.
	shards, err := e.rs.Split(ciphertext)
	if err != nil {
		return nil, nil, fmt.Errorf("rs split: %w", err)
	}

	// Generate n-k parity shards.
	if err := e.rs.Encode(shards); err != nil {
		return nil, nil, fmt.Errorf("rs encode parity: %w", err)
	}

	// Build chunk results with per-shard hashes for verification.
	chunks := make([]EncodedChunk, len(shards))
	shardSize := len(shards[0])
	for i, shard := range shards {
		chunks[i] = EncodedChunk{
			Index:    i,
			Data:     shard,
			DataHash: sha256.Sum256(shard),
		}
	}

	result := &EncodeResult{
		Chunks:       chunks,
		DataHash:     dataHash,
		CipherHash:   cipherHash,
		ShardSize:    shardSize,
		OriginalSize: len(data),
	}
	return result, key, nil
}

// Decode reconstructs the original data from at least k shards and the AES key.
// Missing shards must be nil in the slice. Detects corruption via AES-GCM auth tag.
// [Spec: RecoverData action -- RS-decode -> AES-decrypt]
func (e *RSEncoder) Decode(shards [][]byte, key []byte, originalSize int) ([]byte, error) {
	totalShards := e.dataShards + e.parityShards
	if len(shards) != totalShards {
		return nil, fmt.Errorf("expected %d shards, got %d", totalShards, len(shards))
	}

	available := 0
	for _, s := range shards {
		if s != nil {
			available++
		}
	}
	if available < e.dataShards {
		return nil, fmt.Errorf("%w: need %d, have %d", ErrInsufficientShards, e.dataShards, available)
	}

	// Reconstruct missing shards via RS MDS property.
	if err := e.rs.Reconstruct(shards); err != nil {
		return nil, fmt.Errorf("rs reconstruct: %w", err)
	}

	// Join data shards back to ciphertext.
	ciphertextSize := 0
	for i := 0; i < e.dataShards; i++ {
		ciphertextSize += len(shards[i])
	}
	ciphertext := make([]byte, 0, ciphertextSize)
	for i := 0; i < e.dataShards; i++ {
		ciphertext = append(ciphertext, shards[i]...)
	}

	// Trim RS padding (RS pads to equal-sized shards).
	expectedLen := originalSize + AESGCMOverhead
	if len(ciphertext) > expectedLen {
		ciphertext = ciphertext[:expectedLen]
	}

	// AES-GCM decrypt -- authentication tag detects corruption.
	plaintext, err := decryptAESGCM(key, ciphertext)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrCorruptedData, err)
	}

	return plaintext, nil
}

// encryptAESGCM encrypts plaintext with AES-256-GCM using a random nonce.
// Output format: nonce (12 bytes) || ciphertext || tag (16 bytes).
func encryptAESGCM(key, plaintext []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("aes new cipher: %w", err)
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("aes-gcm: %w", err)
	}

	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("generate nonce: %w", err)
	}

	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

// decryptAESGCM decrypts AES-256-GCM ciphertext (nonce prepended).
// Returns error if authentication tag is invalid (corruption detected).
func decryptAESGCM(key, ciphertext []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("aes new cipher: %w", err)
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("aes-gcm: %w", err)
	}

	nonceSize := gcm.NonceSize()
	if len(ciphertext) < nonceSize {
		return nil, fmt.Errorf("ciphertext too short: %d < %d", len(ciphertext), nonceSize)
	}

	nonce, ct := ciphertext[:nonceSize], ciphertext[nonceSize:]
	return gcm.Open(nil, nonce, ct, nil)
}
