package da

import (
	"crypto/sha256"
	"fmt"
	"time"
)

// Recover attempts data recovery from available online nodes.
// Three-step process: RS-decode -> Shamir key recovery -> AES-GCM decrypt -> hash verify.
//
// Recovery outcomes map to TLA+ recoverState:
//   - RecoverySuccess: >= threshold uncorrupted chunks, decrypt succeeds, hash matches
//   - RecoveryCorrupted: >= threshold chunks but corruption detected (AES-GCM auth fails)
//   - RecoveryFailed: < threshold chunks or shares available
//
// [Spec: RecoverData(b, S) action -- guards: certState="valid", recoverState="none"]
func (c *Committee) Recover(batchID uint64) ([]byte, *RecoveryResult) {
	result := &RecoveryResult{BatchID: batchID}
	totalStart := time.Now()

	// Verify prerequisites.
	c.mu.RLock()
	certState := c.certState[batchID]
	info, hasInfo := c.batchInfo[batchID]
	c.mu.RUnlock()

	if certState != CertValid {
		result.State = RecoveryFailed
		result.Err = fmt.Errorf("%w: batch %d, certState=%s", ErrNoCertificate, batchID, certState)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}

	if !hasInfo {
		result.State = RecoveryFailed
		result.Err = fmt.Errorf("%w: no batch info for batch %d", ErrBatchNotDistributed, batchID)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}

	// Step 1: Collect RS chunks and Shamir key shares from online nodes.
	// [Spec: S subset {n : nodeOnline[n] /\ n in distributedTo[b]}]
	collectStart := time.Now()
	totalShards := c.Config.DataShards + c.Config.ParityShards
	shards := make([][]byte, totalShards)
	keyShares := make([]ShamirShare, 0, totalShards)

	for i, node := range c.Nodes {
		chunk, err := node.GetChunk(batchID)
		if err != nil {
			shards[i] = nil
			continue
		}

		share, err := node.GetKeyShare(batchID)
		if err != nil {
			shards[i] = nil
			continue
		}

		shards[i] = chunk
		keyShares = append(keyShares, *share)
		result.ChunksUsed++
		result.SharesUsed++
	}
	result.CollectTime = time.Since(collectStart)

	// Check thresholds.
	// [Spec: |S| < Threshold => recoverState = "failed"]
	if result.ChunksUsed < c.Config.DataShards {
		result.State = RecoveryFailed
		result.Err = fmt.Errorf("%w: need %d chunks, have %d",
			ErrInsufficientShards, c.Config.DataShards, result.ChunksUsed)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}
	if result.SharesUsed < c.Config.Threshold {
		result.State = RecoveryFailed
		result.Err = fmt.Errorf("%w: need %d shares, have %d",
			ErrInsufficientShares, c.Config.Threshold, result.SharesUsed)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}

	// Step 2: Recover AES key from Shamir shares.
	// [Spec: Shamir-recover(key) from k shares]
	keyStart := time.Now()
	selectedShares := keyShares[:c.Config.Threshold]
	aesKey, err := ShamirRecover(selectedShares)
	if err != nil {
		result.State = RecoveryFailed
		result.Err = fmt.Errorf("shamir recover: %w", err)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}
	result.KeyRecoverTime = time.Since(keyStart)

	// Step 3: RS decode to recover ciphertext, then AES-GCM decrypt.
	// AES-GCM authentication tag detects corruption automatically.
	// [Spec: S /\ chunkCorrupted[b] /= {} => recoverState = "corrupted"]
	decStart := time.Now()
	data, err := c.encoder.Decode(shards, aesKey, info.OriginalSize)
	if err != nil {
		result.State = RecoveryCorrupted
		result.Err = fmt.Errorf("%w: %v", ErrCorruptedData, err)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}
	result.DecryptTime = time.Since(decStart)

	// Step 4: Verify recovered data hash matches expected.
	// [Spec: RecoveryIntegrity -- success => all contributing nodes have authentic data]
	verifyStart := time.Now()
	recoveredHash := sha256.Sum256(data)
	if recoveredHash != info.DataHash {
		result.State = RecoveryCorrupted
		result.Err = fmt.Errorf("%w: expected %x, got %x",
			ErrHashMismatch, info.DataHash[:8], recoveredHash[:8])
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}
	result.VerifyTime = time.Since(verifyStart)

	result.DataSize = len(data)
	result.State = RecoverySuccess
	result.TotalTime = time.Since(totalStart)
	return data, result
}

