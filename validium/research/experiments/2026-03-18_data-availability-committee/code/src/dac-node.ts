// RU-V6: DAC Node -- Enterprise-managed data availability node
//
// Each DAC node:
// - Receives and stores Shamir shares for batch data
// - Validates shares against data commitment
// - Signs attestation certificates
// - Supports share retrieval for data recovery
//
// In production, each node is operated by the enterprise (or a trusted partner).
// In this experiment, nodes are simulated in-process.

import { createHash } from 'crypto';
import type { Attestation, DACNodeState } from './types.js';

export class DACNode {
  private nodeId: number;
  private secretKey: string; // Simulated private key (hash-based)
  private state: Map<string, DACNodeState>; // batchId -> state
  private online: boolean;

  constructor(nodeId: number) {
    this.nodeId = nodeId;
    // Deterministic "private key" for simulation (NOT real crypto)
    this.secretKey = createHash('sha256')
      .update(`dac-node-secret-${nodeId}`)
      .digest('hex');
    this.state = new Map();
    this.online = true;
  }

  getId(): number {
    return this.nodeId;
  }

  isOnline(): boolean {
    return this.online;
  }

  setOnline(online: boolean): void {
    this.online = online;
  }

  /**
   * Receive shares for a batch.
   * Validates the data commitment and stores shares.
   */
  receiveShares(
    batchId: string,
    shares: bigint[],
    dataCommitment: string
  ): boolean {
    if (!this.online) {
      return false;
    }

    this.state.set(batchId, {
      nodeId: this.nodeId,
      shares,
      dataCommitment,
      receivedAt: performance.now(),
      attested: false,
    });

    return true;
  }

  /**
   * Sign an attestation for a batch.
   * The node attests that it holds shares for this batch.
   */
  attest(batchId: string): Attestation | null {
    if (!this.online) {
      return null;
    }

    const nodeState = this.state.get(batchId);
    if (!nodeState) {
      return null;
    }

    // Create attestation signature (simulated ECDSA)
    const message = `${batchId}:${nodeState.dataCommitment}:${this.nodeId}`;
    const signature = createHash('sha256')
      .update(message + this.secretKey)
      .digest('hex');

    nodeState.attested = true;

    return {
      nodeId: this.nodeId,
      dataCommitment: nodeState.dataCommitment,
      batchId,
      timestamp: Date.now(),
      signature,
    };
  }

  /**
   * Retrieve shares for data recovery.
   * Only returns shares if the node has them and is online.
   */
  getShares(batchId: string): bigint[] | null {
    if (!this.online) {
      return null;
    }

    const nodeState = this.state.get(batchId);
    if (!nodeState) {
      return null;
    }

    return nodeState.shares;
  }

  /** Check if this node has shares for a batch */
  hasShares(batchId: string): boolean {
    return this.state.has(batchId);
  }

  /** Get storage usage in bytes (approximate) */
  getStorageBytes(): number {
    let total = 0;
    for (const [, state] of this.state) {
      // Each share is a bigint ~32 bytes + overhead
      total += state.shares.length * 40; // 32 bytes value + 8 bytes overhead
      total += state.dataCommitment.length;
      total += 64; // metadata overhead
    }
    return total;
  }

  /** Get number of batches stored */
  getBatchCount(): number {
    return this.state.size;
  }

  /** Verify attestation signature (static, for on-chain verification simulation) */
  static verifyAttestation(attestation: Attestation, nodeId: number): boolean {
    const expectedKey = createHash('sha256')
      .update(`dac-node-secret-${nodeId}`)
      .digest('hex');
    const message = `${attestation.batchId}:${attestation.dataCommitment}:${nodeId}`;
    const expectedSig = createHash('sha256')
      .update(message + expectedKey)
      .digest('hex');
    return attestation.signature === expectedSig;
  }

  /** Clear all stored data (for benchmarking reset) */
  clear(): void {
    this.state.clear();
  }
}
