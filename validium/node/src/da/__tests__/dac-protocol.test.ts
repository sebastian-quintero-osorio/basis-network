/**
 * Unit and adversarial tests for DACProtocol.
 *
 * [Spec: validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/specs/DataAvailability/DataAvailability.tla]
 *
 * Tests cover:
 *   - Full lifecycle: distribute -> attest -> recover
 *   - CertificateSoundness: valid cert requires >= k attestations
 *   - DataAvailability: k honest nodes -> successful recovery
 *   - Privacy (INV-DA1): no individual node can reconstruct data
 *   - RecoveryIntegrity: corrupted shares detected via commitment
 *   - AttestationIntegrity: only share-holders can attest
 *   - EventualFallback: fallback triggers when threshold structurally unreachable
 *   - Adversarial: forged attestations, duplicate signers, non-member signers
 */

import { createHash } from "crypto";
import { DACProtocol } from "../dac-protocol";
import { DACNode } from "../dac-node";
import { CertificateState, DACError, DACErrorCode, RecoveryState } from "../types";
import type { DACConfig, DACCertificate, Attestation } from "../types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const DEFAULT_CONFIG: DACConfig = {
  committeeSize: 3,
  threshold: 2,
  enableFallback: true,
};

const TEST_DATA = Buffer.from("enterprise batch data -- DAC protocol test payload");

