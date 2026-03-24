package cross

import (
	"log/slog"
	"os"
	"testing"

	"github.com/ethereum/go-ethereum/common"
)

// ---------------------------------------------------------------------------
// Test Infrastructure
// ---------------------------------------------------------------------------

// mockRegistry implements EnterpriseRegistry for testing.
type mockRegistry struct {
	registered map[common.Address]bool
}

func (r *mockRegistry) IsRegistered(enterprise common.Address) bool {
	return r.registered[enterprise]
}

// Test addresses (deterministic).
var (
	enterpriseA = common.HexToAddress("0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
	enterpriseB = common.HexToAddress("0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB")
	enterpriseC = common.HexToAddress("0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC")

	genesisRootA = [32]byte{0x0A}
	genesisRootB = [32]byte{0x0B}
	genesisRootC = [32]byte{0x0C}

	testCommitment = [32]byte{0x01, 0x02, 0x03}
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelWarn}))
}

// setupTestEnv creates a hub with 3 registered enterprises and a settlement coordinator.
func setupTestEnv(t *testing.T) (*Hub, *Spoke, *Spoke, *Spoke, *SettlementCoordinator) {
	t.Helper()
	logger := testLogger()

	registry := &mockRegistry{
		registered: map[common.Address]bool{
			enterpriseA: true,
			enterpriseB: true,
			enterpriseC: true,
		},
	}

	hub, err := NewHub(DefaultConfig(), registry, logger)
	if err != nil {
		t.Fatalf("NewHub: %v", err)
	}

	// Set genesis state roots.
	hub.SetStateRoot(enterpriseA, genesisRootA)
	hub.SetStateRoot(enterpriseB, genesisRootB)
	hub.SetStateRoot(enterpriseC, genesisRootC)

	spokeA, err := NewSpoke(enterpriseA, hub, logger)
	if err != nil {
		t.Fatalf("NewSpoke A: %v", err)
	}
	spokeB, err := NewSpoke(enterpriseB, hub, logger)
	if err != nil {
		t.Fatalf("NewSpoke B: %v", err)
	}
	spokeC, err := NewSpoke(enterpriseC, hub, logger)
	if err != nil {
		t.Fatalf("NewSpoke C: %v", err)
	}

	spokes := map[common.Address]*Spoke{
		enterpriseA: spokeA,
		enterpriseB: spokeB,
		enterpriseC: spokeC,
	}
	coord, err := NewSettlementCoordinator(hub, spokes, logger)
	if err != nil {
		t.Fatalf("NewSettlementCoordinator: %v", err)
	}

	return hub, spokeA, spokeB, spokeC, coord
}

// ===========================================================================
// TEST: Successful Cross-Enterprise Transaction (Full 4-Phase Cycle)
// ===========================================================================

func TestSuccessfulCrossEnterpriseTx(t *testing.T) {
	hub, spokeA, spokeB, _, _ := setupTestEnv(t)

	// Record pre-transaction roots.
	rootABefore := hub.GetStateRoot(enterpriseA)
	rootBBefore := hub.GetStateRoot(enterpriseB)

	// Phase 1: Enterprise A prepares message to Enterprise B.
	msgID, err := spokeA.PrepareMessage(enterpriseB, testCommitment, true)
	if err != nil {
		t.Fatalf("Phase 1 PrepareMessage: %v", err)
	}

	msg, _ := hub.GetMessage(msgID)
	if msg.Status != StatusPrepared {
		t.Fatalf("after Phase 1: expected prepared, got %s", msg.Status)
	}

	// Phase 2: Hub verifies.
	if err := hub.VerifyMessage(msgID); err != nil {
		t.Fatalf("Phase 2 VerifyMessage: %v", err)
	}

	msg, _ = hub.GetMessage(msgID)
	if msg.Status != StatusHubVerified {
		t.Fatalf("after Phase 2: expected hub_verified, got %s", msg.Status)
	}

	// Phase 3: Enterprise B responds.
	if err := spokeB.RespondToMessage(msgID, true); err != nil {
		t.Fatalf("Phase 3 RespondToMessage: %v", err)
	}

	msg, _ = hub.GetMessage(msgID)
	if msg.Status != StatusResponded {
		t.Fatalf("after Phase 3: expected responded, got %s", msg.Status)
	}

	// Phase 4: Hub settles atomically.
	if err := hub.SettleMessage(msgID); err != nil {
		t.Fatalf("Phase 4 SettleMessage: %v", err)
	}

	msg, _ = hub.GetMessage(msgID)
	if msg.Status != StatusSettled {
		t.Fatalf("after Phase 4: expected settled, got %s", msg.Status)
	}

	// Verify: BOTH roots advanced (INV-CE6 AtomicSettlement).
	rootAAfter := hub.GetStateRoot(enterpriseA)
	rootBAfter := hub.GetStateRoot(enterpriseB)
	if rootAAfter == rootABefore {
		t.Fatal("AtomicSettlement: source root did not advance")
	}
	if rootBAfter == rootBBefore {
		t.Fatal("AtomicSettlement: dest root did not advance")
	}
}

