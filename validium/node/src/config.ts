/**
 * Configuration loader for the Enterprise Node.
 *
 * Loads configuration from environment variables with validation.
 * Use .env files locally; reference .env.example for required variables.
 *
 * [Spec: validium/specs/units/2026-03-enterprise-node/1-formalization/v0-analysis/specs/EnterpriseNode/EnterpriseNode.tla]
 *
 * @module config
 */

import * as path from "path";
import type { NodeConfig } from "./types";
import { NodeError, NodeErrorCode } from "./types";

/**
 * Load and validate node configuration from environment variables.
 * Call dotenv.config() before this function if using .env files.
 *
 * @param envOverrides - Optional overrides for testing
 * @returns Validated node configuration
 * @throws NodeError if required variables are missing
 */
export function loadConfig(
  envOverrides?: Partial<Record<string, string>>
): NodeConfig {
  const env = { ...process.env, ...envOverrides };

  const required = (key: string): string => {
    const value = env[key];
    if (!value) {
      throw new NodeError(
        NodeErrorCode.INVALID_CONFIG,
        `Missing required environment variable: ${key}`
      );
    }
    return value;
  };

  const optional = (key: string, fallback: string): string =>
    env[key] ?? fallback;

  const optionalInt = (key: string, fallback: number): number => {
    const v = env[key];
    if (!v) return fallback;
    const parsed = parseInt(v, 10);
    if (isNaN(parsed)) {
      throw new NodeError(
        NodeErrorCode.INVALID_CONFIG,
        `Environment variable ${key} must be an integer, got: ${v}`
      );
    }
    return parsed;
  };

  const optionalBool = (key: string, fallback: boolean): boolean => {
    const v = env[key];
    if (!v) return fallback;
    return v === "true" || v === "1";
  };

  const config: NodeConfig = {
    enterpriseId: required("ENTERPRISE_ID"),
    l1RpcUrl: required("L1_RPC_URL"),
    l1PrivateKey: required("L1_PRIVATE_KEY"),
    stateCommitmentAddress: required("STATE_COMMITMENT_ADDRESS"),
    circuitWasmPath: required("CIRCUIT_WASM_PATH"),
    provingKeyPath: required("PROVING_KEY_PATH"),
    maxBatchSize: optionalInt("MAX_BATCH_SIZE", 4),
    maxWaitTimeMs: optionalInt("MAX_WAIT_TIME_MS", 30000),
    walDir: optional("WAL_DIR", path.resolve(process.cwd(), "data", "wal")),
    walFsync: optionalBool("WAL_FSYNC", true),
    smtDepth: optionalInt("SMT_DEPTH", 32),
    dacCommitteeSize: optionalInt("DAC_COMMITTEE_SIZE", 3),
    dacThreshold: optionalInt("DAC_THRESHOLD", 2),
    dacEnableFallback: optionalBool("DAC_ENABLE_FALLBACK", true),
    apiHost: optional("API_HOST", "0.0.0.0"),
    apiPort: optionalInt("API_PORT", 3000),
    maxRetries: optionalInt("MAX_RETRIES", 3),
    retryBaseDelayMs: optionalInt("RETRY_BASE_DELAY_MS", 1000),
    batchLoopIntervalMs: optionalInt("BATCH_LOOP_INTERVAL_MS", 1000),
    txConfirmTimeoutMs: optionalInt("L1_TX_CONFIRM_TIMEOUT_MS", 120000),
    walHmacKey: env["WAL_HMAC_KEY"] || undefined,
    walEncryptionKey: env["WAL_ENCRYPTION_KEY"] || undefined,
  };

  // Validate constraints
  if (config.maxBatchSize <= 0) {
    throw new NodeError(
      NodeErrorCode.INVALID_CONFIG,
      `MAX_BATCH_SIZE must be > 0, got ${config.maxBatchSize}`
    );
  }
  if (config.smtDepth <= 0) {
    throw new NodeError(
      NodeErrorCode.INVALID_CONFIG,
      `SMT_DEPTH must be > 0, got ${config.smtDepth}`
    );
  }
  if (config.dacThreshold < 2 || config.dacThreshold > config.dacCommitteeSize) {
    throw new NodeError(
      NodeErrorCode.INVALID_CONFIG,
      `DAC_THRESHOLD must be in [2, DAC_COMMITTEE_SIZE], got threshold=${config.dacThreshold}, size=${config.dacCommitteeSize}`
    );
  }

  return config;
}
