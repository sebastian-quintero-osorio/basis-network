// RU-V6: DAC Protocol -- Orchestrates share distribution, attestation, and recovery
//
// Implements the full DAC pipeline:
// 1. Data -> Shamir shares -> distribute to nodes
// 2. Collect attestations from nodes
// 3. Verify threshold met -> produce DACCertificate
// 4. Recovery: reconstruct data from k nodes' shares
//
// Security model: AnyTrust-inspired
// - Attestation threshold: k-of-n (default 2-of-3)
// - Privacy: information-theoretic (Shamir SSS)
// - Fallback: if < k nodes attest, emit on-chain DA event (data posted to L1)

import { createHash, randomBytes } from 'crypto';
import { DACNode } from './dac-node.js';
import { shareData, reconstructData } from './shamir.js';
import type { Attestation, DACCertificate, DACConfig } from './types.js';

export interface DistributionResult {
  batchId: string;
  commitment: string;
  fieldElementCount: number;
  shareSent: boolean[];
  durationMs: number;
}

export interface AttestationResult {
  certificate: DACCertificate;
  attestations: (Attestation | null)[];
  durationMs: number;
  fallbackTriggered: boolean;
}

export interface RecoveryResult {
  recovered: boolean;
  data: Buffer | null;
  nodesUsed: number[];
  durationMs: number;
  dataMatches: boolean;
}

export class DACProtocol {
  private config: DACConfig;
  private nodes: DACNode[];

  constructor(config: DACConfig) {
    this.config = config;
    this.nodes = [];

    // Create committee nodes
    for (let i = 0; i < config.committeeSize; i++) {
      this.nodes.push(new DACNode(i + 1));
    }
  }

  getNodes(): DACNode[] {
    return this.nodes;
  }

  getConfig(): DACConfig {
    return this.config;
  }

  /**
   * Phase 1: Split data into Shamir shares and distribute to DAC nodes.
   */
  distributeShares(data: Buffer): DistributionResult {
    const startTime = performance.now();
    const batchId = createHash('sha256')
      .update(randomBytes(16))
      .update(data)
      .digest('hex')
      .slice(0, 16);

    const { fieldElements, memberShares, commitment } = shareData(
      data,
      this.config.threshold,
      this.config.committeeSize
    );

    const shareSent: boolean[] = [];
    for (let i = 0; i < this.config.committeeSize; i++) {
      const sent = this.nodes[i].receiveShares(batchId, memberShares[i], commitment);
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

  /**
   * Phase 2: Collect attestations from DAC nodes and produce a certificate.
   */
  collectAttestations(batchId: string, commitment: string): AttestationResult {
    const startTime = performance.now();
    const attestations: (Attestation | null)[] = [];
    const validAttestations: Attestation[] = [];

    for (const node of this.nodes) {
      const attestation = node.attest(batchId);
      attestations.push(attestation);

      if (attestation) {
        // Verify the attestation signature
        if (DACNode.verifyAttestation(attestation, node.getId())) {
          validAttestations.push(attestation);
        }
      }
    }

    const thresholdMet = validAttestations.length >= this.config.threshold;
    const fallbackTriggered = !thresholdMet && this.config.enableFallback;

    const certificate: DACCertificate = {
      batchId,
      dataCommitment: commitment,
      attestations: validAttestations,
      signatureCount: validAttestations.length,
      valid: thresholdMet,
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
   */
  attestBatch(data: Buffer): {
    distribution: DistributionResult;
    attestation: AttestationResult;
    totalMs: number;
  } {
    const totalStart = performance.now();
    const distribution = this.distributeShares(data);
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

  /**
   * Phase 3: Recover data from available nodes.
   * Attempts to reconstruct from the first k available nodes.
   */
  recoverData(batchId: string, originalData: Buffer): RecoveryResult {
    const startTime = performance.now();

    // Find available nodes with shares
    const availableNodes: { node: DACNode; shares: bigint[] }[] = [];
    for (const node of this.nodes) {
      const shares = node.getShares(batchId);
      if (shares) {
        availableNodes.push({ node, shares });
      }
    }

    if (availableNodes.length < this.config.threshold) {
      return {
        recovered: false,
        data: null,
        nodesUsed: [],
        durationMs: performance.now() - startTime,
        dataMatches: false,
      };
    }

    // Use first k available nodes
    const used = availableNodes.slice(0, this.config.threshold);
    const memberShares = used.map((n) => n.shares);
    const memberIndices = used.map((n) => n.node.getId());

    // Determine element count from share array length
    const elementCount = memberShares[0].length;

    const recoveredData = reconstructData(
      memberShares,
      memberIndices,
      this.config.threshold,
      elementCount
    );

    const dataMatches = recoveredData.equals(originalData);

    return {
      recovered: true,
      data: recoveredData,
      nodesUsed: memberIndices,
      durationMs: performance.now() - startTime,
      dataMatches,
    };
  }

  /**
   * Simulate on-chain verification of a DACCertificate.
   * Checks:
   * 1. Signature count meets threshold
   * 2. All signatures are valid
   * 3. No duplicate signers
   * 4. All signers are committee members
   */
  verifyOnChain(certificate: DACCertificate): {
    valid: boolean;
    verificationTimeMs: number;
    ecrecoverCount: number;
  } {
    const startTime = performance.now();
    let ecrecoverCount = 0;

    // Check threshold
    if (certificate.signatureCount < this.config.threshold) {
      return { valid: false, verificationTimeMs: performance.now() - startTime, ecrecoverCount };
    }

    // Verify each signature and check for duplicates
    const seenSigners = new Set<number>();
    for (const attestation of certificate.attestations) {
      ecrecoverCount++;

      // Verify signature
      if (!DACNode.verifyAttestation(attestation, attestation.nodeId)) {
        return { valid: false, verificationTimeMs: performance.now() - startTime, ecrecoverCount };
      }

      // Check for duplicate signer
      if (seenSigners.has(attestation.nodeId)) {
        return { valid: false, verificationTimeMs: performance.now() - startTime, ecrecoverCount };
      }
      seenSigners.add(attestation.nodeId);

      // Check committee membership (nodeId must be 1..n)
      if (attestation.nodeId < 1 || attestation.nodeId > this.config.committeeSize) {
        return { valid: false, verificationTimeMs: performance.now() - startTime, ecrecoverCount };
      }
    }

    return {
      valid: true,
      verificationTimeMs: performance.now() - startTime,
      ecrecoverCount,
    };
  }

  /** Reset all nodes (for benchmarking) */
  reset(): void {
    for (const node of this.nodes) {
      node.clear();
      node.setOnline(true);
    }
  }

  /** Set specific node offline (for failure simulation) */
  setNodeOffline(nodeId: number): void {
    const node = this.nodes.find((n) => n.getId() === nodeId);
    if (node) {
      node.setOnline(false);
    }
  }

  /** Set specific node online */
  setNodeOnline(nodeId: number): void {
    const node = this.nodes.find((n) => n.getId() === nodeId);
    if (node) {
      node.setOnline(true);
    }
  }
}