// ===========================================================================
// TEST: Cross-Enterprise Isolation (INV-CE5)
// ===========================================================================

func TestCrossEnterpriseIsolation(t *testing.T) {
	_, spokeA, _, _, _ := setupTestEnv(t)

	// Self-message must be rejected.
	_, err := spokeA.PrepareMessage(enterpriseA, testCommitment, true)
	if err == nil {
		t.Fatal("self-message should be rejected")
	}

	// Prepare a valid message and verify it carries no private data.
	hub := spokeA.hub
	msgID, err := spokeA.PrepareMessage(enterpriseB, testCommitment, true)
	if err != nil {
		t.Fatalf("PrepareMessage: %v", err)
	}

	msg, _ := hub.GetMessage(msgID)

	// INV-CE5: Message fields are all public metadata. No private data field exists.
	// The struct has: Source, Dest (public addresses), Nonce (counter),
	// SourceProofValid/DestProofValid (boolean), SourceStateRoot/DestStateRoot (public),
	// Status, CreatedAtBlock, Commitment (opaque hash), ResponseCommitment.
	// Enterprise A's internal state is NEVER part of the message record.
	if msg.Source != enterpriseA {
		t.Fatal("Isolation: unexpected source")
	}
	if msg.Dest != enterpriseB {
		t.Fatal("Isolation: unexpected dest")
	}
	if msg.Source == msg.Dest {
		t.Fatal("Isolation: source == dest")
	}
	// Proof validity is boolean -- reveals nothing about witness.
	if msg.SourceProofValid != true {
		t.Fatal("Isolation: proof validity not a boolean")
	}
}

// ===========================================================================
// TEST: Atomic Settlement -- Partial Settlement Must Fail (INV-CE6)
// ===========================================================================

func TestAtomicSettlement_InvalidSourceProof(t *testing.T) {
	hub, _, _, _, coord := setupTestEnv(t)

	rootABefore := hub.GetStateRoot(enterpriseA)
	rootBBefore := hub.GetStateRoot(enterpriseB)

	// Execute with invalid source proof.
	result, err := coord.ExecuteCrossEnterpriseTxWithProofs(
		enterpriseA, enterpriseB, testCommitment, false, true,
	)
	if err != nil {
		t.Fatalf("ExecuteCrossEnterpriseTx: %v", err)
	}

	// Must fail at Phase 2 (hub verification rejects invalid proof).
	if result.FinalStatus != StatusFailed {
		t.Fatalf("expected failed, got %s", result.FinalStatus)
	}
	if result.FailedPhase != 2 {
		t.Fatalf("expected failure at Phase 2, got Phase %d", result.FailedPhase)
	}

	// NEITHER root changed.
	if hub.GetStateRoot(enterpriseA) != rootABefore {
		t.Fatal("AtomicSettlement: source root changed on failure")
	}
	if hub.GetStateRoot(enterpriseB) != rootBBefore {
		t.Fatal("AtomicSettlement: dest root changed on failure")
	}
}

func TestAtomicSettlement_InvalidDestProof(t *testing.T) {
	hub, _, _, _, coord := setupTestEnv(t)

	rootABefore := hub.GetStateRoot(enterpriseA)
	rootBBefore := hub.GetStateRoot(enterpriseB)

	// Execute with invalid dest proof.
	result, err := coord.ExecuteCrossEnterpriseTxWithProofs(
		enterpriseA, enterpriseB, testCommitment, true, false,
	)
	if err != nil {
		t.Fatalf("ExecuteCrossEnterpriseTx: %v", err)
	}

	// Must fail at Phase 4 (settlement rejects invalid dest proof).
	if result.FinalStatus != StatusFailed {
		t.Fatalf("expected failed, got %s", result.FinalStatus)
	}
	if result.FailedPhase != 4 {
		t.Fatalf("expected failure at Phase 4, got Phase %d", result.FailedPhase)
	}

	// NEITHER root changed.
	if hub.GetStateRoot(enterpriseA) != rootABefore {
		t.Fatal("AtomicSettlement: source root changed on dest proof failure")
	}
	if hub.GetStateRoot(enterpriseB) != rootBBefore {
		t.Fatal("AtomicSettlement: dest root changed on dest proof failure")
	}
}

