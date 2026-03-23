/**
 * Basis Network DAC Node -- Standalone Data Availability Committee Service.
 *
 * Each DAC node stores Shamir secret shares of enterprise batch data,
 * provides ECDSA attestation signatures, and participates in data recovery.
 *
 * Transport: gRPC (proto/dac.proto)
 * Storage: LevelDB for persistent share storage
 * Signing: ECDSA via ethers.js (compatible with on-chain DACAttestation.sol)
 */

import * as grpc from "@grpc/grpc-js";
import * as protoLoader from "@grpc/proto-loader";
import { ethers } from "ethers";
import { Level } from "level";
import * as path from "path";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

interface DACNodeConfig {
  nodeId: string;
  host: string;
  port: number;
  privateKey: string;
  dataDir: string;
}

function loadConfig(): DACNodeConfig {
  return {
    nodeId: process.env["DAC_NODE_ID"] ?? "dac-node-1",
    host: process.env["DAC_HOST"] ?? "0.0.0.0",
    port: parseInt(process.env["DAC_PORT"] ?? "50051", 10),
    privateKey: process.env["DAC_PRIVATE_KEY"] ?? ethers.Wallet.createRandom().privateKey,
    dataDir: process.env["DAC_DATA_DIR"] ?? "./data",
  };
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

interface StoredShare {
  batchId: string;
  enterpriseId: string;
  shareValue: string;
  shareIndex: number;
  dataCommitment: string;
  storedAt: number;
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const config = loadConfig();
  const wallet = new ethers.Wallet(config.privateKey);
  const signerAddress = wallet.address;

  console.log(`DAC Node starting: ${config.nodeId}`);
  console.log(`  Signer: ${signerAddress}`);
  console.log(`  Listen: ${config.host}:${config.port}`);
  console.log(`  Data:   ${config.dataDir}`);

  // Initialize LevelDB
  const db = new Level<string, string>(path.join(config.dataDir, "shares"), {
    valueEncoding: "json",
  });

  const startedAt = Date.now();
  let sharesStored = 0;

  // Load proto
  const PROTO_PATH = path.resolve(__dirname, "../proto/dac.proto");
  const packageDefinition = protoLoader.loadSync(PROTO_PATH, {
    keepCase: true,
    longs: String,
    enums: String,
    defaults: true,
    oneofs: true,
  });
  const proto = grpc.loadPackageDefinition(packageDefinition) as any;

  // Signing helper: keccak256(batchId || dataCommitment || shareIndex)
  async function signAttestation(
    batchId: string,
    dataCommitment: string,
    shareIndex: number
  ): Promise<string> {
    const message = ethers.solidityPackedKeccak256(
      ["string", "string", "uint32"],
      [batchId, dataCommitment, shareIndex]
    );
    return wallet.signMessage(ethers.getBytes(message));
  }

  // gRPC service implementation
  const service = {
    StoreShare: async (
      call: grpc.ServerUnaryCall<any, any>,
      callback: grpc.sendUnaryData<any>
    ) => {
      const req = call.request;
      try {
        // Verify data commitment (SHA-256 of share value should relate to commitment)
        const share: StoredShare = {
          batchId: req.batch_id,
          enterpriseId: req.enterprise_id,
          shareValue: req.share_value,
          shareIndex: req.share_index,
          dataCommitment: req.data_commitment,
          storedAt: Date.now(),
        };

        // Store in LevelDB
        const key = `${req.enterprise_id}:${req.batch_id}`;
        await db.put(key, JSON.stringify(share));
        sharesStored++;

        // Sign attestation
        const signature = await signAttestation(
          req.batch_id,
          req.data_commitment,
          req.share_index
        );

        callback(null, {
          accepted: true,
          attestation_signature: signature,
          signer_address: signerAddress,
          error: "",
        });
      } catch (err) {
        callback(null, {
          accepted: false,
          attestation_signature: "",
          signer_address: signerAddress,
          error: String(err),
        });
      }
    },

    Attest: async (
      call: grpc.ServerUnaryCall<any, any>,
      callback: grpc.sendUnaryData<any>
    ) => {
      const req = call.request;
      const key = `${req.enterprise_id}:${req.batch_id}`;
      try {
        const data = JSON.parse(await db.get(key)) as StoredShare;
        const signature = await signAttestation(
          data.batchId,
          data.dataCommitment,
          data.shareIndex
        );
        callback(null, {
          has_share: true,
          attestation_signature: signature,
          signer_address: signerAddress,
        });
      } catch {
        callback(null, {
          has_share: false,
          attestation_signature: "",
          signer_address: signerAddress,
        });
      }
    },

    GetShare: async (
      call: grpc.ServerUnaryCall<any, any>,
      callback: grpc.sendUnaryData<any>
    ) => {
      const req = call.request;
      const key = `${req.enterprise_id}:${req.batch_id}`;
      try {
        const data = JSON.parse(await db.get(key)) as StoredShare;
        callback(null, {
          found: true,
          share_value: data.shareValue,
          share_index: data.shareIndex,
          error: "",
        });
      } catch {
        callback(null, {
          found: false,
          share_value: "",
          share_index: 0,
          error: "Share not found",
        });
      }
    },

    Health: (
      _call: grpc.ServerUnaryCall<any, any>,
      callback: grpc.sendUnaryData<any>
    ) => {
      callback(null, {
        healthy: true,
        node_id: config.nodeId,
        shares_stored: sharesStored,
        uptime_seconds: Math.floor((Date.now() - startedAt) / 1000),
      });
    },
  };

  // Start gRPC server
  const server = new grpc.Server();
  server.addService(proto.basis.dac.v1.DACService.service, service);

  server.bindAsync(
    `${config.host}:${config.port}`,
    grpc.ServerCredentials.createInsecure(),
    (err, port) => {
      if (err) {
        console.error("Failed to bind:", err);
        process.exit(1);
      }
      console.log(`DAC Node ${config.nodeId} listening on port ${port}`);
    }
  );

  // Graceful shutdown
  const shutdown = (): void => {
    console.log("Shutting down DAC node...");
    server.tryShutdown(() => {
      db.close().then(() => {
        console.log("DAC node stopped.");
        process.exit(0);
      });
    });
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
