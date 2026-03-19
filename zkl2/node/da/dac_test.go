package da

import (
	"bytes"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"sync"
	"testing"
)

// testData generates deterministic test data of the given size.
func testData(size int) []byte {
	data := make([]byte, size)
	if _, err := rand.Read(data); err != nil {
		panic(err)
	}
	return data
}

// newTestCommittee creates a committee with default (5,7) config for testing.
func newTestCommittee(t *testing.T) *Committee {
	t.Helper()
	c, err := NewCommittee(DefaultConfig())
	if err != nil {
		t.Fatalf("NewCommittee: %v", err)
	}
	return c
}

// disperseAndVerify runs a full dispersal and checks success.
func disperseAndVerify(t *testing.T, c *Committee, batchID uint64, data []byte) *DispersalResult {
	t.Helper()
	result := c.Disperse(batchID, data)
	if result.Err != nil {
		t.Fatalf("Disperse batch %d: %v", batchID, result.Err)
	}
	if result.Certificate == nil {
		t.Fatalf("Disperse batch %d: no certificate produced", batchID)
	}
	if result.CertState != CertValid {
		t.Fatalf("Disperse batch %d: cert state %s, want valid", batchID, result.CertState)
	}
	return result
}

// =============================================================================
// TLA+ INVARIANT TESTS
// =============================================================================

// TestCertificateSoundness verifies that a valid DACCertificate can only exist
// when >= Threshold nodes have attested.
// [Spec: CertificateSoundness invariant in ProductionDAC.tla]
func TestCertificateSoundness(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(1024)

	result := c.Disperse(1, data)
	if result.Err != nil {
		t.Fatalf("Disperse: %v", result.Err)
	}

	cert := result.Certificate
	if cert == nil {
		t.Fatal("expected certificate")
	}

	if len(cert.Attestations) < c.Config.Threshold {
		t.Errorf("CertificateSoundness violated: %d attestations < threshold %d",
			len(cert.Attestations), c.Config.Threshold)
	}

	// Verify certificate is valid.
	if err := c.VerifyCertificate(cert); err != nil {
		t.Errorf("certificate verification failed: %v", err)
	}
}

// TestDataRecoverability verifies that recovery succeeds when >= Threshold
// honest nodes with authentic chunks/shares are available.
// [Spec: DataRecoverability invariant in ProductionDAC.tla]
func TestDataRecoverability(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(4096)

	disperseAndVerify(t, c, 1, data)

	recovered, result := c.Recover(1)
	if result.State != RecoverySuccess {
		t.Fatalf("recovery state: %s, err: %v", result.State, result.Err)
	}

	if !bytes.Equal(recovered, data) {
		t.Error("DataRecoverability violated: recovered data does not match original")
	}
}

// TestErasureSoundness verifies that corrupted chunks are detected during recovery.
// [Spec: ErasureSoundness invariant -- corruption detected by commitment check]
func TestErasureSoundness(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(2048)

	disperseAndVerify(t, c, 1, data)

	// Corrupt 3 nodes' chunks (exceeds parity capacity of 2).
	for i := 0; i < 3; i++ {
		if err := c.Nodes[i].CorruptChunk(1); err != nil {
			t.Fatalf("corrupt node %d: %v", i, err)
		}
	}

	_, result := c.Recover(1)
	if result.State != RecoveryCorrupted {
		t.Errorf("ErasureSoundness violated: expected corrupted state, got %s", result.State)
	}
}

// TestPrivacy verifies that successful recovery requires >= Threshold participants.
// [Spec: Privacy invariant -- success => |recoveryNodes[b]| >= Threshold]
func TestPrivacy(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(1024)

	disperseAndVerify(t, c, 1, data)

	// Take 3 nodes offline, leaving only 4 (below threshold of 5).
	for i := 0; i < 3; i++ {
		c.SetNodeOffline(NodeID(i))
	}

	_, result := c.Recover(1)
	if result.State != RecoveryFailed {
		t.Errorf("Privacy violated: recovery succeeded with only %d nodes (threshold %d)",
			result.ChunksUsed, c.Config.Threshold)
	}

	if !errors.Is(result.Err, ErrInsufficientShards) {
		t.Errorf("expected ErrInsufficientShards, got: %v", result.Err)
	}
}

