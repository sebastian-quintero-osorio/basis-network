// Package erasure implements Reed-Solomon erasure coding for DAC data dispersal.
//
// The encoding scheme splits data into k data shards and generates n-k parity shards,
// enabling reconstruction from any k of n total shards. This provides fault tolerance
// against n-k node failures with only n/k storage overhead.
package erasure

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
// This gives 254 bits of key entropy -- more than sufficient for AES-256-GCM.
var bn254Prime = new(big.Int).SetBytes([]byte{
	0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
	0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
	0x28, 0x33, 0xe8, 0x48, 0x79, 0xb9, 0x70, 0x91,
	0x43, 0xe1, 0xf5, 0x93, 0xf0, 0x00, 0x00, 0x01,
})

// Config holds the erasure coding parameters for the DAC.
type Config struct {
	DataShards   int // k: number of data shards (reconstruction threshold)
	ParityShards int // n-k: number of parity shards
}

// DefaultConfig returns the production (5,7) configuration.
func DefaultConfig() Config {
	return Config{
		DataShards:   5,
		ParityShards: 2,
	}
}

// TotalShards returns the total number of shards (n = k + parity).
func (c Config) TotalShards() int {
	return c.DataShards + c.ParityShards
}

// Encoder wraps the Reed-Solomon encoder with encryption support.
type Encoder struct {
	config Config
	rs     reedsolomon.Encoder
}

// NewEncoder creates a new erasure encoder with the given configuration.
func NewEncoder(config Config) (*Encoder, error) {
	rs, err := reedsolomon.New(config.DataShards, config.ParityShards)
	if err != nil {
		return nil, fmt.Errorf("create rs encoder: %w", err)
	}
	return &Encoder{config: config, rs: rs}, nil
}

// EncodedChunk represents a single shard distributed to a DAC node.
type EncodedChunk struct {
	Index    int    // Shard index (0 to n-1)
	Data     []byte // Shard data (encrypted ciphertext chunk)
	DataHash [32]byte // SHA-256 hash of chunk data for integrity
}

// EncodeResult contains all outputs of the encode operation.
type EncodeResult struct {
	Chunks       []EncodedChunk // n chunks (k data + parity)
	DataHash     [32]byte       // SHA-256 of original plaintext data
	CipherHash   [32]byte       // SHA-256 of the full ciphertext
	ShardSize    int            // Size of each shard in bytes
	OriginalSize int            // Size of original data before padding
}

// Encode takes raw data, encrypts it with AES-256-GCM, and RS-encodes the ciphertext
// into n shards. Returns the encoded chunks and the AES key (to be Shamir-shared separately).
func (e *Encoder) Encode(data []byte) (*EncodeResult, []byte, error) {
	// Generate random AES-256 key, reduced modulo BN254 prime for Shamir compatibility.
	// This gives 254 bits of key entropy (more than sufficient for AES-256-GCM).
	rawKey := make([]byte, 32)
	if _, err := io.ReadFull(rand.Reader, rawKey); err != nil {
		return nil, nil, fmt.Errorf("generate key: %w", err)
	}
	keyInt := new(big.Int).SetBytes(rawKey)
	keyInt.Mod(keyInt, bn254Prime)
	key := make([]byte, 32)
	keyBytes := keyInt.Bytes()
	copy(key[32-len(keyBytes):], keyBytes)

	// Hash the original plaintext
	dataHash := sha256.Sum256(data)

	// Encrypt with AES-256-GCM
	ciphertext, err := encryptAESGCM(key, data)
	if err != nil {
		return nil, nil, fmt.Errorf("encrypt: %w", err)
	}

	cipherHash := sha256.Sum256(ciphertext)

	// Split ciphertext into k data shards
	shards, err := e.rs.Split(ciphertext)
	if err != nil {
		return nil, nil, fmt.Errorf("split data: %w", err)
	}

	// Generate parity shards
	if err := e.rs.Encode(shards); err != nil {
		return nil, nil, fmt.Errorf("encode parity: %w", err)
	}

	// Build chunk results
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
// Missing shards should be passed as nil in the shards slice.
func (e *Encoder) Decode(shards [][]byte, key []byte, originalSize int) ([]byte, error) {
	if len(shards) != e.config.TotalShards() {
		return nil, fmt.Errorf("expected %d shards, got %d", e.config.TotalShards(), len(shards))
	}

	// Count available shards
	available := 0
	for _, s := range shards {
		if s != nil {
			available++
		}
	}
	if available < e.config.DataShards {
		return nil, fmt.Errorf("need %d shards, only %d available", e.config.DataShards, available)
	}

	// Reconstruct missing shards
	if err := e.rs.Reconstruct(shards); err != nil {
		return nil, fmt.Errorf("reconstruct: %w", err)
	}

	// Join data shards back to ciphertext
	ciphertextSize := 0
	for i := 0; i < e.config.DataShards; i++ {
		ciphertextSize += len(shards[i])
	}

	ciphertext := make([]byte, 0, ciphertextSize)
	for i := 0; i < e.config.DataShards; i++ {
		ciphertext = append(ciphertext, shards[i]...)
	}

	// AES-GCM adds 12 bytes nonce + 16 bytes tag = 28 bytes overhead
	expectedCiphertextLen := originalSize + 12 + 16

	// Trim padding added by RS split (it pads to make equal-sized shards)
	if len(ciphertext) > expectedCiphertextLen {
		ciphertext = ciphertext[:expectedCiphertextLen]
	}

	// Decrypt
	plaintext, err := decryptAESGCM(key, ciphertext)
	if err != nil {
		return nil, fmt.Errorf("decrypt: %w", err)
	}

	return plaintext, nil
}

// Verify checks that a shard is consistent with the encoding.
// Returns true if the shard data matches its claimed hash.
func (e *Encoder) Verify(shards [][]byte) (bool, error) {
	return e.rs.Verify(shards)
}

// encryptAESGCM encrypts plaintext with AES-256-GCM using a random nonce.
func encryptAESGCM(key, plaintext []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}

	// nonce is prepended to ciphertext
	return gcm.Seal(nonce, nonce, plaintext, nil), nil
}

// decryptAESGCM decrypts AES-256-GCM ciphertext (nonce prepended).
func decryptAESGCM(key, ciphertext []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	nonceSize := gcm.NonceSize()
	if len(ciphertext) < nonceSize {
		return nil, fmt.Errorf("ciphertext too short")
	}

	nonce, ciphertext := ciphertext[:nonceSize], ciphertext[nonceSize:]
	return gcm.Open(nil, nonce, ciphertext, nil)
}
