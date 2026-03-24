/**
 * Submits DAC attestations to DACAttestation.sol on L1.
 *
 * After the orchestrator collects threshold attestation signatures from
 * DAC nodes, this module submits them on-chain for verifiable data availability.
 *
 * @module da/dac-l1-submitter
 */

import { ethers } from "ethers";
import { createLogger } from "../logger";

const log = createLogger("dac-l1");

const DAC_ATTESTATION_ABI = [
  "function submitAttestation(bytes32 batchId, bytes32 commitment, address[] signers, bytes[] signatures) external",
];

export interface DACL1SubmitterConfig {
  readonly rpcUrl: string;
  readonly privateKey: string;
  readonly contractAddress: string;
}

export interface AttestationData {
  batchId: string;
  commitment: string;
  signers: string[];
  signatures: string[];
}

export class DACL1Submitter {
  private readonly contract: ethers.Contract;

  constructor(config: DACL1SubmitterConfig) {
    const provider = new ethers.JsonRpcProvider(config.rpcUrl);
    const signer = new ethers.Wallet(config.privateKey, provider);
    this.contract = new ethers.Contract(
      config.contractAddress,
      DAC_ATTESTATION_ABI,
      signer
    );
    log.info("DAC L1 submitter initialized", { contract: config.contractAddress });
  }

  /**
   * Submit attestation to DACAttestation.sol.
   * Returns the L1 transaction hash.
   */
  async submit(attestation: AttestationData): Promise<string> {
    const batchIdBytes32 = ethers.zeroPadValue(
      "0x" + attestation.batchId.replace(/^0x/, "").padStart(64, "0"),
      32
    );
    const commitmentBytes32 = ethers.zeroPadValue(
      "0x" + attestation.commitment.replace(/^0x/, "").padStart(64, "0"),
      32
    );

    log.info("Submitting DAC attestation to L1", {
      batchId: batchIdBytes32.slice(0, 18) + "...",
      signerCount: attestation.signers.length,
    });

    try {
      const submitFn = this.contract.getFunction("submitAttestation");
      const tx = await submitFn(
        batchIdBytes32,
        commitmentBytes32,
        attestation.signers,
        attestation.signatures
      );
      const receipt = await tx.wait();

      log.info("DAC attestation confirmed on L1", {
        txHash: receipt.hash,
        blockNumber: receipt.blockNumber,
      });

      return receipt.hash;
    } catch (error) {
      log.warn("DAC L1 attestation failed (non-critical)", {
        error: String(error),
      });
      throw error;
    }
  }
}