// TestRecoveryIntegrity verifies that successful recovery implies all
// contributing nodes have authentic (non-corrupted) data.
// [Spec: RecoveryIntegrity invariant -- success => recoveryNodes /\ chunkCorrupted = {}]
func TestRecoveryIntegrity(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(2048)

	disperseAndVerify(t, c, 1, data)

	// Corrupt 1 node, take it offline so it's excluded from recovery.
	if err := c.Nodes[0].CorruptChunk(1); err != nil {
		t.Fatalf("corrupt: %v", err)
	}
	c.SetNodeOffline(NodeID(0))

	// Recovery should succeed using only 6 uncorrupted nodes.
	recovered, result := c.Recover(1)
	if result.State != RecoverySuccess {
		t.Fatalf("recovery state: %s, err: %v", result.State, result.Err)
	}

	if !bytes.Equal(recovered, data) {
		t.Error("RecoveryIntegrity violated: recovered data does not match original")
	}
}

// TestAttestationIntegrity verifies that only nodes which have verified their
// chunk can produce attestations.
// [Spec: AttestationIntegrity invariant -- attested[b] subset chunkVerified[b]]
func TestAttestationIntegrity(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(512)

	// Manually distribute without auto-verify/attest.
	encoded, aesKey, err := c.encoder.Encode(data)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	_ = aesKey

	keyShares, err := ShamirSplit(aesKey, c.Config.Threshold, c.Config.Total)
	if err != nil {
		t.Fatalf("shamir split: %v", err)
	}

	// Distribute to all nodes.
	for i, node := range c.Nodes {
		pkg := &NodePackage{
			NodeID:     node.ID,
			BatchID:    1,
			Chunk:      encoded.Chunks[i],
			KeyShare:   keyShares[i],
			DataHash:   encoded.DataHash,
			CipherHash: encoded.CipherHash,
		}
		if err := node.Receive(pkg); err != nil {
			t.Fatalf("receive node %d: %v", i, err)
		}
	}

	// Try to attest without verifying -- should fail.
	_, err = c.Nodes[0].Attest(1)
	if !errors.Is(err, ErrNodeNotVerified) {
		t.Errorf("AttestationIntegrity violated: attest without verify returned: %v", err)
	}

	// Verify first, then attest -- should succeed.
	if err := c.Nodes[0].Verify(1); err != nil {
		t.Fatalf("verify: %v", err)
	}
	att, err := c.Nodes[0].Attest(1)
	if err != nil {
		t.Fatalf("attest after verify: %v", err)
	}
	if att == nil {
		t.Error("expected attestation after verify")
	}
}

// TestVerificationIntegrity verifies that a node cannot verify a chunk
// it never received.
// [Spec: VerificationIntegrity invariant -- chunkVerified[b] subset distributedTo[b]]
func TestVerificationIntegrity(t *testing.T) {
	c := newTestCommittee(t)

	// Node 0 has no package stored. Verify should fail.
	err := c.Nodes[0].Verify(999)
	if !errors.Is(err, ErrNodeNotDistributed) {
		t.Errorf("VerificationIntegrity violated: verify without distribution returned: %v", err)
	}
}

// =============================================================================
// SCENARIO TESTS
// =============================================================================

// TestRecoveryAllOnline tests recovery with all 7 nodes online and uncorrupted.
func TestRecoveryAllOnline(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(8192)

	disperseAndVerify(t, c, 1, data)

	recovered, result := c.Recover(1)
	if result.State != RecoverySuccess {
		t.Fatalf("recovery state: %s, err: %v", result.State, result.Err)
	}
	if result.ChunksUsed != 7 {
		t.Errorf("expected 7 chunks used, got %d", result.ChunksUsed)
	}
	if !bytes.Equal(recovered, data) {
		t.Error("recovered data mismatch")
	}
}

