// Package dac implements the production Data Availability Committee protocol
// for the Basis Network enterprise zkEVM L2.
//
// Architecture: Hybrid AES-256-GCM encryption + Reed-Solomon erasure coding + Shamir key sharing.
// This combines computational privacy (AES), storage-efficient redundancy (RS), and
// information-theoretic key secrecy (Shamir) into a production-grade DAC protocol.
package dac

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"math/big"
	"sync"
	"time"

	"github.com/basis-network/zkl2-production-dac/erasure"
	"github.com/basis-network/zkl2-production-dac/shamir"
)

// NodeID identifies a DAC member.
type NodeID int

// NodeStatus represents the operational state of a DAC node.
type NodeStatus int

const (
	NodeOnline  NodeStatus = iota
	NodeOffline
	NodeMalicious
)

// DACConfig holds the full DAC configuration.
type DACConfig struct {
	Erasure         erasure.Config
	Shamir          shamir.Config
	AttestThreshold int           // Minimum signatures for valid attestation
	AttestTimeout   time.Duration // Maximum time to wait for attestation
}

// DefaultDACConfig returns the production (5,7) configuration.
func DefaultDACConfig() DACConfig {
	return DACConfig{
		Erasure:         erasure.DefaultConfig(),
		Shamir:          shamir.DefaultConfig(),
		AttestThreshold: 5,
		AttestTimeout:   1 * time.Second,
	}
}

// NodePackage is what each DAC node receives during dispersal.
type NodePackage struct {
	NodeID     NodeID
	Chunk      erasure.EncodedChunk
	KeyShare   shamir.Share
	DataHash   [32]byte // Hash of original plaintext
	CipherHash [32]byte // Hash of full ciphertext
	BatchID    uint64
}

// Attestation is a single node's signed confirmation of data availability.
type Attestation struct {
	NodeID    NodeID
	BatchID   uint64
	DataHash  [32]byte
	Signature []byte // ECDSA signature over (batchID || dataHash)
	Timestamp time.Time
}

// Certificate is the aggregated attestation submitted on-chain.
type Certificate struct {
	BatchID      uint64
	DataHash     [32]byte
	Attestations []Attestation
	SignerBitmap uint8 // Bitmap of which nodes signed (bit i = node i)
	Timestamp    time.Time
}

// Node simulates a DAC member node.
type Node struct {
	ID         NodeID
	Status     NodeStatus
	PrivateKey *ecdsa.PrivateKey
	PublicKey  *ecdsa.PublicKey
	stored     map[uint64]*NodePackage // batchID -> package
	mu         sync.RWMutex
}

// GetStored returns the stored package for a given batchID, if any.
func (n *Node) GetStored(batchID uint64) (*NodePackage, bool) {
	n.mu.RLock()
	defer n.mu.RUnlock()
	pkg, ok := n.stored[batchID]
	return pkg, ok
}

// Committee is the full DAC with all members and the encoding infrastructure.
type Committee struct {
	Config  DACConfig
	Nodes   []*Node
	Encoder *erasure.Encoder
}

// NewCommittee creates a new DAC with n nodes.
func NewCommittee(config DACConfig) (*Committee, error) {
	encoder, err := erasure.NewEncoder(config.Erasure)
	if err != nil {
		return nil, fmt.Errorf("create encoder: %w", err)
	}

	nodes := make([]*Node, config.Erasure.TotalShards())
	for i := range nodes {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return nil, fmt.Errorf("generate node key: %w", err)
		}
		nodes[i] = &Node{
			ID:         NodeID(i),
			Status:     NodeOnline,
			PrivateKey: key,
			PublicKey:  &key.PublicKey,
			stored:     make(map[uint64]*NodePackage),
		}
	}

	return &Committee{
		Config:  config,
		Nodes:   nodes,
		Encoder: encoder,
	}, nil
}

// DispersalResult contains timing and success information from a dispersal.
type DispersalResult struct {
	BatchID         uint64
	EncryptionTime  time.Duration
	EncodingTime    time.Duration
	KeyShareTime    time.Duration
	DistributionTime time.Duration
	AttestationTime  time.Duration
	TotalTime       time.Duration
	Certificate     *Certificate
	NodesReceived   int
	NodesAttested   int
	Success         bool
	Error           string
}