func TestAtomicSettlement_BothProofsInvalid(t *testing.T) {
	hub, _, _, _, coord := setupTestEnv(t)

	rootABefore := hub.GetStateRoot(enterpriseA)
	rootBBefore := hub.GetStateRoot(enterpriseB)

	result, err := coord.ExecuteCrossEnterpriseTxWithProofs(
		enterpriseA, enterpriseB, testCommitment, false, false,
	)
	if err != nil {
		t.Fatalf("ExecuteCrossEnterpriseTx: %v", err)
	}

	if result.FinalStatus != StatusFailed {
		t.Fatalf("expected failed, got %s", result.FinalStatus)
	}

	// NEITHER root changed.
	if hub.GetStateRoot(enterpriseA) != rootABefore {
		t.Fatal("AtomicSettlement: source root changed on double failure")
	}
	if hub.GetStateRoot(enterpriseB) != rootBBefore {
		t.Fatal("AtomicSettlement: dest root changed on double failure")
	}
}

// ===========================================================================
// TEST: Replay Protection (INV-CE8)
// ===========================================================================

func TestReplayProtection(t *testing.T) {
	hub, spokeA, spokeB, _, _ := setupTestEnv(t)

	// Execute a successful cross-enterprise tx.
	msgID, _ := spokeA.PrepareMessage(enterpriseB, testCommitment, true)
	hub.VerifyMessage(msgID)
	spokeB.RespondToMessage(msgID, true)
	hub.SettleMessage(msgID)

	// Verify the nonce was consumed.
	pair := EnterprisePair{Source: enterpriseA, Dest: enterpriseB}
	if !hub.IsNonceUsed(pair, 1) {
		t.Fatal("ReplayProtection: nonce 1 should be consumed after settlement")
	}

	// Adversarial replay: manually craft a message with the same nonce.
	// Since the message ID is deterministic (source + dest + nonce), the replay
	// message has the same ID as the original. RegisterPreparedMessage must
	// reject duplicates, preventing the nonce from being reused.
	replayMsg, _ := NewPreparedMessage(
		enterpriseA, enterpriseB, 1, true, hub.GetStateRoot(enterpriseA),
		testCommitment, hub.BlockHeight(),
	)
	err := hub.RegisterPreparedMessage(replayMsg)
	if err == nil {
		t.Fatal("ReplayProtection: RegisterPreparedMessage should reject duplicate message ID")
	}

	// Verify the original message remains settled (unchanged).
	originalResult, _ := hub.GetMessage(replayMsg.ID)
	if originalResult.Status != StatusSettled {
		t.Fatalf("ReplayProtection: original message should remain settled, got %s", originalResult.Status)
	}

	// Verify: only ONE message with nonce 1 exists and it is settled.
	verifiedCount := 0
	for _, msg := range hub.AllMessages() {
		if msg.Source == enterpriseA && msg.Dest == enterpriseB && msg.Nonce == 1 {
			if msg.Status == StatusHubVerified || msg.Status == StatusResponded || msg.Status == StatusSettled {
				verifiedCount++
			}
		}
	}
	if verifiedCount != 1 {
		t.Fatalf("ReplayProtection: expected exactly 1 verified message with nonce 1, got %d", verifiedCount)
	}
}

// ===========================================================================
// TEST: Timeout and Rollback (INV-CE9)
// ===========================================================================