// TestRecoveryTwoNodesOffline tests recovery with exactly 5 of 7 nodes (at threshold).
func TestRecoveryTwoNodesOffline(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(4096)

	disperseAndVerify(t, c, 1, data)

	// Take 2 nodes offline after dispersal.
	c.SetNodeOffline(NodeID(5))
	c.SetNodeOffline(NodeID(6))

	recovered, result := c.Recover(1)
	if result.State != RecoverySuccess {
		t.Fatalf("recovery state: %s, err: %v", result.State, result.Err)
	}
	if result.ChunksUsed != 5 {
		t.Errorf("expected 5 chunks used, got %d", result.ChunksUsed)
	}
	if !bytes.Equal(recovered, data) {
		t.Error("recovered data mismatch")
	}
}

// TestRecoveryMaliciousCorruption tests recovery when one node corrupts its chunk
// after attestation. With 2 corruptions, RS parity can correct them.
func TestRecoveryMaliciousCorruption(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(2048)

	disperseAndVerify(t, c, 1, data)

	// Corrupt 1 node's chunk post-attestation.
	if err := c.Nodes[0].CorruptChunk(1); err != nil {
		t.Fatalf("corrupt: %v", err)
	}

	// Take the corrupted node offline so RS uses clean chunks.
	c.SetNodeOffline(NodeID(0))

	recovered, result := c.Recover(1)
	if result.State != RecoverySuccess {
		t.Fatalf("recovery state: %s, err: %v", result.State, result.Err)
	}
	if !bytes.Equal(recovered, data) {
		t.Error("recovered data mismatch")
	}
}

// TestInsufficientAttestations verifies that only 4 online nodes cannot produce a certificate.
func TestInsufficientAttestations(t *testing.T) {
	c := newTestCommittee(t)

	// Take 3 nodes offline before dispersal.
	c.SetNodeOffline(NodeID(4))
	c.SetNodeOffline(NodeID(5))
	c.SetNodeOffline(NodeID(6))

	data := testData(1024)
	result := c.Disperse(1, data)

	// With only 4 online nodes (< threshold 5), should trigger fallback.
	if result.CertState != CertFallback {
		t.Errorf("expected fallback, got cert state: %s", result.CertState)
	}
	if result.Certificate != nil {
		t.Error("certificate should not be produced with insufficient nodes")
	}
}

// TestAnyTrustFallback verifies the fallback mechanism when < threshold nodes
// receive the distribution.
func TestAnyTrustFallback(t *testing.T) {
	c := newTestCommittee(t)

	// Take 4 nodes offline (only 3 can receive, below threshold of 5).
	for i := 3; i < 7; i++ {
		c.SetNodeOffline(NodeID(i))
	}

	data := testData(2048)
	result := c.Disperse(1, data)

	if result.CertState != CertFallback {
		t.Fatalf("expected fallback, got: %s", result.CertState)
	}
	if !errors.Is(result.Err, ErrFallbackActive) {
		t.Errorf("expected ErrFallbackActive, got: %v", result.Err)
	}
	if result.FallbackData == nil {
		t.Error("fallback data should be set")
	}
	if !bytes.Equal(result.FallbackData, data) {
		t.Error("fallback data mismatch")
	}

	// Verify fallback state persists.
	if !c.IsFallback(1) {
		t.Error("batch should be in fallback mode")
	}

	fbData, err := c.GetFallbackData(1)
	if err != nil {
		t.Fatalf("get fallback data: %v", err)
	}
	if !bytes.Equal(fbData, data) {
		t.Error("stored fallback data mismatch")
	}
}