// Disperse encrypts, encodes, distributes, and collects attestations for a batch.
func (c *Committee) Disperse(batchID uint64, data []byte) *DispersalResult {
	result := &DispersalResult{BatchID: batchID}
	totalStart := time.Now()

	// Step 1: Encode (encrypt + RS encode)
	encStart := time.Now()
	encoded, aesKey, err := c.Encoder.Encode(data)
	if err != nil {
		result.Error = fmt.Sprintf("encode: %v", err)
		result.TotalTime = time.Since(totalStart)
		return result
	}
	result.EncryptionTime = time.Since(encStart) // Includes both AES + RS
	result.EncodingTime = result.EncryptionTime   // Combined for now

	// Step 2: Shamir share the AES key
	keyStart := time.Now()
	keyShares, err := shamir.Split(aesKey, c.Config.Shamir)
	if err != nil {
		result.Error = fmt.Sprintf("key share: %v", err)
		result.TotalTime = time.Since(totalStart)
		return result
	}
	result.KeyShareTime = time.Since(keyStart)

	// Step 3: Distribute to nodes
	distStart := time.Now()
	packages := make([]*NodePackage, len(c.Nodes))
	for i, node := range c.Nodes {
		pkg := &NodePackage{
			NodeID:     node.ID,
			Chunk:      encoded.Chunks[i],
			KeyShare:   keyShares[i],
			DataHash:   encoded.DataHash,
			CipherHash: encoded.CipherHash,
			BatchID:    batchID,
		}
		packages[i] = pkg

		if node.Status == NodeOnline {
			node.mu.Lock()
			node.stored[batchID] = pkg
			node.mu.Unlock()
			result.NodesReceived++
		}
		// Offline and malicious nodes do not receive/store
	}
	result.DistributionTime = time.Since(distStart)

	// Step 4: Collect attestations
	attestStart := time.Now()
	attestations := make([]Attestation, 0, len(c.Nodes))
	var signerBitmap uint8

	for _, node := range c.Nodes {
		if node.Status != NodeOnline {
			continue
		}

		att, err := node.attest(batchID, encoded.DataHash)
		if err != nil {
			continue
		}
		attestations = append(attestations, *att)
		signerBitmap |= 1 << uint(node.ID)
	}
	result.AttestationTime = time.Since(attestStart)
	result.NodesAttested = len(attestations)

	// Step 5: Build certificate
	if len(attestations) >= c.Config.AttestThreshold {
		result.Certificate = &Certificate{
			BatchID:      batchID,
			DataHash:     encoded.DataHash,
			Attestations: attestations,
			SignerBitmap: signerBitmap,
			Timestamp:    time.Now(),
		}
		result.Success = true
	} else {
		result.Error = fmt.Sprintf("insufficient attestations: %d < %d",
			len(attestations), c.Config.AttestThreshold)
	}

	result.TotalTime = time.Since(totalStart)
	return result
}

// RecoveryResult contains timing and success information from a recovery.
type RecoveryResult struct {
	BatchID        uint64
	ChunkCollect   time.Duration
	RSDecodeTime   time.Duration
	KeyRecoverTime time.Duration
	DecryptTime    time.Duration
	TotalTime      time.Duration
	DataSize       int
	ChunksUsed     int
	KeySharesUsed  int
	Success        bool
	Error          string
}

// Recover reconstructs the original data from available node chunks and key shares.
func (c *Committee) Recover(batchID uint64, originalSize int) ([]byte, *RecoveryResult) {
	result := &RecoveryResult{BatchID: batchID}
	totalStart := time.Now()

	// Step 1: Collect chunks and key shares from available nodes
	collectStart := time.Now()
	shards := make([][]byte, len(c.Nodes))
	keyShares := make([]shamir.Share, 0, len(c.Nodes))

	for i, node := range c.Nodes {
		if node.Status != NodeOnline {
			shards[i] = nil // Mark as missing
			continue
		}

		node.mu.RLock()
		pkg, exists := node.stored[batchID]
		node.mu.RUnlock()

		if !exists {
			shards[i] = nil
			continue
		}

		shards[i] = make([]byte, len(pkg.Chunk.Data))
		copy(shards[i], pkg.Chunk.Data)
		keyShares = append(keyShares, pkg.KeyShare)
		result.ChunksUsed++
		result.KeySharesUsed++
	}
	result.ChunkCollect = time.Since(collectStart)

	// Check thresholds
	if result.ChunksUsed < c.Config.Erasure.DataShards {
		result.Error = fmt.Sprintf("insufficient chunks: %d < %d",
			result.ChunksUsed, c.Config.Erasure.DataShards)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}
	if result.KeySharesUsed < c.Config.Shamir.Threshold {
		result.Error = fmt.Sprintf("insufficient key shares: %d < %d",
			result.KeySharesUsed, c.Config.Shamir.Threshold)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}

	// Step 2: Recover AES key from Shamir shares
	keyStart := time.Now()
	selectedShares := keyShares[:c.Config.Shamir.Threshold]
	aesKey, err := shamir.Recover(selectedShares)
	if err != nil {
		result.Error = fmt.Sprintf("key recovery: %v", err)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}
	result.KeyRecoverTime = time.Since(keyStart)

	// Step 3: RS decode
	rsStart := time.Now()
	data, err := c.Encoder.Decode(shards, aesKey, originalSize)
	if err != nil {
		result.Error = fmt.Sprintf("decode: %v", err)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}
	result.RSDecodeTime = time.Since(rsStart)
	result.DataSize = len(data)

	result.TotalTime = time.Since(totalStart)
	result.Success = true
	return data, result
}

