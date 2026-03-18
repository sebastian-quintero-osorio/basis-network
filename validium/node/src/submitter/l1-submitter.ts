/**
 * L1 Submitter -- Submits ZK proofs and state roots to StateCommitment.sol.
 *
 * [Spec: validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/specs/EnterpriseNode/EnterpriseNode.tla]
 *
 * Implements SubmitBatch + ConfirmBatch actions:
 *   - Sends Groth16 proof + state roots to the L1 StateCommitment contract
 *   - Retries with exponential backoff on transient failures
 *   - Tracks lastConfirmedRoot for INV-NO2 (ProofStateIntegrity) validation
 *
 * Contract: l1/contracts/contracts/core/StateCommitment.sol
 *   function submitBatch(
 *     bytes32 prevStateRoot, bytes32 newStateRoot,
 *     uint256[2] a, uint256[2][2] b, uint256[2] c,
 *     uint256[] publicSignals
 *   ) external
 *
 * @module submitter/l1-submitter
 */

import { ethers } from "ethers";
import type { ProofResult, SubmissionResult } from "../types";
import { NodeError, NodeErrorCode } from "../types";
import { createLogger } from "../logger";

const log = createLogger("submitter");

// ---------------------------------------------------------------------------
// StateCommitment ABI (minimal, human-readable)
// ---------------------------------------------------------------------------

const STATE_COMMITMENT_ABI = [
  "function submitBatch(bytes32 prevStateRoot, bytes32 newStateRoot, uint256[2] a, uint256[2][2] b, uint256[2] c, uint256[] publicSignals) external",
  "function getEnterpriseState(address enterprise) external view returns (bytes32 currentRoot, uint64 batchCount, uint64 lastTimestamp, bool initialized)",
  "function initializeEnterprise(bytes32 genesisRoot) external",
  "event BatchCommitted(address indexed enterprise, uint256 indexed batchId, bytes32 prevRoot, bytes32 newRoot, uint256 timestamp)",
];

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

export interface L1SubmitterConfig {
  /** L1 RPC URL. */
  readonly rpcUrl: string;
  /** Private key (hex with 0x prefix). */
  readonly privateKey: string;
  /** StateCommitment contract address. */
  readonly contractAddress: string;
  /** Maximum retry attempts. */
  readonly maxRetries: number;
  /** Base delay (ms) for exponential backoff. */
  readonly retryBaseDelayMs: number;
}

// ---------------------------------------------------------------------------
// L1Submitter
// ---------------------------------------------------------------------------

/**
 * Submits batch proofs to the Basis Network L1 StateCommitment contract.
 *
 * [Spec: SubmitBatch + ConfirmBatch actions]
 *   SubmitBatch: dataExposed' = dataExposed \cup {"proof_signals"}
 *   ConfirmBatch: l1State' = smtState, walCheckpoint advances
 */
export class L1Submitter {
  private readonly contract: ethers.Contract;
  private readonly signer: ethers.Wallet;
  private readonly maxRetries: number;
  private readonly retryBaseDelayMs: number;
  private lastConfirmedRoot: string;

  constructor(config: L1SubmitterConfig) {
    const provider = new ethers.JsonRpcProvider(config.rpcUrl);
    this.signer = new ethers.Wallet(config.privateKey, provider);
    this.contract = new ethers.Contract(
      config.contractAddress,
      STATE_COMMITMENT_ABI,
      this.signer
    );
    this.maxRetries = config.maxRetries;
    this.retryBaseDelayMs = config.retryBaseDelayMs;
    this.lastConfirmedRoot = ethers.zeroPadValue("0x00", 32);

    log.info("L1 submitter initialized", {
      contract: config.contractAddress,
      signer: this.signer.address,
    });
  }

