/**
 * DAC Protocol -- Orchestrates share distribution, attestation, and recovery.
 *
 * [Spec: validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/specs/DataAvailability/DataAvailability.tla]
 *
 * Implements the full DAC lifecycle:
 *   Phase 1: distribute(batchId, data, nodes) -- Shamir split + share distribution
 *   Phase 2: collectAttestations -> Certificate production or fallback
 *   Phase 3: recover(batchId, nodes, threshold) -- Lagrange reconstruction
 *   verify(certificate) -- On-chain verification simulation
 *
 * Security model: AnyTrust-inspired
 *   - Attestation threshold: k-of-n (default 2-of-3)
 *   - Privacy: information-theoretic (Shamir SSS)
 *   - Fallback: if < k nodes hold shares, post data on-chain (validium -> rollup mode)
 *
 * @module da/dac-protocol
 */

import { createHash, randomBytes } from "crypto";
import { DACNode } from "./dac-node";
import { shareData, reconstructData } from "./shamir";
import {
  CertificateState,
  DACError,
  DACErrorCode,
  RecoveryState,
  type Attestation,
  type AttestationResult,
  type DACCertificate,
  type DACConfig,
  type DistributionResult,
  type RecoveryResult,
  type VerificationResult,
} from "./types";

// ---------------------------------------------------------------------------
// DACProtocol
// ---------------------------------------------------------------------------

/**
 * Orchestrates the Data Availability Committee protocol across all phases.
 *
 * [Spec: Init, DistributeShares, NodeAttest, ProduceCertificate, TriggerFallback, RecoverData]
 */
export class DACProtocol {
  private readonly config: DACConfig;
  private readonly nodes: DACNode[];

  /**
   * @param config - DAC configuration (committeeSize, threshold, enableFallback)
   * @throws DACError if configuration is invalid
   */
  constructor(config: DACConfig) {
    if (config.threshold < 2 || config.threshold > config.committeeSize) {
      throw new DACError(
        DACErrorCode.INVALID_CONFIG,
        `Invalid config: threshold=${config.threshold}, committeeSize=${config.committeeSize}. Require 2 <= threshold <= committeeSize.`
      );
    }

    this.config = config;
    this.nodes = [];

    for (let i = 0; i < config.committeeSize; i++) {
      this.nodes.push(new DACNode(i + 1));
    }
  }

  /** Returns the committee nodes. */
  getNodes(): readonly DACNode[] {
    return this.nodes;
  }

  /** Returns the protocol configuration. */
  getConfig(): DACConfig {
    return this.config;
  }

  // =========================================================================
  // Phase 1: Share Distribution
  // =========================================================================

  /**
   * Split data into Shamir shares and distribute to all online DAC nodes.
   *
   * [Spec: DistributeShares(b)]
   *   Pre:  shareHolders[b] = {}
   *   Post: shareHolders'[b] = {n in Nodes : nodeOnline[n]}
   *
   * Generates a deterministic batchId from random nonce + data hash.
   * Offline nodes do not receive shares and cannot attest or participate
   * in recovery for this batch.
   *
   * @param batchId - Unique batch identifier (if empty, one is generated)
   * @param data - Raw batch data to distribute
   * @returns Distribution result with per-node delivery status
   */
  distribute(batchId: string, data: Buffer): DistributionResult {
    const startTime = performance.now();

    if (!batchId) {
      batchId = createHash("sha256")
        .update(randomBytes(16))
        .update(data)
        .digest("hex")
        .slice(0, 16);
    }

    const { fieldElements, memberShares, commitment } = shareData(
      data,
      this.config.threshold,
      this.config.committeeSize
    );

    const shareSent: boolean[] = [];
    for (let i = 0; i < this.config.committeeSize; i++) {
      const sent = this.nodes[i]!.storeShare(batchId, memberShares[i]!, commitment);
      shareSent.push(sent);
    }

    return {
      batchId,
      commitment,
      fieldElementCount: fieldElements.length,
      shareSent,
      durationMs: performance.now() - startTime,
    };
  }

