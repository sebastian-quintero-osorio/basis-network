/**
 * gRPC client for distributed DAC nodes.
 *
 * Replaces the in-process DACProtocol for production deployments where
 * DAC nodes run as separate services (validium/dac-node/).
 *
 * Each client instance connects to one DAC node. The orchestrator
 * manages a pool of clients (one per committee member).
 *
 * @module da/dac-client
 */

import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";
import * as path from "path";
import { createLogger } from "../logger";

const log = createLogger("dac-client");

export interface DACClientConfig {
  /** gRPC endpoint (host:port). */
  readonly endpoint: string;
  /** Timeout for each RPC call (ms). */
  readonly timeoutMs: number;
}

export interface StoreShareResult {
  accepted: boolean;
  attestationSignature: string;
  signerAddress: string;
  error?: string;
}

export interface ShareResult {
  found: boolean;
  shareValue: string;
  shareIndex: number;
}

export interface DACHealthResult {
  healthy: boolean;
  nodeId: string;
  sharesStored: number;
  uptimeSeconds: number;
}

/**
 * gRPC client for a single DAC node.
 */
export class DACNodeClient {
  private client: any;
  private readonly config: DACClientConfig;

  constructor(config: DACClientConfig) {
    this.config = config;

    const PROTO_PATH = path.resolve(__dirname, "../../dac-node/proto/dac.proto");
    const packageDefinition = protoLoader.loadSync(PROTO_PATH, {
      keepCase: true,
      longs: String,
      enums: String,
      defaults: true,
      oneofs: true,
    });
    const proto = grpc.loadPackageDefinition(packageDefinition) as any;

    this.client = new proto.basis.dac.v1.DACService(
      config.endpoint,
      grpc.credentials.createInsecure()
    );

    log.info("DAC client created", { endpoint: config.endpoint });
  }

  /**
   * Store a Shamir share on the remote DAC node.
   */
  async storeShare(params: {
    batchId: string;
    enterpriseId: string;
    shareValue: string;
    shareIndex: number;
    dataCommitment: string;
    totalShares: number;
    threshold: number;
  }): Promise<StoreShareResult> {
    return new Promise((resolve, reject) => {
      const deadline = new Date(Date.now() + this.config.timeoutMs);
      this.client.StoreShare(
        {
          batch_id: params.batchId,
          enterprise_id: params.enterpriseId,
          share_value: params.shareValue,
          share_index: params.shareIndex,
          data_commitment: params.dataCommitment,
          total_shares: params.totalShares,
          threshold: params.threshold,
        },
        { deadline },
        (err: grpc.ServiceError | null, response: any) => {
          if (err) {
            reject(new Error(`DAC StoreShare failed: ${err.message}`));
            return;
          }
          resolve({
            accepted: response.accepted,
            attestationSignature: response.attestation_signature,
            signerAddress: response.signer_address,
            error: response.error || undefined,
          });
        }
      );
    });
  }

  /**
   * Retrieve a stored share for data recovery.
   */
  async getShare(batchId: string, enterpriseId: string): Promise<ShareResult> {
    return new Promise((resolve, reject) => {
      const deadline = new Date(Date.now() + this.config.timeoutMs);
      this.client.GetShare(
        { batch_id: batchId, enterprise_id: enterpriseId },
        { deadline },
        (err: grpc.ServiceError | null, response: any) => {
          if (err) {
            reject(new Error(`DAC GetShare failed: ${err.message}`));
            return;
          }
          resolve({
            found: response.found,
            shareValue: response.share_value,
            shareIndex: response.share_index,
          });
        }
      );
    });
  }

  /**
   * Check health of the remote DAC node.
   */
  async health(): Promise<DACHealthResult> {
    return new Promise((resolve, reject) => {
      const deadline = new Date(Date.now() + this.config.timeoutMs);
      this.client.Health(
        {},
        { deadline },
        (err: grpc.ServiceError | null, response: any) => {
          if (err) {
            reject(new Error(`DAC Health failed: ${err.message}`));
            return;
          }
          resolve({
            healthy: response.healthy,
            nodeId: response.node_id,
            sharesStored: Number(response.shares_stored),
            uptimeSeconds: Number(response.uptime_seconds),
          });
        }
      );
    });
  }

  /**
   * Close the gRPC channel.
   */
  close(): void {
    this.client.close();
  }
}