  /**
   * Submit a batch proof to the L1 StateCommitment contract.
   *
   * Implements exponential backoff retry for transient failures.
   * The L1 contract enforces INV-NO2 (prevStateRoot must match current chain head).
   *
   * [Spec: SubmitBatch -> ConfirmBatch]
   *
   * @param proof - Groth16 proof from ZKProver
   * @param prevStateRoot - Previous state root (hex, no 0x prefix)
   * @param newStateRoot - New state root (hex, no 0x prefix)
   * @param batchNum - Sequential batch number
   * @returns Submission result with L1 tx hash
   * @throws NodeError if all retries exhausted
   */
  async submit(
    proof: ProofResult,
    prevStateRoot: string,
    newStateRoot: string,
    batchNum: number
  ): Promise<SubmissionResult> {
    const prevRootBytes32 = ethers.zeroPadValue("0x" + prevStateRoot, 32);
    const newRootBytes32 = ethers.zeroPadValue("0x" + newStateRoot, 32);

    log.info("Submitting batch to L1", {
      batchNum,
      prevRoot: prevRootBytes32.slice(0, 18) + "...",
      newRoot: newRootBytes32.slice(0, 18) + "...",
    });

    for (let attempt = 0; attempt <= this.maxRetries; attempt++) {
      try {
        const submitFn = this.contract.getFunction("submitBatch");
        const tx: ethers.TransactionResponse = await submitFn(
          prevRootBytes32,
          newRootBytes32,
          proof.a,
          proof.b,
          proof.c,
          proof.publicSignals
        );

        log.info("L1 tx sent, waiting for confirmation", {
          txHash: tx.hash,
          attempt,
        });

        const receipt = await tx.wait();
        if (!receipt) {
          throw new Error("Transaction receipt is null");
        }

        this.lastConfirmedRoot = newRootBytes32;

        log.info("Batch confirmed on L1", {
          txHash: receipt.hash,
          blockNumber: receipt.blockNumber,
          batchNum,
        });

        return {
          txHash: receipt.hash,
          blockNumber: receipt.blockNumber,
          newStateRoot,
        };
      } catch (error) {
        const isLastAttempt = attempt === this.maxRetries;
        const errorMsg = error instanceof Error ? error.message : String(error);

        if (isLastAttempt) {
          log.error("L1 submission failed after all retries", {
            batchNum,
            attempts: attempt + 1,
            error: errorMsg,
          });
          throw new NodeError(
            NodeErrorCode.SUBMISSION_FAILED,
            `L1 submission failed after ${attempt + 1} attempts: ${errorMsg}`
          );
        }

        const delay = this.retryBaseDelayMs * Math.pow(2, attempt);
        log.warn("L1 submission attempt failed, retrying", {
          attempt,
          delay,
          error: errorMsg,
        });

        await new Promise((resolve) => setTimeout(resolve, delay));
      }
    }

    // Unreachable, but satisfies TypeScript exhaustiveness
    throw new NodeError(
      NodeErrorCode.SUBMISSION_FAILED,
      "Unexpected: retry loop completed without result"
    );
  }

  /**
   * Get the last confirmed state root on L1.
   *
   * [Spec: l1State variable -- last confirmed state on chain]
   */
  getLastConfirmedRoot(): string {
    return this.lastConfirmedRoot;
  }

  /**
   * Set the last confirmed root (used during recovery from checkpoint).
   */
  setLastConfirmedRoot(root: string): void {
    this.lastConfirmedRoot = root;
  }

  /**
   * Query the enterprise's current state from the L1 contract.
   * Used during startup to sync with on-chain state.
   */
  async queryEnterpriseState(): Promise<{
    currentRoot: string;
    batchCount: number;
    initialized: boolean;
  }> {
    try {
      const queryFn = this.contract.getFunction("getEnterpriseState");
      const result = await queryFn(this.signer.address);
      return {
        currentRoot: String(result[0]),
        batchCount: Number(result[1]),
        initialized: Boolean(result[3]),
      };
    } catch (error) {
      log.warn("Failed to query enterprise state from L1", {
        error: String(error),
      });
      return {
        currentRoot: ethers.zeroPadValue("0x00", 32),
        batchCount: 0,
        initialized: false,
      };
    }
  }
}
