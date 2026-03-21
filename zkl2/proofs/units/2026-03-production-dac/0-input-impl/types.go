// Package da implements the production Data Availability Committee protocol
// for the Basis Network enterprise zkEVM L2.
//
// Architecture: Hybrid AES-256-GCM + Reed-Solomon (5,7) erasure coding +
// Shamir (5,7) secret sharing. This combines computational privacy (AES),
// storage-efficient redundancy (RS at 1.4x overhead), and information-theoretic
// key secrecy (Shamir) into a single DAC protocol.
//
// [Spec: zkl2/specs/units/2026-03-production-dac/ProductionDAC.tla]
package da

import (
	"crypto/ecdsa"
	"errors"
	"math/big"
	"sync"
	"time"
)

// Protocol constants derived from TLA+ specification.
// [Spec: CONSTANTS Nodes, Batches, Threshold in ProductionDAC.tla]
const (
	DefaultDataShards   = 5  // k: RS data shards (reconstruction threshold)
	DefaultParityShards = 2  // n-k: RS parity shards
	DefaultThreshold    = 5  // k: minimum attestations/shares for certificate/recovery
	DefaultTotal        = 7  // n: total committee members
	AESKeySize          = 32 // AES-256 key size in bytes
	AESGCMNonceSize     = 12 // AES-GCM nonce size
	AESGCMTagSize       = 16 // AES-GCM authentication tag size
	AESGCMOverhead      = AESGCMNonceSize + AESGCMTagSize
)

// Sentinel errors for protocol operations.
var (
	ErrInsufficientShards       = errors.New("da: insufficient RS shards for reconstruction")
	ErrInsufficientShares       = errors.New("da: insufficient Shamir shares for key recovery")
	ErrInsufficientAttestations = errors.New("da: insufficient attestations for certificate")
	ErrChunkVerificationFailed  = errors.New("da: chunk hash mismatch (KZG verification gate)")
	ErrNodeOffline              = errors.New("da: node is offline")
	ErrNodeNotDistributed       = errors.New("da: node has not received distribution for batch")
	ErrNodeNotVerified          = errors.New("da: node has not verified chunk for batch")
	ErrAlreadyAttested          = errors.New("da: node already attested for batch")
	ErrAlreadyVerified          = errors.New("da: node already verified chunk for batch")
	ErrCertificateExists        = errors.New("da: certificate already produced for batch")
	ErrNoCertificate            = errors.New("da: no valid certificate exists for batch")
	ErrCorruptedData            = errors.New("da: data corruption detected during recovery")
	ErrHashMismatch             = errors.New("da: recovered data hash does not match expected")
	ErrFallbackActive           = errors.New("da: AnyTrust fallback active for batch")
	ErrSecretExceedsField       = errors.New("da: secret exceeds BN254 field prime")
	ErrDuplicateShares          = errors.New("da: duplicate share x-values detected")
	ErrInvalidSignature         = errors.New("da: invalid ECDSA signature")
	ErrDuplicateSigner          = errors.New("da: duplicate signer in certificate")
	ErrNotCommitteeMember       = errors.New("da: signer is not a committee member")
	ErrBatchNotDistributed      = errors.New("da: batch has not been distributed")
)

// CertState represents the certificate state for a batch.
// [Spec: certState variable in ProductionDAC.tla -- {"none", "valid", "fallback"}]
type CertState int

const (
	CertNone     CertState = iota // No certificate produced
	CertValid                     // Valid certificate with >= threshold attestations
	CertFallback                  // AnyTrust fallback (validium -> rollup mode)
)

func (s CertState) String() string {
	switch s {
	case CertNone:
		return "none"
	case CertValid:
		return "valid"
	case CertFallback:
		return "fallback"
	default:
		return "unknown"
	}
}

// RecoveryState represents the outcome of a data recovery attempt.
// [Spec: recoverState variable in ProductionDAC.tla -- {"none", "success", "corrupted", "failed"}]
type RecoveryState int

const (
	RecoveryNone      RecoveryState = iota // No recovery attempted
	RecoverySuccess                        // Data recovered and verified
	RecoveryCorrupted                      // Corruption detected (AES-GCM auth or hash mismatch)
	RecoveryFailed                         // Insufficient chunks or shares
)

func (s RecoveryState) String() string {
	switch s {
	case RecoveryNone:
		return "none"
	case RecoverySuccess:
		return "success"
	case RecoveryCorrupted:
		return "corrupted"
	case RecoveryFailed:
		return "failed"
	default:
		return "unknown"
	}
}

// Config holds the full DAC protocol configuration.
type Config struct {
	DataShards    int           // k: RS data shards
	ParityShards  int           // n-k: RS parity shards
	Threshold     int           // Minimum attestations for valid certificate
	Total         int           // Total committee members (must equal DataShards + ParityShards)
	AttestTimeout time.Duration // Maximum time to collect attestations
}