// TestDoubleAttestationPrevention verifies that a node cannot attest twice for the same batch.
func TestDoubleAttestationPrevention(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(512)

	// Manual flow to control attestation.
	encoded, aesKey, err := c.encoder.Encode(data)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	keyShares, err := ShamirSplit(aesKey, c.Config.Threshold, c.Config.Total)
	if err != nil {
		t.Fatalf("shamir: %v", err)
	}

	node := c.Nodes[0]
	pkg := &NodePackage{
		NodeID:     node.ID,
		BatchID:    1,
		Chunk:      encoded.Chunks[0],
		KeyShare:   keyShares[0],
		DataHash:   encoded.DataHash,
		CipherHash: encoded.CipherHash,
	}

	if err := node.Receive(pkg); err != nil {
		t.Fatalf("receive: %v", err)
	}
	if err := node.Verify(1); err != nil {
		t.Fatalf("verify: %v", err)
	}

	// First attestation should succeed.
	if _, err := node.Attest(1); err != nil {
		t.Fatalf("first attest: %v", err)
	}

	// Second attestation should fail.
	_, err = node.Attest(1)
	if !errors.Is(err, ErrAlreadyAttested) {
		t.Errorf("expected ErrAlreadyAttested, got: %v", err)
	}
}

// TestCommitteeRotation verifies that a committee member can be replaced.
func TestCommitteeRotation(t *testing.T) {
	c := newTestCommittee(t)

	oldPub := c.Nodes[2].PublicKey

	// Replace node 2.
	if err := c.ReplaceNode(NodeID(2)); err != nil {
		t.Fatalf("replace: %v", err)
	}

	newPub := c.Nodes[2].PublicKey
	if oldPub == newPub {
		t.Error("node key should have changed after rotation")
	}

	// Node should be online and empty.
	if !c.Nodes[2].IsOnline() {
		t.Error("replaced node should be online")
	}
	if c.Nodes[2].HasPackage(1) {
		t.Error("replaced node should have no stored packages")
	}

	// Dispersal should still work after rotation.
	data := testData(1024)
	disperseAndVerify(t, c, 1, data)
}

// TestKZGVerificationFailure verifies that a corrupted chunk fails the
// verification gate and prevents attestation.
func TestKZGVerificationFailure(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(1024)

	encoded, aesKey, err := c.encoder.Encode(data)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	keyShares, err := ShamirSplit(aesKey, c.Config.Threshold, c.Config.Total)
	if err != nil {
		t.Fatalf("shamir: %v", err)
	}

	node := c.Nodes[0]

	// Create package with corrupted chunk data (hash won't match).
	chunk := encoded.Chunks[0]
	corruptedData := make([]byte, len(chunk.Data))
	copy(corruptedData, chunk.Data)
	corruptedData[0] ^= 0xFF // flip a byte

	pkg := &NodePackage{
		NodeID:  node.ID,
		BatchID: 1,
		Chunk: EncodedChunk{
			Index:    chunk.Index,
			Data:     corruptedData,
			DataHash: chunk.DataHash, // Original hash -- won't match corrupted data
		},
		KeyShare:   keyShares[0],
		DataHash:   encoded.DataHash,
		CipherHash: encoded.CipherHash,
	}

	if err := node.Receive(pkg); err != nil {
		t.Fatalf("receive: %v", err)
	}

	// Verification should fail because chunk data hash doesn't match.
	err = node.Verify(1)
	if !errors.Is(err, ErrChunkVerificationFailed) {
		t.Errorf("expected ErrChunkVerificationFailed, got: %v", err)
	}

	// Attestation should fail because verification didn't pass.
	_, err = node.Attest(1)
	if !errors.Is(err, ErrNodeNotVerified) {
		t.Errorf("expected ErrNodeNotVerified after failed verification, got: %v", err)
	}
}