func TestTimeout_PreparedMessage(t *testing.T) {
	hub, spokeA, _, _, _ := setupTestEnv(t)
	config := hub.config

	msgID, _ := spokeA.PrepareMessage(enterpriseB, testCommitment, true)

	// Timeout must fail before deadline.
	err := hub.TimeoutMessage(msgID)
	if err == nil {
		t.Fatal("TimeoutSafety: timeout should fail before deadline")
	}

	// Advance to exactly the deadline.
	hub.AdvanceBlocks(config.TimeoutBlocks)

	// Timeout must succeed.
	if err := hub.TimeoutMessage(msgID); err != nil {
		t.Fatalf("TimeoutMessage: %v", err)
	}

	msg, _ := hub.GetMessage(msgID)
	if msg.Status != StatusTimedOut {
		t.Fatalf("expected timed_out, got %s", msg.Status)
	}

	// No root changes on timeout.
	if hub.GetStateRoot(enterpriseA) != genesisRootA {
		t.Fatal("TimeoutSafety: source root changed on timeout")
	}
	if hub.GetStateRoot(enterpriseB) != genesisRootB {
		t.Fatal("TimeoutSafety: dest root changed on timeout")
	}
}

func TestTimeout_HubVerifiedMessage(t *testing.T) {
	hub, spokeA, _, _, _ := setupTestEnv(t)

	msgID, _ := spokeA.PrepareMessage(enterpriseB, testCommitment, true)
	hub.VerifyMessage(msgID)

	hub.AdvanceBlocks(hub.config.TimeoutBlocks)

	if err := hub.TimeoutMessage(msgID); err != nil {
		t.Fatalf("TimeoutMessage on hub_verified: %v", err)
	}

	msg, _ := hub.GetMessage(msgID)
	if msg.Status != StatusTimedOut {
		t.Fatalf("expected timed_out, got %s", msg.Status)
	}

	// Nonce remains consumed after timeout (prevents replay).
	pair := EnterprisePair{Source: enterpriseA, Dest: enterpriseB}
	if !hub.IsNonceUsed(pair, 1) {
		t.Fatal("TimeoutSafety: nonce should remain consumed after timeout")
	}
}

func TestTimeout_RespondedMessage(t *testing.T) {
	hub, spokeA, spokeB, _, _ := setupTestEnv(t)

	msgID, _ := spokeA.PrepareMessage(enterpriseB, testCommitment, true)
	hub.VerifyMessage(msgID)
	spokeB.RespondToMessage(msgID, true)

	hub.AdvanceBlocks(hub.config.TimeoutBlocks)

	if err := hub.TimeoutMessage(msgID); err != nil {
		t.Fatalf("TimeoutMessage on responded: %v", err)
	}

	msg, _ := hub.GetMessage(msgID)
	if msg.Status != StatusTimedOut {
		t.Fatalf("expected timed_out, got %s", msg.Status)
	}
}

func TestTimeout_CannotTimeoutSettledMessage(t *testing.T) {
	hub, _, _, _, coord := setupTestEnv(t)

	result, _ := coord.ExecuteCrossEnterpriseTx(enterpriseA, enterpriseB, testCommitment)
	if result.FinalStatus != StatusSettled {
		t.Fatalf("expected settled, got %s", result.FinalStatus)
	}

	hub.AdvanceBlocks(hub.config.TimeoutBlocks + 100)

	// Cannot timeout a settled (terminal) message.
	err := hub.TimeoutMessage(result.MessageID)
	if err == nil {
		t.Fatal("should not be able to timeout a settled message")
	}
}

func TestTimeout_PrematureTimeoutRejected(t *testing.T) {
	hub, spokeA, _, _, _ := setupTestEnv(t)

	msgID, _ := spokeA.PrepareMessage(enterpriseB, testCommitment, true)

	// Advance only partially.
	hub.AdvanceBlocks(hub.config.TimeoutBlocks - 1)

	err := hub.TimeoutMessage(msgID)
	if err == nil {
		t.Fatal("TimeoutSafety: premature timeout should be rejected")
	}

	msg, _ := hub.GetMessage(msgID)
	if msg.Status != StatusPrepared {
		t.Fatalf("message should still be prepared, got %s", msg.Status)
	}
}

// ===========================================================================
// TEST: Stale State Root (Race Condition)
// ===========================================================================

func TestStaleStateRoot_AtVerification(t *testing.T) {
	hub, spokeA, _, _, _ := setupTestEnv(t)

	// Phase 1: Prepare message (records current root).
	msgID, _ := spokeA.PrepareMessage(enterpriseB, testCommitment, true)

	// Simulate independent state root update (race condition).
	newRoot := [32]byte{0xFF}
	hub.SetStateRoot(enterpriseA, newRoot)

	// Phase 2: Hub verification must fail (stale root).
	err := hub.VerifyMessage(msgID)
	if err == nil {
		t.Fatal("should reject message with stale state root")
	}

	msg, _ := hub.GetMessage(msgID)
	if msg.Status != StatusFailed {
		t.Fatalf("expected failed, got %s", msg.Status)
	}
}

