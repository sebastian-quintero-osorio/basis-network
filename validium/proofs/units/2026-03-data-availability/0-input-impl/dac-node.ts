/**
 * DAC Node -- Enterprise-managed data availability node.
 *
 * [Spec: validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/specs/DataAvailability/DataAvailability.tla]
 *
 * Each DAC node:
 *   - Receives and stores Shamir shares for batch data (Phase 1)
 *   - Signs attestation certificates (Phase 2)
 *   - Returns shares for data recovery (Phase 3)
 *   - Simulates crash/recovery via online/offline toggle
 *
 * In production, each node is operated by the enterprise or a trusted partner.
 * Signature generation uses SHA-256 HMAC simulation; production replaces with ECDSA.
 *
 * @module da/dac-node
 */

import { createHash } from "crypto";
import type { Attestation, DACNodeState } from "./types";

// ---------------------------------------------------------------------------
// DACNode
// ---------------------------------------------------------------------------

/**
 * A single Data Availability Committee node.
 *
 * [Spec: nodeOnline[n], shareHolders[b], attested[b] variables]
 *
 * State persistence model: shares survive offline/online transitions
 * (persistent storage assumption from DACNodeState design). A node that
 * goes offline retains its shares and can resume attestation after recovery.
 */
export class DACNode {
  private readonly nodeId: number;
  private readonly secretKey: string;
  private readonly state: Map<string, DACNodeState>;
  private online: boolean;

  /**
   * @param nodeId - 1-indexed committee member identifier
   */
  constructor(nodeId: number) {
    this.nodeId = nodeId;
    // Deterministic "private key" for simulation (production: ECDSA keypair)
    this.secretKey = createHash("sha256")
      .update(`dac-node-secret-${nodeId}`)
      .digest("hex");
    this.state = new Map();
    this.online = true;
  }

  /** Returns the 1-indexed node identifier. */
  getId(): number {
    return this.nodeId;
  }

  /**
   * Returns whether the node is currently online.
   *
   * [Spec: nodeOnline[n]]
   */
  isOnline(): boolean {
    return this.online;
  }

  /**
   * Set the node's online/offline status.
   *
   * [Spec: NodeFail(n) sets nodeOnline[n] = FALSE]
   * [Spec: NodeRecover(n) sets nodeOnline[n] = TRUE]
   *
   * Shares persist across transitions (persistent storage assumption).
   */
  setOnline(online: boolean): void {
    this.online = online;
  }

  /**
   * Receive and store shares for a batch (Phase 1).
   *
   * [Spec: DistributeShares(b) -- shareHolders'[b] = {n in Nodes : nodeOnline[n]}]
   *
   * Only succeeds if the node is online. Offline nodes do not receive shares
   * and cannot participate in attestation or recovery for this batch.
   *
   * @param batchId - Unique batch identifier
   * @param shares - Share values for each field element
   * @param dataCommitment - SHA-256 commitment of the original batch data
   * @returns True if shares were stored, false if node is offline
   */
  storeShare(
    batchId: string,
    shares: readonly bigint[],
    dataCommitment: string
  ): boolean {
    if (!this.online) {
      return false;
    }

    this.state.set(batchId, {
      nodeId: this.nodeId,
      shares,
      dataCommitment,
      receivedAt: Date.now(),
      attested: false,
    });

    return true;
  }

  /**
   * Sign an attestation for a batch (Phase 2).
   *
   * [Spec: NodeAttest(n, b) -- requires nodeOnline[n], n in shareHolders[b],
   *        n not in attested[b], certState[b] = "none"]
   *
   * The attestation signature certifies this node holds valid shares.
   * Both honest and malicious nodes produce valid attestations (they hold real
   * shares and valid signing keys). The adversarial threat manifests during
   * recovery, not attestation.
   *
   * @param batchId - Batch to attest
   * @returns Attestation object, or null if node is offline or has no shares
   */
  attest(batchId: string): Attestation | null {
    if (!this.online) {
      return null;
    }

    const nodeState = this.state.get(batchId);
    if (!nodeState) {
      return null;
    }

    // Signature: SHA-256(batchId:commitment:nodeId || secretKey)
    const message = `${batchId}:${nodeState.dataCommitment}:${this.nodeId}`;
    const signature = createHash("sha256")
      .update(message + this.secretKey)
      .digest("hex");

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
   * Retrieve shares for data recovery (Phase 3).
   *
   * [Spec: RecoverData(b, S) -- S subset of {n in Nodes : nodeOnline[n] /\ n in shareHolders[b]}]
   *
   * @param batchId - Batch to retrieve shares for
   * @returns Share values, or null if offline or batch not found
   */
  getShare(batchId: string): readonly bigint[] | null {
    if (!this.online) {
      return null;
    }

    const nodeState = this.state.get(batchId);
    if (!nodeState) {
      return null;
    }

    return nodeState.shares;
  }

  /** Check if this node has shares for a batch. */
  hasShares(batchId: string): boolean {
    return this.state.has(batchId);
  }

  /** Returns the number of batches stored on this node. */
  getBatchCount(): number {
    return this.state.size;
  }

  /**
   * Verify an attestation signature (static method).
   *
   * Simulates on-chain ecrecover: recomputes the expected signature from the
   * attestation payload and the deterministic node secret, then compares.
   *
   * In production, this is replaced by ECDSA ecrecover on the L1 contract.
   *
   * @param attestation - Attestation to verify
   * @param nodeId - Expected signer node ID
   * @returns True if the signature is valid
   */
  static verifyAttestation(attestation: Attestation, nodeId: number): boolean {
    const expectedKey = createHash("sha256")
      .update(`dac-node-secret-${nodeId}`)
      .digest("hex");
    const message = `${attestation.batchId}:${attestation.dataCommitment}:${nodeId}`;
    const expectedSig = createHash("sha256")
      .update(message + expectedKey)
      .digest("hex");
    return attestation.signature === expectedSig;
  }

  /** Clear all stored batch data (for testing and benchmarking). */
  clear(): void {
    this.state.clear();
  }
}