  // =========================================================================
  // Phase 2: Attestation Collection + Certificate Production
  // =========================================================================

  /**
   * Collect attestations from all nodes and produce a certificate.
   *
   * [Spec: NodeAttest(n, b) + ProduceCertificate(b) + TriggerFallback(b)]
   *
   * Iterates over all committee nodes, requests attestation, verifies each
   * signature, then evaluates the threshold condition:
   *   - signatureCount >= k -> CertificateState.VALID (ProduceCertificate)
   *   - signatureCount < k && shareHolders < k -> CertificateState.FALLBACK (TriggerFallback)
   *   - signatureCount < k otherwise -> CertificateState.NONE (waiting)
   *
   * @param batchId - Batch to collect attestations for
   * @param commitment - SHA-256 commitment of the original data
   * @returns Attestation result including certificate and fallback status
   */
  collectAttestations(batchId: string, commitment: string): AttestationResult {
    const startTime = performance.now();
    const attestations: (Attestation | null)[] = [];
    const validAttestations: Attestation[] = [];

    for (const node of this.nodes) {
      const attestation = node.attest(batchId);
      attestations.push(attestation);

      if (attestation) {
        if (DACNode.verifyAttestation(attestation, node.getId())) {
          validAttestations.push(attestation);
        }
      }
    }

    const thresholdMet = validAttestations.length >= this.config.threshold;

    // [Spec: TriggerFallback -- shareHolders[b] != {} /\ |shareHolders[b]| < Threshold]
    // Count nodes that actually hold shares (received during distribution)
    const shareHolderCount = this.nodes.filter((n) => n.hasShares(batchId)).length;
    const fallbackTriggered =
      !thresholdMet &&
      this.config.enableFallback &&
      shareHolderCount > 0 &&
      shareHolderCount < this.config.threshold;

    let state: CertificateState;
    if (thresholdMet) {
      state = CertificateState.VALID;
    } else if (fallbackTriggered) {
      state = CertificateState.FALLBACK;
    } else {
      state = CertificateState.NONE;
    }

    const certificate: DACCertificate = {
      batchId,
      dataCommitment: commitment,
      attestations: validAttestations,
      signatureCount: validAttestations.length,
      state,
      createdAt: Date.now(),
    };

    return {
      certificate,
      attestations,
      durationMs: performance.now() - startTime,
      fallbackTriggered,
    };
  }

  /**
   * Full attestation pipeline: distribute + collect attestations.
   *
   * Convenience method that executes Phase 1 and Phase 2 in sequence.
   *
   * @param data - Raw batch data
   * @returns Combined distribution and attestation results
   */
  attestBatch(data: Buffer): {
    distribution: DistributionResult;
    attestation: AttestationResult;
    totalMs: number;
  } {
    const totalStart = performance.now();
    const distribution = this.distribute("", data);
    const attestation = this.collectAttestations(
      distribution.batchId,
      distribution.commitment
    );
    return {
      distribution,
      attestation,
      totalMs: performance.now() - totalStart,
    };
  }

  // =========================================================================
  // Phase 3: Data Recovery
  // =========================================================================