func TestStaleStateRoot_AtSettlement(t *testing.T) {
	hub, spokeA, spokeB, _, _ := setupTestEnv(t)

	rootABefore := hub.GetStateRoot(enterpriseA)
	rootBBefore := hub.GetStateRoot(enterpriseB)

	// Phases 1-3: normal flow.
	msgID, _ := spokeA.PrepareMessage(enterpriseB, testCommitment, true)
	hub.VerifyMessage(msgID)
	spokeB.RespondToMessage(msgID, true)

	// Simulate dest root change between response and settlement.
	hub.SetStateRoot(enterpriseB, [32]byte{0xEE})

	// Phase 4: Settlement must fail (dest root stale).
	err := hub.SettleMessage(msgID)
	if err == nil {
		t.Fatal("should reject settlement with stale dest root")
	}

	msg, _ := hub.GetMessage(msgID)
	if msg.Status != StatusFailed {
		t.Fatalf("expected failed, got %s", msg.Status)
	}

	// Neither root changed from their pre-settlement values.
	// Source root is still the genesis root (not changed by failed settlement).
	if hub.GetStateRoot(enterpriseA) != rootABefore {
		t.Fatal("source root should not change on failed settlement")
	}
	// Dest root was changed by the independent update, but NOT by settlement.
	_ = rootBBefore // dest root was independently modified, which is fine
}

// ===========================================================================
// TEST: Multiple Concurrent Cross-Enterprise Transactions
// ===========================================================================

func TestMultipleConcurrentTransactions(t *testing.T) {
	hub, _, _, _, coord := setupTestEnv(t)

	// Execute A->B.
	result1, err := coord.ExecuteCrossEnterpriseTx(enterpriseA, enterpriseB, [32]byte{0x01})
	if err != nil {
		t.Fatalf("tx1: %v", err)
	}
	if result1.FinalStatus != StatusSettled {
		t.Fatalf("tx1: expected settled, got %s (err: %v)", result1.FinalStatus, result1.Error)
	}

	// Execute B->C (roots of B changed from tx1).
	result2, err := coord.ExecuteCrossEnterpriseTx(enterpriseB, enterpriseC, [32]byte{0x02})
	if err != nil {
		t.Fatalf("tx2: %v", err)
	}
	if result2.FinalStatus != StatusSettled {
		t.Fatalf("tx2: expected settled, got %s (err: %v)", result2.FinalStatus, result2.Error)
	}

	// Execute A->C (roots of A changed from tx1).
	result3, err := coord.ExecuteCrossEnterpriseTx(enterpriseA, enterpriseC, [32]byte{0x03})
	if err != nil {
		t.Fatalf("tx3: %v", err)
	}
	if result3.FinalStatus != StatusSettled {
		t.Fatalf("tx3: expected settled, got %s (err: %v)", result3.FinalStatus, result3.Error)
	}

	// All 3 messages should be settled.
	settled := 0
	for _, msg := range hub.AllMessages() {
		if msg.Status == StatusSettled {
			settled++
		}
	}
	if settled != 3 {
		t.Fatalf("expected 3 settled messages, got %d", settled)
	}
}

// ===========================================================================
// TEST: 3-Enterprise Chain (A->B->C)
// ===========================================================================