// DefaultConfig returns the production (5,7) configuration.
func DefaultConfig() Config {
	return Config{
		DataShards:    DefaultDataShards,
		ParityShards:  DefaultParityShards,
		Threshold:     DefaultThreshold,
		Total:         DefaultTotal,
		AttestTimeout: 1 * time.Second,
	}
}

// NodeID identifies a DAC committee member.
type NodeID int

// EncodedChunk represents a single RS shard distributed to a DAC node.
type EncodedChunk struct {
	Index    int      // Shard index (0 to n-1)
	Data     []byte   // Shard data (encrypted ciphertext chunk)
	DataHash [32]byte // SHA-256 hash of shard data for integrity verification
}

// EncodeResult contains all outputs of the RS encode operation.
type EncodeResult struct {
	Chunks       []EncodedChunk // n chunks (k data + parity)
	DataHash     [32]byte       // SHA-256 of original plaintext
	CipherHash   [32]byte       // SHA-256 of full ciphertext
	ShardSize    int            // Size of each shard in bytes
	OriginalSize int            // Size of original data before padding
}

// ShamirShare represents a point on the Shamir polynomial: (X, Y) in GF(BN254).
type ShamirShare struct {
	X *big.Int // Evaluation point (1-indexed: 1, 2, ..., n)
	Y *big.Int // Polynomial value at X
}

// NodePackage is what each DAC node receives during dispersal.
// [Spec: DistributeChunks action distributes {RS chunk, Shamir key share, KZG proof}]
type NodePackage struct {
	NodeID     NodeID
	BatchID    uint64
	Chunk      EncodedChunk // RS-encoded ciphertext chunk
	KeyShare   ShamirShare  // Shamir share of AES-256 key
	DataHash   [32]byte     // SHA-256 of original plaintext
	CipherHash [32]byte     // SHA-256 of full ciphertext
}

// Attestation is a node's signed confirmation of data availability.
// [Spec: attested variable tracks which nodes have attested per batch]
type Attestation struct {
	NodeID    NodeID
	BatchID   uint64
	DataHash  [32]byte
	Signature []byte    // ECDSA secp256k1 signature (65 bytes: R||S||V)
	Timestamp time.Time
}

// DACCertificate is the aggregated attestation for on-chain submission.
// [Spec: ProduceCertificate action -- requires |attested[b]| >= Threshold]
type DACCertificate struct {
	BatchID      uint64
	DataHash     [32]byte
	Attestations []Attestation
	SignerBitmap uint8     // Bitmap of signing nodes (bit i = node i attested)
	Timestamp    time.Time
}

// BatchInfo stores metadata needed for recovery verification.
type BatchInfo struct {
	DataHash     [32]byte // SHA-256 of original plaintext
	CipherHash   [32]byte // SHA-256 of full ciphertext
	OriginalSize int      // Original data size (needed for RS decode padding trim)
}

// DispersalResult captures the outcome and timing of a dispersal operation.
type DispersalResult struct {
	BatchID       uint64
	EncodeTime    time.Duration
	KeyShareTime  time.Duration
	DistributeTime time.Duration
	VerifyTime    time.Duration
	AttestTime    time.Duration
	CertifyTime   time.Duration
	TotalTime     time.Duration
	NodesReceived int
	NodesVerified int
	NodesAttested int
	Certificate   *DACCertificate
	CertState     CertState
	FallbackData  []byte // Raw data if fallback triggered (validium -> rollup)
	Err           error
}

// RecoveryResult captures the outcome and timing of a recovery operation.
type RecoveryResult struct {
	BatchID        uint64
	CollectTime    time.Duration
	RSDecodeTime   time.Duration
	KeyRecoverTime time.Duration
	DecryptTime    time.Duration
	VerifyTime     time.Duration
	TotalTime      time.Duration
	ChunksUsed     int
	SharesUsed     int
	DataSize       int
	State          RecoveryState
	Err            error
}

// DACNode represents a single DAC committee member with persistent storage.
// [Spec: Models nodeOnline, distributedTo, chunkVerified, attested per node]
type DACNode struct {
	ID         NodeID
	PrivateKey *ecdsa.PrivateKey
	PublicKey  *ecdsa.PublicKey

	mu       sync.RWMutex
	online   bool
	stored   map[uint64]*NodePackage // persistent storage: batchID -> package
	verified map[uint64]bool         // verification gate: batchID -> verified
	attested map[uint64]bool         // attestation record: batchID -> attested
}

// Committee orchestrates the DAC protocol across all member nodes.
// [Spec: Top-level ProductionDAC module with all actions]
type Committee struct {
	Config  Config
	Nodes   []*DACNode
	encoder *RSEncoder

	mu        sync.RWMutex
	certState map[uint64]CertState      // [Spec: certState variable]
	certs     map[uint64]*DACCertificate // stored certificates
	batchInfo map[uint64]*BatchInfo      // metadata for recovery
	fallback  map[uint64][]byte          // fallback data per batch
}