  /**
   * Recover data from available online nodes via Lagrange interpolation.
   *
   * [Spec: RecoverData(b, S)]
   *   Pre:  certState[b] = "valid", recoverState[b] = "none"
   *   Post: recoverState'[b] in {"success", "corrupted", "failed"}
   *
   * Three outcomes per the TLA+ specification:
   *   - SUCCESS:   |S| >= k and all S honest -> SHA-256 matches commitment
   *   - CORRUPTED: |S| >= k but S contains malicious node -> commitment mismatch
   *   - FAILED:    |S| < k -> insufficient shares for reconstruction
   *
   * @param batchId - Batch to recover
   * @param commitment - Expected SHA-256 commitment for integrity check
   * @returns Recovery result with state classification
   */
  recover(batchId: string, commitment: string): RecoveryResult {
    const startTime = performance.now();

    // Find available nodes: online and holding shares for this batch
    const availableNodes: { node: DACNode; shares: readonly bigint[] }[] = [];
    for (const node of this.nodes) {
      const shares = node.getShare(batchId);
      if (shares) {
        availableNodes.push({ node, shares });
      }
    }

    // [Spec: |S| < k -> "failed"]
    if (availableNodes.length < this.config.threshold) {
      return {
        recovered: false,
        data: null,
        nodesUsed: [],
        durationMs: performance.now() - startTime,
        dataMatches: false,
        state: RecoveryState.FAILED,
      };
    }

    // Use first k available nodes
    const used = availableNodes.slice(0, this.config.threshold);
    const memberShares = used.map((n) => n.shares);
    const memberIndices = used.map((n) => n.node.getId());
    const elementCount = memberShares[0]!.length;

    const recoveredData = reconstructData(
      memberShares,
      memberIndices,
      this.config.threshold,
      elementCount
    );

    // Commitment check: SHA-256(recovered) == commitment
    const recoveredCommitment = createHash("sha256").update(recoveredData).digest("hex");
    const dataMatches = recoveredCommitment === commitment;

    // [Spec: success if matches, corrupted if mismatch with enough shares]
    const state = dataMatches ? RecoveryState.SUCCESS : RecoveryState.CORRUPTED;

    return {
      recovered: true,
      data: recoveredData,
      nodesUsed: memberIndices,
      durationMs: performance.now() - startTime,
      dataMatches,
      state,
    };
  }

  // =========================================================================
  // On-Chain Verification Simulation
  // =========================================================================

  /**
   * Simulate on-chain verification of a DACCertificate.
   *
   * [Spec: CertificateSoundness invariant -- valid => |attested[b]| >= Threshold]
   *
   * Checks:
   *   1. Signature count meets threshold
   *   2. All signatures are cryptographically valid
   *   3. No duplicate signers
   *   4. All signers are registered committee members (nodeId in [1, n])
   *
   * @param certificate - Certificate to verify
   * @returns Verification result
   */
  verify(certificate: DACCertificate): VerificationResult {
    const startTime = performance.now();
    let ecrecoverCount = 0;

    // Check 1: threshold
    if (certificate.signatureCount < this.config.threshold) {
      return {
        valid: false,
        ecrecoverCount,
        durationMs: performance.now() - startTime,
      };
    }

    const seenSigners = new Set<number>();

    for (const attestation of certificate.attestations) {
      ecrecoverCount++;

      // Check 2: valid signature
      if (!DACNode.verifyAttestation(attestation, attestation.nodeId)) {
        return {
          valid: false,
          ecrecoverCount,
          durationMs: performance.now() - startTime,
        };
      }

      // Check 3: no duplicate signer
      if (seenSigners.has(attestation.nodeId)) {
        return {
          valid: false,
          ecrecoverCount,
          durationMs: performance.now() - startTime,
        };
      }
      seenSigners.add(attestation.nodeId);

      // Check 4: committee membership (nodeId in [1, committeeSize])
      if (attestation.nodeId < 1 || attestation.nodeId > this.config.committeeSize) {
        return {
          valid: false,
          ecrecoverCount,
          durationMs: performance.now() - startTime,
        };
      }
    }

    return {
      valid: true,
      ecrecoverCount,
      durationMs: performance.now() - startTime,
    };
  }

  // =========================================================================
  // Failure Simulation
  // =========================================================================

  /**
   * Reset all nodes to initial state (online, no stored data).
   */
  reset(): void {
    for (const node of this.nodes) {
      node.clear();
      node.setOnline(true);
    }
  }

  /**
   * Take a specific node offline.
   *
   * [Spec: NodeFail(n) -- nodeOnline'[n] = FALSE]
   */
  setNodeOffline(nodeId: number): void {
    const node = this.nodes.find((n) => n.getId() === nodeId);
    if (node) {
      node.setOnline(false);
    }
  }

  /**
   * Bring a specific node back online.
   *
   * [Spec: NodeRecover(n) -- nodeOnline'[n] = TRUE]
   */
  setNodeOnline(nodeId: number): void {
    const node = this.nodes.find((n) => n.getId() === nodeId);
    if (node) {
      node.setOnline(true);
    }
  }
}