function makeProtocol(config?: Partial<DACConfig>): DACProtocol {
  return new DACProtocol({ ...DEFAULT_CONFIG, ...config });
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

describe("DACProtocol construction", () => {
  it("should create committee with correct size", () => {
    const protocol = makeProtocol();
    expect(protocol.getNodes()).toHaveLength(3);
    expect(protocol.getConfig().threshold).toBe(2);
  });

  it("should reject invalid config (threshold > committeeSize)", () => {
    expect(() => makeProtocol({ threshold: 4, committeeSize: 3 })).toThrow(
      DACErrorCode.INVALID_CONFIG
    );
  });

  it("should reject invalid config (threshold < 2)", () => {
    expect(() => makeProtocol({ threshold: 1 })).toThrow(DACErrorCode.INVALID_CONFIG);
  });
});

// ---------------------------------------------------------------------------
// Full Lifecycle (Happy Path)
// ---------------------------------------------------------------------------

describe("Full lifecycle", () => {
  it("distribute -> attest -> recover (2-of-3, all online)", () => {
    const protocol = makeProtocol();

    // Phase 1: distribute
    const dist = protocol.distribute("", TEST_DATA);
    expect(dist.shareSent).toEqual([true, true, true]);
    expect(dist.fieldElementCount).toBeGreaterThan(0);
    expect(dist.commitment).toBe(
      createHash("sha256").update(TEST_DATA).digest("hex")
    );

    // Phase 2: attest
    const att = protocol.collectAttestations(dist.batchId, dist.commitment);
    expect(att.certificate.state).toBe(CertificateState.VALID);
    expect(att.certificate.signatureCount).toBe(3);
    expect(att.fallbackTriggered).toBe(false);

    // Verify certificate
    const ver = protocol.verify(att.certificate);
    expect(ver.valid).toBe(true);
    expect(ver.ecrecoverCount).toBe(3);

    // Phase 3: recover
    const rec = protocol.recover(dist.batchId, dist.commitment);
    expect(rec.recovered).toBe(true);
    expect(rec.dataMatches).toBe(true);
    expect(rec.state).toBe(RecoveryState.SUCCESS);
    expect(rec.data!.equals(TEST_DATA)).toBe(true);
  });

  it("attestBatch convenience method works end-to-end", () => {
    const protocol = makeProtocol();
    const result = protocol.attestBatch(TEST_DATA);

    expect(result.distribution.shareSent.every(Boolean)).toBe(true);
    expect(result.attestation.certificate.state).toBe(CertificateState.VALID);
    expect(result.totalMs).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// CertificateSoundness Invariant
// ---------------------------------------------------------------------------

describe("CertificateSoundness", () => {
  it("valid certificate requires >= threshold attestations", () => {
    const protocol = makeProtocol();
    const dist = protocol.distribute("", TEST_DATA);
    const att = protocol.collectAttestations(dist.batchId, dist.commitment);

    expect(att.certificate.state).toBe(CertificateState.VALID);
    expect(att.certificate.signatureCount).toBeGreaterThanOrEqual(
      protocol.getConfig().threshold
    );
  });

  it("certificate is NOT valid with < threshold online nodes", () => {
    const protocol = makeProtocol();

    // Take 2 nodes offline before distribution
    protocol.setNodeOffline(2);
    protocol.setNodeOffline(3);

    const dist = protocol.distribute("", TEST_DATA);
    const att = protocol.collectAttestations(dist.batchId, dist.commitment);

    // Only 1 node attested, threshold is 2
    expect(att.certificate.signatureCount).toBe(1);
    expect(att.certificate.state).not.toBe(CertificateState.VALID);
  });
});

// ---------------------------------------------------------------------------
// DataAvailability Invariant
// ---------------------------------------------------------------------------

describe("DataAvailability", () => {
  it("recovery succeeds with k honest online nodes", () => {
    const protocol = makeProtocol();
    const dist = protocol.distribute("", TEST_DATA);
    protocol.collectAttestations(dist.batchId, dist.commitment);

    // Take one node offline (still have 2 >= threshold)
    protocol.setNodeOffline(3);

    const rec = protocol.recover(dist.batchId, dist.commitment);
    expect(rec.recovered).toBe(true);
    expect(rec.dataMatches).toBe(true);
    expect(rec.state).toBe(RecoveryState.SUCCESS);
    expect(rec.nodesUsed).toHaveLength(2);
  });

  it("recovery with all 3 nodes succeeds", () => {
    const protocol = makeProtocol();
    const dist = protocol.distribute("", TEST_DATA);

    const rec = protocol.recover(dist.batchId, dist.commitment);
    expect(rec.state).toBe(RecoveryState.SUCCESS);
    expect(rec.data!.equals(TEST_DATA)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Privacy Invariant (INV-DA1)
// ---------------------------------------------------------------------------

describe("Privacy (INV-DA1)", () => {
  it("single node cannot reconstruct data", () => {
    const protocol = makeProtocol();
    const dist = protocol.distribute("", TEST_DATA);

    // Take 2 nodes offline, leaving only 1
    protocol.setNodeOffline(2);
    protocol.setNodeOffline(3);

    const rec = protocol.recover(dist.batchId, dist.commitment);
    expect(rec.recovered).toBe(false);
    expect(rec.state).toBe(RecoveryState.FAILED);
    expect(rec.data).toBeNull();
  });

  it("k-1 nodes cannot reconstruct data (3-of-5)", () => {
    const protocol = makeProtocol({ committeeSize: 5, threshold: 3 });
    const dist = protocol.distribute("", TEST_DATA);

    // Take 3 nodes offline, leaving only 2 (k-1 = 2)
    protocol.setNodeOffline(3);
    protocol.setNodeOffline(4);
    protocol.setNodeOffline(5);

    const rec = protocol.recover(dist.batchId, dist.commitment);
    expect(rec.recovered).toBe(false);
    expect(rec.state).toBe(RecoveryState.FAILED);
  });
});

// ---------------------------------------------------------------------------
// RecoveryIntegrity Invariant
// ---------------------------------------------------------------------------

describe("RecoveryIntegrity", () => {
  it("detects corrupted shares via commitment mismatch", () => {
    const protocol = makeProtocol();
    const dist = protocol.distribute("", TEST_DATA);

    // Simulate malicious node: replace node 1's shares with garbage
    const maliciousNode = protocol.getNodes()[0]!;
    maliciousNode.clear();
    const garbageShares = Array.from(
      { length: dist.fieldElementCount },
      () => 999n
    );
    maliciousNode.storeShare(dist.batchId, garbageShares, dist.commitment);

    // Take node 3 offline so recovery uses nodes 1 (malicious) and 2 (honest)
    protocol.setNodeOffline(3);

    const rec = protocol.recover(dist.batchId, dist.commitment);
    expect(rec.recovered).toBe(true);
    expect(rec.dataMatches).toBe(false);
    expect(rec.state).toBe(RecoveryState.CORRUPTED);
  });
});

// ---------------------------------------------------------------------------
// EventualFallback
// ---------------------------------------------------------------------------

describe("EventualFallback", () => {
  it("triggers fallback when < threshold nodes received shares", () => {
    const protocol = makeProtocol();

    // Take 2 nodes offline BEFORE distribution
    protocol.setNodeOffline(2);
    protocol.setNodeOffline(3);

    const dist = protocol.distribute("", TEST_DATA);
    // Only node 1 received shares (1 < threshold 2)
    expect(dist.shareSent).toEqual([true, false, false]);

    const att = protocol.collectAttestations(dist.batchId, dist.commitment);
    expect(att.fallbackTriggered).toBe(true);
    expect(att.certificate.state).toBe(CertificateState.FALLBACK);
  });

  it("does NOT trigger fallback when threshold nodes received shares", () => {
    const protocol = makeProtocol();

    // Only 1 node offline -- 2 nodes received shares (>= threshold)
    protocol.setNodeOffline(3);

    const dist = protocol.distribute("", TEST_DATA);
    expect(dist.shareSent).toEqual([true, true, false]);

    const att = protocol.collectAttestations(dist.batchId, dist.commitment);
    expect(att.certificate.state).toBe(CertificateState.VALID);
    expect(att.fallbackTriggered).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Node Failure and Recovery
// ---------------------------------------------------------------------------

describe("Node failure and recovery", () => {
  it("node recovers and can participate in recovery (shares persist)", () => {
    const protocol = makeProtocol();
    const dist = protocol.distribute("", TEST_DATA);

    // Node 3 crashes then recovers
    protocol.setNodeOffline(3);
    protocol.setNodeOnline(3);

    // All 3 nodes can contribute to recovery
    const rec = protocol.recover(dist.batchId, dist.commitment);
    expect(rec.state).toBe(RecoveryState.SUCCESS);
  });

  it("node that missed distribution cannot help after recovery", () => {
    const protocol = makeProtocol();

    // Node 3 offline during distribution
    protocol.setNodeOffline(3);
    const dist = protocol.distribute("", TEST_DATA);

    // Node 3 comes back online
    protocol.setNodeOnline(3);

    // Node 3 has no shares, so only nodes 1 and 2 can contribute
    // Take node 2 offline to test if node 3 can fill in
    protocol.setNodeOffline(2);

    const rec = protocol.recover(dist.batchId, dist.commitment);
    // Only node 1 has shares (1 < threshold 2), so recovery fails
    expect(rec.state).toBe(RecoveryState.FAILED);
  });

  it("sequential batches with intermittent failures", () => {
    const protocol = makeProtocol();
    const data1 = Buffer.from("batch 1");
    const data2 = Buffer.from("batch 2");

    // Batch 1: all online
    const dist1 = protocol.distribute("", data1);
    protocol.collectAttestations(dist1.batchId, dist1.commitment);

    // Node 2 crashes
    protocol.setNodeOffline(2);

    // Batch 2: only nodes 1 and 3 online
    const dist2 = protocol.distribute("", data2);
    const att2 = protocol.collectAttestations(dist2.batchId, dist2.commitment);
    expect(att2.certificate.state).toBe(CertificateState.VALID);

    // Both batches recoverable (different node sets)
    const rec1 = protocol.recover(dist1.batchId, dist1.commitment);
    expect(rec1.state).toBe(RecoveryState.SUCCESS);

    const rec2 = protocol.recover(dist2.batchId, dist2.commitment);
    expect(rec2.state).toBe(RecoveryState.SUCCESS);
  });
});

// ---------------------------------------------------------------------------
// On-Chain Verification (verify)
// ---------------------------------------------------------------------------

describe("verify (on-chain simulation)", () => {
  it("accepts valid certificate", () => {
    const protocol = makeProtocol();
    const dist = protocol.distribute("", TEST_DATA);
    const att = protocol.collectAttestations(dist.batchId, dist.commitment);

    const result = protocol.verify(att.certificate);
    expect(result.valid).toBe(true);
  });

  it("rejects certificate with insufficient signatures", () => {
    const protocol = makeProtocol();

    // Build certificate with only 1 attestation (threshold = 2)
    const cert: DACCertificate = {
      batchId: "test",
      dataCommitment: "abc",
      attestations: [],
      signatureCount: 0,
      state: CertificateState.NONE,
      createdAt: Date.now(),
    };

    const result = protocol.verify(cert);
    expect(result.valid).toBe(false);
  });

  it("rejects certificate with forged signature", () => {
    const protocol = makeProtocol();
    const dist = protocol.distribute("", TEST_DATA);
    const att = protocol.collectAttestations(dist.batchId, dist.commitment);

    // Tamper with one signature
    const tampered = att.certificate.attestations.map((a, i) =>
      i === 0 ? { ...a, signature: "forged-signature-hex" } : a
    );
    const forgedCert: DACCertificate = {
      ...att.certificate,
      attestations: tampered,
    };

    const result = protocol.verify(forgedCert);
    expect(result.valid).toBe(false);
  });

  it("rejects certificate with duplicate signer", () => {
    const protocol = makeProtocol();
    const dist = protocol.distribute("", TEST_DATA);
    const att = protocol.collectAttestations(dist.batchId, dist.commitment);

    // Duplicate the first attestation
    const duplicated: DACCertificate = {
      ...att.certificate,
      attestations: [att.certificate.attestations[0]!, att.certificate.attestations[0]!],
      signatureCount: 2,
    };

    const result = protocol.verify(duplicated);
    expect(result.valid).toBe(false);
  });

  it("rejects certificate with non-committee signer", () => {
    const protocol = makeProtocol();

    // Create attestation from node 99 (not in committee of 3)
    const fakeAttestation: Attestation = {
      nodeId: 99,
      dataCommitment: "abc",
      batchId: "test",
      timestamp: Date.now(),
      signature: "fake",
    };

    const cert: DACCertificate = {
      batchId: "test",
      dataCommitment: "abc",
      attestations: [fakeAttestation, fakeAttestation],
      signatureCount: 2,
      state: CertificateState.VALID,
      createdAt: Date.now(),
    };

    const result = protocol.verify(cert);
    expect(result.valid).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Reset
// ---------------------------------------------------------------------------

describe("reset", () => {
  it("should clear all nodes and bring them online", () => {
    const protocol = makeProtocol();
    protocol.distribute("", TEST_DATA);
    protocol.setNodeOffline(1);

    protocol.reset();

    for (const node of protocol.getNodes()) {
      expect(node.isOnline()).toBe(true);
      expect(node.getBatchCount()).toBe(0);
    }
  });
});