// TestConcurrentBatchProcessing tests that multiple batches can be dispersed
// and recovered concurrently without data races.
func TestConcurrentBatchProcessing(t *testing.T) {
	c := newTestCommittee(t)
	batchCount := 5

	batches := make([][]byte, batchCount)
	for i := range batches {
		batches[i] = testData(1024 + i*256)
	}

	// Disperse all batches concurrently.
	var wg sync.WaitGroup
	results := make([]*DispersalResult, batchCount)

	for i := 0; i < batchCount; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			results[idx] = c.Disperse(uint64(idx+1), batches[idx])
		}(i)
	}
	wg.Wait()

	// Verify all dispersals succeeded.
	for i, result := range results {
		if result.Err != nil {
			t.Errorf("batch %d dispersal failed: %v", i+1, result.Err)
		}
		if result.Certificate == nil {
			t.Errorf("batch %d: no certificate", i+1)
		}
	}

	// Recover all batches concurrently.
	recovered := make([][]byte, batchCount)
	recResults := make([]*RecoveryResult, batchCount)

	for i := 0; i < batchCount; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			recovered[idx], recResults[idx] = c.Recover(uint64(idx + 1))
		}(i)
	}
	wg.Wait()

	// Verify all recoveries succeeded with correct data.
	for i := 0; i < batchCount; i++ {
		if recResults[i].State != RecoverySuccess {
			t.Errorf("batch %d recovery: %s, err: %v", i+1, recResults[i].State, recResults[i].Err)
			continue
		}
		if !bytes.Equal(recovered[i], batches[i]) {
			t.Errorf("batch %d: recovered data mismatch", i+1)
		}
	}
}

// TestE2EDisperseAttestCertifyRecover tests the complete protocol lifecycle.
func TestE2EDisperseAttestCertifyRecover(t *testing.T) {
	c := newTestCommittee(t)

	// Test with various data sizes.
	sizes := []int{100, 1024, 4096, 16384, 65536}

	for _, size := range sizes {
		t.Run(formatSize(size), func(t *testing.T) {
			batchID := uint64(size)
			data := testData(size)

			// Disperse.
			result := c.Disperse(batchID, data)
			if result.Err != nil {
				t.Fatalf("disperse: %v", result.Err)
			}
			if result.CertState != CertValid {
				t.Fatalf("cert state: %s", result.CertState)
			}
			if result.NodesReceived != 7 {
				t.Errorf("nodes received: %d, want 7", result.NodesReceived)
			}
			if result.NodesVerified != 7 {
				t.Errorf("nodes verified: %d, want 7", result.NodesVerified)
			}
			if result.NodesAttested != 7 {
				t.Errorf("nodes attested: %d, want 7", result.NodesAttested)
			}

			// Verify certificate.
			if err := c.VerifyCertificate(result.Certificate); err != nil {
				t.Fatalf("verify cert: %v", err)
			}

			// Recover.
			recovered, recResult := c.Recover(batchID)
			if recResult.State != RecoverySuccess {
				t.Fatalf("recovery: %s, err: %v", recResult.State, recResult.Err)
			}
			if !bytes.Equal(recovered, data) {
				t.Error("data mismatch")
			}
			if recResult.DataSize != size {
				t.Errorf("data size: %d, want %d", recResult.DataSize, size)
			}
		})
	}
}

// TestRecoverFromSpecificNodes tests recovery using only a specific subset of nodes.
func TestRecoverFromSpecificNodes(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(2048)

	disperseAndVerify(t, c, 1, data)

	// Recover from exactly 5 specific nodes (threshold).
	nodeIDs := []NodeID{0, 2, 3, 5, 6}
	recovered, result := c.RecoverFrom(1, nodeIDs)
	if result.State != RecoverySuccess {
		t.Fatalf("recovery: %s, err: %v", result.State, result.Err)
	}
	if result.ChunksUsed != 5 {
		t.Errorf("chunks used: %d, want 5", result.ChunksUsed)
	}
	if !bytes.Equal(recovered, data) {
		t.Error("data mismatch")
	}
}

