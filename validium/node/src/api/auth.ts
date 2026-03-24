/**
 * Enterprise API key authentication middleware.
 *
 * Validates API keys passed via the Authorization header (Bearer scheme)
 * or X-API-Key header. Each enterprise has one or more API keys registered
 * by the admin, enabling per-enterprise access control and audit trails.
 *
 * Security purpose: Prevent unauthorized transaction submission (ATK-API-02).
 * Only registered enterprises can submit transactions via the REST API.
 *
 * @module api/auth
 */

import { createHash, randomBytes, timingSafeEqual } from "crypto";
import { createLogger } from "../logger";

const log = createLogger("auth");

export interface ApiKeyEntry {
  /** API key hash (SHA-256 hex). Never store plaintext keys. */
  readonly keyHash: string;
  /** Enterprise identifier this key belongs to. */
  readonly enterpriseId: string;
  /** Human-readable label for the key (e.g., "production", "staging"). */
  readonly label: string;
  /** Whether this key is currently active. */
  readonly active: boolean;
}

export interface AuthConfig {
  /** Whether authentication is enabled. When false, all requests are allowed. */
  readonly enabled: boolean;
  /** Registered API keys. */
  readonly keys: readonly ApiKeyEntry[];
}

/**
 * Hash an API key using SHA-256.
 * Used both for registration (storing hashes) and validation (comparing).
 */
export function hashApiKey(apiKey: string): string {
  return createHash("sha256").update(apiKey).digest("hex");
}

export interface RotateKeyResult {
  /** The new plaintext API key. Only returned once -- store it securely. */
  readonly newKey: string;
  /** SHA-256 hash of the new key. */
  readonly newKeyHash: string;
  /** Timestamp of rotation. */
  readonly rotatedAt: string;
}

export class ApiKeyAuthenticator {
  private readonly enabled: boolean;
  private readonly keyMap: Map<string, ApiKeyEntry>;

  constructor(config: AuthConfig) {
    this.enabled = config.enabled;
    this.keyMap = new Map();

    for (const entry of config.keys) {
      if (entry.active) {
        this.keyMap.set(entry.keyHash, entry);
      }
    }

    log.info("API authentication configured", {
      enabled: this.enabled,
      activeKeys: this.keyMap.size,
    });
  }

  /**
   * Validate an API key from a request.
   * Returns the enterprise ID if valid, null if invalid or auth is disabled.
   *
   * Uses timing-safe comparison to prevent timing attacks.
   */
  validate(authHeader: string | undefined, apiKeyHeader: string | undefined): {
    valid: boolean;
    enterpriseId?: string;
    reason?: string;
  } {
    if (!this.enabled) {
      return { valid: true };
    }

    // Extract key from either header
    let rawKey: string | undefined;

    if (authHeader) {
      const parts = authHeader.split(" ");
      if (parts.length === 2 && parts[0]?.toLowerCase() === "bearer") {
        rawKey = parts[1];
      }
    }

    if (!rawKey && apiKeyHeader) {
      rawKey = apiKeyHeader;
    }

    if (!rawKey) {
      return { valid: false, reason: "Missing API key" };
    }

    const keyHash = hashApiKey(rawKey);
    const entry = this.findKey(keyHash);

    if (!entry) {
      log.warn("Authentication failed: invalid API key");
      return { valid: false, reason: "Invalid API key" };
    }

    return { valid: true, enterpriseId: entry.enterpriseId };
  }

  /**
   * Find a key entry using timing-safe comparison.
   */
  private findKey(keyHash: string): ApiKeyEntry | undefined {
    const keyHashBuffer = Buffer.from(keyHash, "hex");

    for (const [storedHash, entry] of this.keyMap) {
      const storedBuffer = Buffer.from(storedHash, "hex");
      if (
        keyHashBuffer.length === storedBuffer.length &&
        timingSafeEqual(keyHashBuffer, storedBuffer)
      ) {
        return entry;
      }
    }

    return undefined;
  }

  /**
   * Rotate an API key for an enterprise.
   * Generates a new key, deactivates the old one, and returns the new plaintext key.
   */
  rotateKey(enterpriseId: string): RotateKeyResult | null {
    if (!this.enabled) {
      return null;
    }

    // Find and deactivate existing keys for this enterprise.
    for (const [hash, entry] of this.keyMap) {
      if (entry.enterpriseId === enterpriseId) {
        this.keyMap.delete(hash);
        log.info("API key deactivated", { enterpriseId, label: entry.label });
      }
    }

    // Generate new key (32 bytes = 64 hex chars).
    const newKey = randomBytes(32).toString("hex");
    const newKeyHash = hashApiKey(newKey);

    this.keyMap.set(newKeyHash, {
      keyHash: newKeyHash,
      enterpriseId,
      label: "rotated",
      active: true,
    });

    const rotatedAt = new Date().toISOString();
    log.info("API key rotated", { enterpriseId, rotatedAt });

    return { newKey, newKeyHash, rotatedAt };
  }
}
