/**
 * Unit tests for DACNode.
 *
 * [Spec: validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/specs/DataAvailability/DataAvailability.tla]
 *
 * Tests cover:
 *   - Share storage and retrieval
 *   - Attestation signing and verification
 *   - Online/offline state transitions
 *   - AttestationIntegrity invariant: only share-holders can attest
 */

import { DACNode } from "../dac-node";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const BATCH_ID = "test-batch-001";
const COMMITMENT = "abc123def456";
const TEST_SHARES: bigint[] = [100n, 200n, 300n];

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

describe("DACNode construction", () => {
  it("should initialize with correct nodeId", () => {
    const node = new DACNode(1);
    expect(node.getId()).toBe(1);
  });

  it("should start online", () => {
    const node = new DACNode(1);
    expect(node.isOnline()).toBe(true);
  });

  it("should start with no batches", () => {
    const node = new DACNode(1);
    expect(node.getBatchCount()).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Share Storage (Phase 1)
// ---------------------------------------------------------------------------

describe("storeShare", () => {
  it("should store shares when online", () => {
    const node = new DACNode(1);
    const result = node.storeShare(BATCH_ID, TEST_SHARES, COMMITMENT);
    expect(result).toBe(true);
    expect(node.hasShares(BATCH_ID)).toBe(true);
    expect(node.getBatchCount()).toBe(1);
  });

  it("should reject shares when offline", () => {
    const node = new DACNode(1);
    node.setOnline(false);
    const result = node.storeShare(BATCH_ID, TEST_SHARES, COMMITMENT);
    expect(result).toBe(false);
    expect(node.hasShares(BATCH_ID)).toBe(false);
  });

  it("should store shares for multiple batches", () => {
    const node = new DACNode(1);
    node.storeShare("batch-1", TEST_SHARES, COMMITMENT);
    node.storeShare("batch-2", [400n, 500n], "def789");
    expect(node.getBatchCount()).toBe(2);
  });
});

// ---------------------------------------------------------------------------
// Attestation (Phase 2)
// ---------------------------------------------------------------------------

describe("attest", () => {
  it("should produce valid attestation when online with shares", () => {
    const node = new DACNode(1);
    node.storeShare(BATCH_ID, TEST_SHARES, COMMITMENT);
    const attestation = node.attest(BATCH_ID);

    expect(attestation).not.toBeNull();
    expect(attestation!.nodeId).toBe(1);
    expect(attestation!.batchId).toBe(BATCH_ID);
    expect(attestation!.dataCommitment).toBe(COMMITMENT);
    expect(attestation!.signature).toBeTruthy();
  });

  it("should return null when offline", () => {
    const node = new DACNode(1);
    node.storeShare(BATCH_ID, TEST_SHARES, COMMITMENT);
    node.setOnline(false);
    expect(node.attest(BATCH_ID)).toBeNull();
  });

  it("should return null when batch not found (AttestationIntegrity)", () => {
    const node = new DACNode(1);
    expect(node.attest("nonexistent")).toBeNull();
  });

  it("should produce verifiable signatures", () => {
    const node = new DACNode(2);
    node.storeShare(BATCH_ID, TEST_SHARES, COMMITMENT);
    const attestation = node.attest(BATCH_ID)!;

    expect(DACNode.verifyAttestation(attestation, 2)).toBe(true);
  });

  it("should reject forged signatures (wrong nodeId)", () => {
    const node = new DACNode(1);
    node.storeShare(BATCH_ID, TEST_SHARES, COMMITMENT);
    const attestation = node.attest(BATCH_ID)!;

    // Verify with wrong node ID should fail
    expect(DACNode.verifyAttestation(attestation, 2)).toBe(false);
  });

  it("should detect tampered attestation data", () => {
    const node = new DACNode(1);
    node.storeShare(BATCH_ID, TEST_SHARES, COMMITMENT);
    const attestation = node.attest(BATCH_ID)!;

    // Tamper with the commitment
    const tampered = { ...attestation, dataCommitment: "tampered" };
    expect(DACNode.verifyAttestation(tampered, 1)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Share Retrieval (Phase 3)
// ---------------------------------------------------------------------------

describe("getShare", () => {
  it("should return shares when online and batch exists", () => {
    const node = new DACNode(1);
    node.storeShare(BATCH_ID, TEST_SHARES, COMMITMENT);
    const shares = node.getShare(BATCH_ID);
    expect(shares).toEqual(TEST_SHARES);
  });

  it("should return null when offline", () => {
    const node = new DACNode(1);
    node.storeShare(BATCH_ID, TEST_SHARES, COMMITMENT);
    node.setOnline(false);
    expect(node.getShare(BATCH_ID)).toBeNull();
  });

  it("should return null for unknown batch", () => {
    const node = new DACNode(1);
    expect(node.getShare("nonexistent")).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// Online/Offline Transitions (NodeFail / NodeRecover)
// ---------------------------------------------------------------------------

describe("online/offline transitions", () => {
  it("shares should persist across offline/online transitions", () => {
    const node = new DACNode(1);
    node.storeShare(BATCH_ID, TEST_SHARES, COMMITMENT);

    // Go offline, come back
    node.setOnline(false);
    expect(node.getShare(BATCH_ID)).toBeNull(); // Offline: cannot retrieve
    expect(node.hasShares(BATCH_ID)).toBe(true); // But shares are still stored

    node.setOnline(true);
    expect(node.getShare(BATCH_ID)).toEqual(TEST_SHARES); // Back online: can retrieve
  });

  it("node can attest after recovery if it had shares before crash", () => {
    const node = new DACNode(1);
    node.storeShare(BATCH_ID, TEST_SHARES, COMMITMENT);

    node.setOnline(false);
    node.setOnline(true);

    const attestation = node.attest(BATCH_ID);
    expect(attestation).not.toBeNull();
    expect(DACNode.verifyAttestation(attestation!, 1)).toBe(true);
  });

  it("node that missed distribution cannot attest after coming online", () => {
    const node = new DACNode(1);
    node.setOnline(false);

    // Distribution happens while offline -- node does NOT receive shares
    const stored = node.storeShare(BATCH_ID, TEST_SHARES, COMMITMENT);
    expect(stored).toBe(false);

    // Come back online
    node.setOnline(true);

    // Cannot attest because shares were never stored
    expect(node.attest(BATCH_ID)).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// Clear
// ---------------------------------------------------------------------------

describe("clear", () => {
  it("should remove all stored batches", () => {
    const node = new DACNode(1);
    node.storeShare("batch-1", TEST_SHARES, COMMITMENT);
    node.storeShare("batch-2", [400n], "xyz");
    expect(node.getBatchCount()).toBe(2);

    node.clear();
    expect(node.getBatchCount()).toBe(0);
    expect(node.hasShares("batch-1")).toBe(false);
  });
});