// StorageOverhead returns the storage overhead ratio for the current configuration.
func (c *Committee) StorageOverhead(dataSize int) float64 {
	// Each node stores: 1 shard of size ceil(dataSize/k) + 28 bytes AES overhead padding
	// Plus key share (~64 bytes) and hash (~32 bytes)
	shardSize := (dataSize + 28) / c.Config.Erasure.DataShards
	if (dataSize+28)%c.Config.Erasure.DataShards != 0 {
		shardSize++
	}
	perNodeStorage := shardSize + 64 + 32 // shard + key share + hash
	totalStorage := perNodeStorage * c.Config.Erasure.TotalShards()
	return float64(totalStorage) / float64(dataSize)
}

// SetNodeStatus changes a node's operational status.
func (c *Committee) SetNodeStatus(nodeID NodeID, status NodeStatus) {
	if int(nodeID) < len(c.Nodes) {
		c.Nodes[int(nodeID)].Status = status
	}
}

// OnlineCount returns the number of online nodes.
func (c *Committee) OnlineCount() int {
	count := 0
	for _, node := range c.Nodes {
		if node.Status == NodeOnline {
			count++
		}
	}
	return count
}

// attest signs a data availability attestation.
func (n *Node) attest(batchID uint64, dataHash [32]byte) (*Attestation, error) {
	// Create message to sign: SHA-256(batchID || dataHash)
	msg := make([]byte, 8+32)
	for i := 0; i < 8; i++ {
		msg[i] = byte(batchID >> (56 - 8*i))
	}
	copy(msg[8:], dataHash[:])
	hash := sha256.Sum256(msg)

	// Sign with ECDSA
	r, s, err := ecdsa.Sign(rand.Reader, n.PrivateKey, hash[:])
	if err != nil {
		return nil, fmt.Errorf("sign: %w", err)
	}

	sig := append(r.Bytes(), s.Bytes()...)

	return &Attestation{
		NodeID:    n.ID,
		BatchID:   batchID,
		DataHash:  dataHash,
		Signature: sig,
		Timestamp: time.Now(),
	}, nil
}

// VerifyCertificate checks that a certificate has enough valid signatures.
func (c *Committee) VerifyCertificate(cert *Certificate) (bool, int) {
	validCount := 0
	for _, att := range cert.Attestations {
		node := c.Nodes[int(att.NodeID)]

		// Recreate message
		msg := make([]byte, 8+32)
		for i := 0; i < 8; i++ {
			msg[i] = byte(att.BatchID >> (56 - 8*i))
		}
		copy(msg[8:], att.DataHash[:])
		hash := sha256.Sum256(msg)

		// Verify ECDSA signature
		sigLen := len(att.Signature) / 2
		r := new(big.Int).SetBytes(att.Signature[:sigLen])
		s := new(big.Int).SetBytes(att.Signature[sigLen:])

		if ecdsa.Verify(node.PublicKey, hash[:], r, s) {
			validCount++
		}
	}

	return validCount >= c.Config.AttestThreshold, validCount
}

// AvailabilityProbability calculates the probability that at least k of n nodes
// are available, given per-node availability p.
func AvailabilityProbability(k, n int, p float64) float64 {
	prob := 0.0
	for i := k; i <= n; i++ {
		prob += binomialPMF(n, i, p)
	}
	return prob
}

// binomialPMF computes C(n,k) * p^k * (1-p)^(n-k).
func binomialPMF(n, k int, p float64) float64 {
	coeff := binomialCoeff(n, k)
	pk := 1.0
	for i := 0; i < k; i++ {
		pk *= p
	}
	qnk := 1.0
	for i := 0; i < n-k; i++ {
		qnk *= (1 - p)
	}
	return float64(coeff) * pk * qnk
}

// binomialCoeff computes C(n,k).
func binomialCoeff(n, k int) int64 {
	if k > n-k {
		k = n - k
	}
	result := int64(1)
	for i := 0; i < k; i++ {
		result = result * int64(n-i) / int64(i+1)
	}
	return result
}
