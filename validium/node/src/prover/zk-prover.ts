/**
 * ZK Prover -- Groth16 proof generation wrapper over snarkjs.
 *
 * [Spec: validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/specs/EnterpriseNode/EnterpriseNode.tla]
 *
 * Implements the GenerateProof action: takes a batch witness (from BatchBuilder)
 * and produces a Groth16 proof suitable for L1 verification via StateCommitment.sol.
 *
 * Circuit: state_transition.circom (depth x batchSize)
 *   Public inputs:  prevStateRoot, newStateRoot, batchNum, enterpriseId
 *   Private inputs: txKeys[], txOldValues[], txNewValues[], txSiblings[][]
 *
 * @module prover/zk-prover
 */

import * as fs from "fs";
import * as path from "path";
import type { ProofResult } from "../types";
import { NodeError, NodeErrorCode } from "../types";
import type { BatchBuildResult } from "../batch/types";
import { createLogger } from "../logger";

// snarkjs is a CommonJS module without TS declarations
// eslint-disable-next-line @typescript-eslint/no-var-requires
const snarkjs = require("snarkjs") as {
  groth16: {
    fullProve(
      input: Record<string, unknown>,
      wasmFile: string,
      zkeyFile: string
    ): Promise<{
      proof: {
        pi_a: string[];
        pi_b: string[][];
        pi_c: string[];
        protocol: string;
        curve: string;
      };
      publicSignals: string[];
    }>;
    verify(
      vkey: Record<string, unknown>,
      publicSignals: string[],
      proof: Record<string, unknown>
    ): Promise<boolean>;
  };
};

const log = createLogger("prover");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

export interface ZKProverConfig {
  /** Path to compiled circuit WASM file. */
  readonly circuitWasmPath: string;
  /** Path to Groth16 proving key (zkey). */
  readonly provingKeyPath: string;
  /** Enterprise identifier (public circuit input). */
  readonly enterpriseId: string;
  /** Circuit batch size (for padding partial batches). */
  readonly batchSize: number;
  /** Circuit SMT depth (for padding siblings). */
  readonly smtDepth: number;
}

// ---------------------------------------------------------------------------
// ZKProver
// ---------------------------------------------------------------------------

/**
 * Generates Groth16 proofs for state transition batches.
 *
 * [Spec: GenerateProof action -- nodeState transitions Proving -> Submitting]
 */
export class ZKProver {
  private readonly config: ZKProverConfig;

  constructor(config: ZKProverConfig) {
    // Validate circuit files exist
    if (!fs.existsSync(config.circuitWasmPath)) {
      throw new NodeError(
        NodeErrorCode.INVALID_CONFIG,
        `Circuit WASM not found: ${config.circuitWasmPath}`
      );
    }
    if (!fs.existsSync(config.provingKeyPath)) {
      throw new NodeError(
        NodeErrorCode.INVALID_CONFIG,
        `Proving key not found: ${config.provingKeyPath}`
      );
    }

    this.config = config;
    log.info("ZK prover initialized", {
      circuit: path.basename(config.circuitWasmPath),
      batchSize: config.batchSize,
      smtDepth: config.smtDepth,
    });
  }