// TestRecoverFromInsufficientNodes tests that recovery fails with < threshold nodes.
func TestRecoverFromInsufficientNodes(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(1024)

	disperseAndVerify(t, c, 1, data)

	// Try recovery from only 4 nodes.
	nodeIDs := []NodeID{0, 1, 2, 3}
	_, result := c.RecoverFrom(1, nodeIDs)
	if result.State != RecoveryFailed {
		t.Errorf("expected failed recovery with 4 nodes, got: %s", result.State)
	}
}

// TestRecoveryWithCorruptedOnlineNode tests that corruption is detected when
// a corrupted node's data is used in recovery.
func TestRecoveryWithCorruptedOnlineNode(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(2048)

	disperseAndVerify(t, c, 1, data)

	// Corrupt 3 nodes but keep them online.
	// RS can only correct 2 corruptions, so 3 will cause AES-GCM auth failure.
	for i := 0; i < 3; i++ {
		if err := c.Nodes[i].CorruptChunk(1); err != nil {
			t.Fatalf("corrupt node %d: %v", i, err)
		}
	}

	_, result := c.Recover(1)
	if result.State != RecoveryCorrupted {
		t.Errorf("expected corrupted recovery, got: %s, err: %v", result.State, result.Err)
	}
}

// TestNoCertificateRecovery tests that recovery is rejected without a valid certificate.
func TestNoCertificateRecovery(t *testing.T) {
	c := newTestCommittee(t)

	// No dispersal done, try recovery.
	_, result := c.Recover(1)
	if result.State != RecoveryFailed {
		t.Errorf("expected failed recovery without certificate, got: %s", result.State)
	}
	if !errors.Is(result.Err, ErrNoCertificate) {
		t.Errorf("expected ErrNoCertificate, got: %v", result.Err)
	}
}

// TestFallbackManualTrigger tests manual fallback triggering.
func TestFallbackManualTrigger(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(1024)

	if err := c.TriggerFallback(1, data); err != nil {
		t.Fatalf("trigger fallback: %v", err)
	}

	if !c.IsFallback(1) {
		t.Error("expected fallback mode")
	}

	// Cannot trigger fallback twice.
	if err := c.TriggerFallback(1, data); err == nil {
		t.Error("expected error on double fallback trigger")
	}

	// Cannot produce certificate after fallback.
	_, err := c.ProduceCertificate(1, nil)
	if !errors.Is(err, ErrCertificateExists) {
		t.Errorf("expected ErrCertificateExists after fallback, got: %v", err)
	}
}

// =============================================================================
// UNIT TESTS
// =============================================================================

// TestRSEncodeDecodeRoundTrip tests RS encoding and decoding.
func TestRSEncodeDecodeRoundTrip(t *testing.T) {
	encoder, err := NewRSEncoder(DefaultDataShards, DefaultParityShards)
	if err != nil {
		t.Fatalf("NewRSEncoder: %v", err)
	}

	data := testData(4096)
	result, key, err := encoder.Encode(data)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}

	if len(result.Chunks) != DefaultTotal {
		t.Errorf("expected %d chunks, got %d", DefaultTotal, len(result.Chunks))
	}

	// Full decode with all shards.
	shards := make([][]byte, len(result.Chunks))
	for i, chunk := range result.Chunks {
		shards[i] = make([]byte, len(chunk.Data))
		copy(shards[i], chunk.Data)
	}
	decoded, err := encoder.Decode(shards, key, len(data))
	if err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if !bytes.Equal(decoded, data) {
		t.Error("decoded data mismatch")
	}
}

// TestRSDecodeWithMissingShards tests RS reconstruction from k shards.
func TestRSDecodeWithMissingShards(t *testing.T) {
	encoder, err := NewRSEncoder(DefaultDataShards, DefaultParityShards)
	if err != nil {
		t.Fatalf("NewRSEncoder: %v", err)
	}

	data := testData(2048)
	result, key, err := encoder.Encode(data)
	if err != nil {
		t.Fatalf("Encode: %v", err)
	}

	// Remove 2 shards (max for 5,7 config).
	shards := make([][]byte, len(result.Chunks))
	for i, chunk := range result.Chunks {
		shards[i] = make([]byte, len(chunk.Data))
		copy(shards[i], chunk.Data)
	}
	shards[0] = nil
	shards[3] = nil

	decoded, err := encoder.Decode(shards, key, len(data))
	if err != nil {
		t.Fatalf("Decode with 2 missing: %v", err)
	}
	if !bytes.Equal(decoded, data) {
		t.Error("decoded data mismatch with missing shards")
	}
}

