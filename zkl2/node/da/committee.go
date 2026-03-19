package da

import (
	"fmt"
	"time"

	ethcrypto "github.com/ethereum/go-ethereum/crypto"
)

// NewCommittee creates a new DAC with n nodes, each with a fresh secp256k1 key pair.
// [Spec: Init state -- all nodes online, no distributions, no attestations]
func NewCommittee(config Config) (*Committee, error) {
	encoder, err := NewRSEncoder(config.DataShards, config.ParityShards)
	if err != nil {
		return nil, fmt.Errorf("create rs encoder: %w", err)
	}

	nodes := make([]*DACNode, config.Total)
	for i := range nodes {
		key, err := ethcrypto.GenerateKey()
		if err != nil {
			return nil, fmt.Errorf("generate node %d key: %w", i, err)
		}
		nodes[i] = NewDACNode(NodeID(i), key)
	}

	return &Committee{
		Config:    config,
		Nodes:     nodes,
		encoder:   encoder,
		certState: make(map[uint64]CertState),
		certs:     make(map[uint64]*DACCertificate),
		batchInfo: make(map[uint64]*BatchInfo),
		fallback:  make(map[uint64][]byte),
	}, nil
}

// Disperse executes the full dispersal protocol for a batch:
// encrypt -> RS-encode -> Shamir-share -> distribute -> verify -> attest -> certify.
// [Spec: Sequence of actions: DistributeChunks -> VerifyChunk -> NodeAttest -> ProduceCertificate/TriggerFallback]
func (c *Committee) Disperse(batchID uint64, data []byte) *DispersalResult {
	result := &DispersalResult{BatchID: batchID}
	totalStart := time.Now()

	// Step 1: Encode (AES-256-GCM encrypt + RS encode).
	encStart := time.Now()
	encoded, aesKey, err := c.encoder.Encode(data)
	if err != nil {
		result.Err = fmt.Errorf("encode: %w", err)
		result.TotalTime = time.Since(totalStart)
		return result
	}
	result.EncodeTime = time.Since(encStart)

	// Store batch metadata for recovery.
	c.mu.Lock()
	c.batchInfo[batchID] = &BatchInfo{
		DataHash:     encoded.DataHash,
		CipherHash:   encoded.CipherHash,
		OriginalSize: encoded.OriginalSize,
	}
	c.mu.Unlock()

	// Step 2: Shamir-share the AES key.
	keyStart := time.Now()
	keyShares, err := ShamirSplit(aesKey, c.Config.Threshold, c.Config.Total)
	if err != nil {
		result.Err = fmt.Errorf("shamir split: %w", err)
		result.TotalTime = time.Since(totalStart)
		return result
	}
	result.KeyShareTime = time.Since(keyStart)

	// Step 3: Distribute packages to online nodes.
	// [Spec: DistributeChunks(b) -- distributedTo[b] <- {n : nodeOnline[n]}]
	distStart := time.Now()
	for i, node := range c.Nodes {
		pkg := &NodePackage{
			NodeID:     node.ID,
			BatchID:    batchID,
			Chunk:      encoded.Chunks[i],
			KeyShare:   keyShares[i],
			DataHash:   encoded.DataHash,
			CipherHash: encoded.CipherHash,
		}
		if err := node.Receive(pkg); err == nil {
			result.NodesReceived++
		}
	}
	result.DistributeTime = time.Since(distStart)

	// Check fallback condition: distributed to fewer than threshold nodes.
	// [Spec: TriggerFallback(b) -- |distributedTo[b]| < Threshold]
	if result.NodesReceived < c.Config.Threshold {
		result.CertState = CertFallback
		c.mu.Lock()
		c.certState[batchID] = CertFallback
		c.fallback[batchID] = data
		c.mu.Unlock()
		result.FallbackData = data
		result.Err = fmt.Errorf("%w: only %d of %d nodes received",
			ErrFallbackActive, result.NodesReceived, c.Config.Threshold)
		result.TotalTime = time.Since(totalStart)
		return result
	}

	// Step 4: Each node verifies its chunk (KZG verification gate).
	// [Spec: VerifyChunk(n, b) -- node verifies RS chunk against commitment]
	verifyStart := time.Now()
	for _, node := range c.Nodes {
		if err := node.Verify(batchID); err == nil {
			result.NodesVerified++
		}
	}
	result.VerifyTime = time.Since(verifyStart)

	// Step 5: Each verified node attests.
	// [Spec: NodeAttest(n, b) -- only after VerifyChunk succeeds]
	attestStart := time.Now()
	attestations := make([]Attestation, 0, len(c.Nodes))
	for _, node := range c.Nodes {
		att, err := node.Attest(batchID)
		if err == nil {
			attestations = append(attestations, *att)
		}
	}
	result.AttestTime = time.Since(attestStart)
	result.NodesAttested = len(attestations)

	// Step 6: Produce certificate if threshold met.
	// [Spec: ProduceCertificate(b) -- |attested[b]| >= Threshold]
	certStart := time.Now()
	if len(attestations) >= c.Config.Threshold {
		cert, err := c.ProduceCertificate(batchID, attestations)
		if err != nil {
			result.Err = fmt.Errorf("produce certificate: %w", err)
		} else {
			result.Certificate = cert
			result.CertState = CertValid
		}
	} else {
		result.Err = fmt.Errorf("%w: %d attestations, need %d",
			ErrInsufficientAttestations, len(attestations), c.Config.Threshold)
	}
	result.CertifyTime = time.Since(certStart)

	result.TotalTime = time.Since(totalStart)
	return result
}

// OnlineCount returns the number of currently online nodes.
func (c *Committee) OnlineCount() int {
	count := 0
	for _, node := range c.Nodes {
		if node.IsOnline() {
			count++
		}
	}
	return count
}

// SetNodeOnline brings a node back online.
// [Spec: NodeRecover(n)]
func (c *Committee) SetNodeOnline(nodeID NodeID) {
	if int(nodeID) < len(c.Nodes) {
		c.Nodes[int(nodeID)].SetOnline()
	}
}

// SetNodeOffline takes a node offline.
// [Spec: NodeFail(n)]
func (c *Committee) SetNodeOffline(nodeID NodeID) {
	if int(nodeID) < len(c.Nodes) {
		c.Nodes[int(nodeID)].SetOffline()
	}
}

// ReplaceNode rotates a committee member. The new node gets a fresh key pair.
// Used for committee rotation (e.g., removing a malicious member).
func (c *Committee) ReplaceNode(nodeID NodeID) error {
	if int(nodeID) >= len(c.Nodes) {
		return fmt.Errorf("node %d out of range", nodeID)
	}

	key, err := ethcrypto.GenerateKey()
	if err != nil {
		return fmt.Errorf("generate replacement key: %w", err)
	}

	c.Nodes[int(nodeID)] = NewDACNode(nodeID, key)
	return nil
}

// StorageOverhead returns the total storage overhead ratio for the current config.
// For (5,7) RS: 7 * (dataSize/5) / dataSize = 1.4x.
func (c *Committee) StorageOverhead(dataSize int) float64 {
	shardSize := (dataSize + AESGCMOverhead) / c.Config.DataShards
	if (dataSize+AESGCMOverhead)%c.Config.DataShards != 0 {
		shardSize++
	}
	perNodeStorage := shardSize + 64 + 32 // shard + key share + hash
	totalStorage := perNodeStorage * c.Config.Total
	return float64(totalStorage) / float64(dataSize)
}