  /**
   * Generate a Groth16 proof for a batch witness.
   *
   * Takes the output of buildBatchCircuitInput() and produces a proof
   * suitable for on-chain verification via StateCommitment.submitBatch().
   *
   * [Spec: GenerateProof]
   *   nodeState = "Proving"
   *   proof.publicSignals = [prevRoot, newRoot, batchNum, enterpriseId]
   *
   * @param witness - Batch build result from BatchBuilder
   * @returns Groth16 proof components + public signals
   * @throws NodeError if proof generation fails
   */
  async prove(witness: BatchBuildResult): Promise<ProofResult> {
    const startMs = Date.now();

    log.info("Generating proof", {
      batchId: witness.batchId,
      batchNum: witness.batchNum,
      txCount: witness.transitions.length,
    });

    const input = this.formatCircuitInput(witness);

    try {
      const { proof, publicSignals } = await snarkjs.groth16.fullProve(
        input,
        this.config.circuitWasmPath,
        this.config.provingKeyPath
      );

      const durationMs = Date.now() - startMs;

      // Convert snarkjs proof format to Solidity-compatible format.
      // snarkjs uses projective coordinates (3 elements); Solidity needs affine (2).
      // BN254 pairing requires swapping elements within pi_b pairs.
      const result: ProofResult = {
        a: [proof.pi_a[0]!, proof.pi_a[1]!],
        b: [
          [proof.pi_b[0]![1]!, proof.pi_b[0]![0]!],
          [proof.pi_b[1]![1]!, proof.pi_b[1]![0]!],
        ],
        c: [proof.pi_c[0]!, proof.pi_c[1]!],
        publicSignals,
        durationMs,
      };

      log.info("Proof generated", {
        batchId: witness.batchId,
        durationMs,
      });

      return result;
    } catch (error) {
      throw new NodeError(
        NodeErrorCode.PROOF_FAILED,
        `Groth16 proof generation failed for batch ${witness.batchId}: ${String(error)}`
      );
    }
  }

  /**
   * Format BatchBuildResult into the circuit's expected input structure.
   *
   * Handles padding for partial batches: empty transactions use zero values
   * and zero siblings. The circuit processes all batchSize slots but identity
   * transitions (key=0, old=0, new=0) produce no state change.
   */
  private formatCircuitInput(
    witness: BatchBuildResult
  ): Record<string, unknown> {
    const { batchSize, smtDepth, enterpriseId } = this.config;

    // Convert hex string to decimal string for snarkjs circuit input.
    // The batch builder outputs hex strings (no 0x prefix) but snarkjs
    // expects decimal strings that can be parsed as BigInt.
    const hexToDec = (hex: string): string => {
      if (hex === "0") return "0";
      return BigInt("0x" + hex).toString(10);
    };

    const keys: string[] = [];
    const oldValues: string[] = [];
    const newValues: string[] = [];
    const siblings: string[][] = [];
    const pathBits: string[][] = [];

    // Fill with actual transitions (convert hex -> decimal)
    for (const t of witness.transitions) {
      keys.push(hexToDec(t.key));
      oldValues.push(hexToDec(t.oldValue));
      newValues.push(hexToDec(t.newValue));
      siblings.push(t.siblings.map(hexToDec));
      pathBits.push(t.pathBits.map(String));
    }

    // Pad remaining slots with identity transitions (key=0, old=0, new=0).
    // Use real SMT siblings from the batch witness if available (set by the
    // orchestrator after building the witness). This ensures the circuit's
    // Merkle path verification produces the correct root for padding slots.
    const paddingSibs = witness.paddingSiblings?.map(hexToDec)
      ?? Array.from({ length: smtDepth }, () => "0");
    const paddingBits = witness.paddingPathBits?.map(String)
      ?? Array.from({ length: smtDepth }, () => "0");
    for (let i = witness.transitions.length; i < batchSize; i++) {
      keys.push("0");
      oldValues.push("0");
      newValues.push("0");
      siblings.push([...paddingSibs]);
      pathBits.push([...paddingBits]);
    }

    // enterpriseId may be a string label (e.g., "e2e-test-basis") or a numeric ID.
    // The circuit expects a field element. Convert string labels to a deterministic
    // numeric hash (truncated to fit BN128 field).
    let numericEnterpriseId: string;
    if (/^\d+$/.test(enterpriseId)) {
      numericEnterpriseId = enterpriseId;
    } else {
      // Hash the string ID to a numeric value
      const { createHash } = require("crypto") as typeof import("crypto");
      const hash = createHash("sha256").update(enterpriseId).digest("hex");
      numericEnterpriseId = BigInt("0x" + hash.slice(0, 16)).toString(10);
    }

    return {
      prevStateRoot: hexToDec(witness.prevStateRoot),
      newStateRoot: hexToDec(witness.newStateRoot),
      batchNum: String(witness.batchNum),
      enterpriseId: numericEnterpriseId,
      keys,
      oldValues,
      newValues,
      siblings,
      pathBits,
    };
  }
}