// TestShamirSplitRecoverRoundTrip tests Shamir SSS split and recover.
func TestShamirSplitRecoverRoundTrip(t *testing.T) {
	secret := testData(32)
	// Reduce secret modulo BN254 prime for compatibility.
	secretInt := new(big.Int).SetBytes(secret)
	secretInt.Mod(secretInt, bn254Prime)
	secretBytes := make([]byte, 32)
	sb := secretInt.Bytes()
	copy(secretBytes[32-len(sb):], sb)

	shares, err := ShamirSplit(secretBytes, 5, 7)
	if err != nil {
		t.Fatalf("ShamirSplit: %v", err)
	}

	if len(shares) != 7 {
		t.Fatalf("expected 7 shares, got %d", len(shares))
	}

	// Recover from exactly 5 shares.
	recovered, err := ShamirRecover(shares[:5])
	if err != nil {
		t.Fatalf("ShamirRecover: %v", err)
	}

	if !bytes.Equal(recovered, secretBytes) {
		t.Error("Shamir round-trip failed: secret mismatch")
	}
}

// TestShamirInsufficientShares tests that < threshold shares fail recovery.
func TestShamirInsufficientShares(t *testing.T) {
	secret := make([]byte, 32)
	secret[31] = 42

	shares, err := ShamirSplit(secret, 5, 7)
	if err != nil {
		t.Fatalf("ShamirSplit: %v", err)
	}

	// 4 shares should recover a WRONG secret (not fail -- Shamir always produces
	// output, but with < k shares the output is random).
	recovered, err := ShamirRecover(shares[:4])
	if err != nil {
		t.Fatalf("ShamirRecover with 4 shares: %v", err)
	}

	// The recovered value should NOT match the original secret.
	if bytes.Equal(recovered, secret) {
		t.Error("Shamir recovered correct secret with < threshold shares (should not happen)")
	}
}

// TestNodeLifecycle tests online/offline transitions and persistent storage.
func TestNodeLifecycle(t *testing.T) {
	c := newTestCommittee(t)
	data := testData(1024)

	disperseAndVerify(t, c, 1, data)

	node := c.Nodes[0]

	// Take offline.
	node.SetOffline()
	if node.IsOnline() {
		t.Error("node should be offline")
	}

	// Cannot get chunk while offline.
	_, err := node.GetChunk(1)
	if !errors.Is(err, ErrNodeOffline) {
		t.Errorf("expected ErrNodeOffline, got: %v", err)
	}

	// Bring back online -- storage persists.
	node.SetOnline()
	chunk, err := node.GetChunk(1)
	if err != nil {
		t.Fatalf("get chunk after recovery: %v", err)
	}
	if chunk == nil {
		t.Error("stored chunk should persist across offline/online cycle")
	}
}

// TestStorageOverhead verifies the storage overhead calculation.
func TestStorageOverhead(t *testing.T) {
	c := newTestCommittee(t)
	overhead := c.StorageOverhead(500000)

	// For (5,7) RS, expected ~1.4x plus small constant for key share + hash.
	if overhead < 1.3 || overhead > 1.6 {
		t.Errorf("unexpected storage overhead: %.2fx (expected ~1.4x)", overhead)
	}
}

// formatSize returns a human-readable size string for test names.
func formatSize(size int) string {
	switch {
	case size >= 1024*1024:
		return fmt.Sprintf("%dMB", size/(1024*1024))
	case size >= 1024:
		return fmt.Sprintf("%dKB", size/1024)
	default:
		return fmt.Sprintf("%dB", size)
	}
}