// RecoverFrom attempts recovery using only the specified subset of nodes.
// This allows testing recovery with specific node combinations.
func (c *Committee) RecoverFrom(batchID uint64, nodeIDs []NodeID) ([]byte, *RecoveryResult) {
	result := &RecoveryResult{BatchID: batchID}
	totalStart := time.Now()

	c.mu.RLock()
	certState := c.certState[batchID]
	info, hasInfo := c.batchInfo[batchID]
	c.mu.RUnlock()

	if certState != CertValid {
		result.State = RecoveryFailed
		result.Err = fmt.Errorf("%w: batch %d", ErrNoCertificate, batchID)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}

	if !hasInfo {
		result.State = RecoveryFailed
		result.Err = fmt.Errorf("%w: batch %d", ErrBatchNotDistributed, batchID)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}

	// Collect from specified nodes only.
	collectStart := time.Now()
	totalShards := c.Config.DataShards + c.Config.ParityShards
	shards := make([][]byte, totalShards)
	keyShares := make([]ShamirShare, 0, len(nodeIDs))

	nodeIDSet := make(map[NodeID]bool, len(nodeIDs))
	for _, id := range nodeIDs {
		nodeIDSet[id] = true
	}

	for i, node := range c.Nodes {
		if !nodeIDSet[node.ID] {
			shards[i] = nil
			continue
		}

		chunk, err := node.GetChunk(batchID)
		if err != nil {
			shards[i] = nil
			continue
		}

		share, err := node.GetKeyShare(batchID)
		if err != nil {
			shards[i] = nil
			continue
		}

		shards[i] = chunk
		keyShares = append(keyShares, *share)
		result.ChunksUsed++
		result.SharesUsed++
	}
	result.CollectTime = time.Since(collectStart)

	if result.ChunksUsed < c.Config.DataShards {
		result.State = RecoveryFailed
		result.Err = fmt.Errorf("%w: need %d, have %d",
			ErrInsufficientShards, c.Config.DataShards, result.ChunksUsed)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}
	if result.SharesUsed < c.Config.Threshold {
		result.State = RecoveryFailed
		result.Err = fmt.Errorf("%w: need %d, have %d",
			ErrInsufficientShares, c.Config.Threshold, result.SharesUsed)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}

	keyStart := time.Now()
	selectedShares := keyShares[:c.Config.Threshold]
	aesKey, err := ShamirRecover(selectedShares)
	if err != nil {
		result.State = RecoveryFailed
		result.Err = fmt.Errorf("shamir recover: %w", err)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}
	result.KeyRecoverTime = time.Since(keyStart)

	decStart := time.Now()
	data, err := c.encoder.Decode(shards, aesKey, info.OriginalSize)
	if err != nil {
		result.State = RecoveryCorrupted
		result.Err = fmt.Errorf("%w: %v", ErrCorruptedData, err)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}
	result.DecryptTime = time.Since(decStart)

	verifyStart := time.Now()
	recoveredHash := sha256.Sum256(data)
	if recoveredHash != info.DataHash {
		result.State = RecoveryCorrupted
		result.Err = fmt.Errorf("%w: hash mismatch", ErrHashMismatch)
		result.TotalTime = time.Since(totalStart)
		return nil, result
	}
	result.VerifyTime = time.Since(verifyStart)

	result.DataSize = len(data)
	result.State = RecoverySuccess
	result.TotalTime = time.Since(totalStart)
	return data, result
}