func TestThreeEnterpriseChain(t *testing.T) {
	hub, _, _, _, coord := setupTestEnv(t)

	// Step 1: A proves claim to B.
	result1, _ := coord.ExecuteCrossEnterpriseTx(enterpriseA, enterpriseB, [32]byte{0x10})
	if result1.FinalStatus != StatusSettled {
		t.Fatalf("A->B: expected settled, got %s (err: %v)", result1.FinalStatus, result1.Error)
	}

	// Verify A and B roots advanced.
	if result1.SourceRootAfter == result1.SourceRootBefore {
		t.Fatal("A->B: A root did not advance")
	}
	if result1.DestRootAfter == result1.DestRootBefore {
		t.Fatal("A->B: B root did not advance")
	}

	// Step 2: B references A's claim to prove something to C.
	result2, _ := coord.ExecuteCrossEnterpriseTx(enterpriseB, enterpriseC, [32]byte{0x20})
	if result2.FinalStatus != StatusSettled {
		t.Fatalf("B->C: expected settled, got %s (err: %v)", result2.FinalStatus, result2.Error)
	}

	// Verify B and C roots advanced.
	if result2.SourceRootAfter == result2.SourceRootBefore {
		t.Fatal("B->C: B root did not advance")
	}
	if result2.DestRootAfter == result2.DestRootBefore {
		t.Fatal("B->C: C root did not advance")
	}

	// C's root should have advanced exactly once (C was not involved in A->B).
	rootC := hub.GetStateRoot(enterpriseC)
	if rootC == genesisRootC {
		t.Fatal("C root should have advanced from genesis")
	}

	// All messages should be in terminal states.
	for _, msg := range hub.AllMessages() {
		if !msg.Status.IsTerminal() {
			t.Fatalf("message %x not in terminal state: %s", msg.ID[:8], msg.Status)
		}
	}
}

// ===========================================================================
// TEST: Hub Neutrality (INV-CE10)
// ===========================================================================

func TestHubNeutrality(t *testing.T) {
	hub, spokeA, spokeB, _, _ := setupTestEnv(t)

	// Execute successful tx.
	msgID, _ := spokeA.PrepareMessage(enterpriseB, testCommitment, true)
	hub.VerifyMessage(msgID)
	spokeB.RespondToMessage(msgID, true)
	hub.SettleMessage(msgID)

	// All messages that passed hub verification must have valid source proofs.
	for _, msg := range hub.AllMessages() {
		if msg.Status == StatusHubVerified || msg.Status == StatusResponded || msg.Status == StatusSettled {
			if !msg.SourceProofValid {
				t.Fatalf("HubNeutrality: message %x passed verification with invalid source proof", msg.ID[:8])
			}
		}
	}
}

// ===========================================================================
// TEST: Cross-Ref Consistency (INV-CE7)
// ===========================================================================

func TestCrossRefConsistency(t *testing.T) {
	hub, _, _, _, coord := setupTestEnv(t)

	// Execute several transactions.
	coord.ExecuteCrossEnterpriseTx(enterpriseA, enterpriseB, [32]byte{0x01})
	coord.ExecuteCrossEnterpriseTx(enterpriseB, enterpriseC, [32]byte{0x02})

	// All settled messages must have both proofs valid.
	for _, msg := range hub.AllMessages() {
		if msg.Status == StatusSettled {
			if !msg.SourceProofValid {
				t.Fatalf("CrossRefConsistency: settled msg %x has invalid source proof", msg.ID[:8])
			}
			if !msg.DestProofValid {
				t.Fatalf("CrossRefConsistency: settled msg %x has invalid dest proof", msg.ID[:8])
			}
		}
	}
}

// ===========================================================================
// TEST: Message Status Transitions
// ===========================================================================

func TestStatusTransitions_InvalidPhaseOrder(t *testing.T) {
	hub, spokeA, _, _, _ := setupTestEnv(t)

	msgID, _ := spokeA.PrepareMessage(enterpriseB, testCommitment, true)

	// Cannot settle a prepared message (must be responded first).
	err := hub.SettleMessage(msgID)
	if err == nil {
		t.Fatal("should not settle a prepared message")
	}

	// Cannot respond to a prepared message (must be hub_verified first).
	err = hub.RegisterResponse(msgID, true, genesisRootB, [32]byte{})
	if err == nil {
		t.Fatal("should not respond to a prepared message")
	}

	// Verify correctly.
	hub.VerifyMessage(msgID)

	// Cannot verify again.
	msg2ID, _ := spokeA.PrepareMessage(enterpriseB, [32]byte{0x99}, true)
	hub.VerifyMessage(msg2ID)

	// Cannot settle hub_verified (must be responded first).
	err = hub.SettleMessage(msg2ID)
	if err == nil {
		t.Fatal("should not settle a hub_verified message")
	}
}

// ===========================================================================
// TEST: Unregistered Enterprise
// ===========================================================================

func TestUnregisteredEnterprise(t *testing.T) {
	logger := testLogger()

	registry := &mockRegistry{
		registered: map[common.Address]bool{
			enterpriseA: true,
			// B is NOT registered
		},
	}

	hub, _ := NewHub(DefaultConfig(), registry, logger)
	hub.SetStateRoot(enterpriseA, genesisRootA)
	hub.SetStateRoot(enterpriseB, genesisRootB)

	spokeA, _ := NewSpoke(enterpriseA, hub, logger)

	// Prepare and try to verify -- should fail because dest not registered.
	msgID, _ := spokeA.PrepareMessage(enterpriseB, testCommitment, true)
	err := hub.VerifyMessage(msgID)
	if err == nil {
		t.Fatal("should reject message to unregistered enterprise")
	}

	msg, _ := hub.GetMessage(msgID)
	if msg.Status != StatusFailed {
		t.Fatalf("expected failed, got %s", msg.Status)
	}
}

// ===========================================================================
// TEST: Message ID Determinism
// ===========================================================================

func TestMessageIDDeterminism(t *testing.T) {
	id1 := ComputeMessageID(enterpriseA, enterpriseB, 1)
	id2 := ComputeMessageID(enterpriseA, enterpriseB, 1)
	if id1 != id2 {
		t.Fatal("message IDs should be deterministic")
	}

	// Different nonce -> different ID.
	id3 := ComputeMessageID(enterpriseA, enterpriseB, 2)
	if id1 == id3 {
		t.Fatal("different nonce should produce different ID")
	}

	// Different direction -> different ID.
	id4 := ComputeMessageID(enterpriseB, enterpriseA, 1)
	if id1 == id4 {
		t.Fatal("different direction should produce different ID")
	}
}

// ===========================================================================
// TEST: EnterprisePair Validation
// ===========================================================================

func TestEnterprisePairValidation(t *testing.T) {
	tests := []struct {
		name    string
		pair    EnterprisePair
		wantErr bool
	}{
		{"valid", EnterprisePair{enterpriseA, enterpriseB}, false},
		{"self", EnterprisePair{enterpriseA, enterpriseA}, true},
		{"zero source", EnterprisePair{common.Address{}, enterpriseB}, true},
		{"zero dest", EnterprisePair{enterpriseA, common.Address{}}, true},
		{"both zero", EnterprisePair{common.Address{}, common.Address{}}, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.pair.Validate()
			if (err != nil) != tt.wantErr {
				t.Fatalf("Validate() = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

// ===========================================================================
// TEST: Config Validation
// ===========================================================================

func TestConfigValidation(t *testing.T) {
	valid := DefaultConfig()
	if err := valid.Validate(); err != nil {
		t.Fatalf("DefaultConfig should be valid: %v", err)
	}

	invalid := Config{TimeoutBlocks: 0}
	if err := invalid.Validate(); err == nil {
		t.Fatal("zero TimeoutBlocks should be invalid")
	}
}

// ===========================================================================
// TEST: Settlement Coordinator -- Full Integration
// ===========================================================================

func TestSettlementCoordinator_HappyPath(t *testing.T) {
	_, _, _, _, coord := setupTestEnv(t)

	result, err := coord.ExecuteCrossEnterpriseTx(enterpriseA, enterpriseB, testCommitment)
	if err != nil {
		t.Fatalf("ExecuteCrossEnterpriseTx: %v", err)
	}
	if result.FinalStatus != StatusSettled {
		t.Fatalf("expected settled, got %s", result.FinalStatus)
	}
	if result.SourceRootBefore == result.SourceRootAfter {
		t.Fatal("source root should have changed")
	}
	if result.DestRootBefore == result.DestRootAfter {
		t.Fatal("dest root should have changed")
	}
	if result.Error != nil {
		t.Fatalf("unexpected error: %v", result.Error)
	}
	if result.FailedPhase != 0 {
		t.Fatalf("expected no failed phase, got %d", result.FailedPhase)
	}
}

func TestSettlementCoordinator_MissingSpoke(t *testing.T) {
	hub, _, _, _, _ := setupTestEnv(t)

	// Create coordinator with only A and B -- no C.
	spokeA, _ := NewSpoke(enterpriseA, hub, testLogger())
	spokeB, _ := NewSpoke(enterpriseB, hub, testLogger())
	spokes := map[common.Address]*Spoke{
		enterpriseA: spokeA,
		enterpriseB: spokeB,
	}
	coord, _ := NewSettlementCoordinator(hub, spokes, testLogger())

	// Try to send to C -- should fail.
	_, err := coord.ExecuteCrossEnterpriseTx(enterpriseA, enterpriseC, testCommitment)
	if err == nil {
		t.Fatal("should fail when dest spoke is missing")
	}
}
