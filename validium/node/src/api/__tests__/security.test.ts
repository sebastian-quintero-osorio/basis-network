/**
 * Security hardening tests: rate limiting, authentication, deduplication,
 * and input validation.
 *
 * @module api/__tests__/security
 */

import { RateLimiter } from "../rate-limiter";
import { ApiKeyAuthenticator, hashApiKey, type AuthConfig } from "../auth";

// ---------------------------------------------------------------------------
// Rate Limiter Tests
// ---------------------------------------------------------------------------

describe("RateLimiter", () => {
  it("should allow requests within the limit", () => {
    const limiter = new RateLimiter({ maxTokens: 5, refillRate: 1 });
    for (let i = 0; i < 5; i++) {
      expect(limiter.allow("client-1")).toBe(true);
    }
  });

  it("should reject requests exceeding the limit", () => {
    const limiter = new RateLimiter({ maxTokens: 3, refillRate: 0 });
    expect(limiter.allow("client-1")).toBe(true);
    expect(limiter.allow("client-1")).toBe(true);
    expect(limiter.allow("client-1")).toBe(true);
    expect(limiter.allow("client-1")).toBe(false);
  });

  it("should track clients independently", () => {
    const limiter = new RateLimiter({ maxTokens: 1, refillRate: 0 });
    expect(limiter.allow("client-1")).toBe(true);
    expect(limiter.allow("client-2")).toBe(true);
    expect(limiter.allow("client-1")).toBe(false);
    expect(limiter.allow("client-2")).toBe(false);
  });

  it("should refill tokens over time", async () => {
    const limiter = new RateLimiter({ maxTokens: 2, refillRate: 100 });
    expect(limiter.allow("client-1")).toBe(true);
    expect(limiter.allow("client-1")).toBe(true);
    expect(limiter.allow("client-1")).toBe(false);

    // Wait for refill (100 tokens/sec -> 10 in 100ms)
    await new Promise((r) => setTimeout(r, 110));
    expect(limiter.allow("client-1")).toBe(true);
  });

  it("should report remaining tokens", () => {
    const limiter = new RateLimiter({ maxTokens: 5, refillRate: 0 });
    expect(limiter.remaining("new-client")).toBe(5);
    limiter.allow("new-client");
    expect(limiter.remaining("new-client")).toBe(4);
  });

  it("should start and stop cleanup", () => {
    const limiter = new RateLimiter({ cleanupIntervalMs: 100 });
    limiter.start();
    limiter.stop();
  });
});

// ---------------------------------------------------------------------------
// API Key Authentication Tests
// ---------------------------------------------------------------------------

describe("ApiKeyAuthenticator", () => {
  const testKey = "test-api-key-secret-12345";
  const testKeyHash = hashApiKey(testKey);

  const authConfig: AuthConfig = {
    enabled: true,
    keys: [
      {
        keyHash: testKeyHash,
        enterpriseId: "enterprise-001",
        label: "test",
        active: true,
      },
    ],
  };

  it("should accept valid Bearer token", () => {
    const auth = new ApiKeyAuthenticator(authConfig);
    const result = auth.validate(`Bearer ${testKey}`, undefined);
    expect(result.valid).toBe(true);
    expect(result.enterpriseId).toBe("enterprise-001");
  });

  it("should accept valid X-API-Key header", () => {
    const auth = new ApiKeyAuthenticator(authConfig);
    const result = auth.validate(undefined, testKey);
    expect(result.valid).toBe(true);
    expect(result.enterpriseId).toBe("enterprise-001");
  });

  it("should reject missing API key", () => {
    const auth = new ApiKeyAuthenticator(authConfig);
    const result = auth.validate(undefined, undefined);
    expect(result.valid).toBe(false);
    expect(result.reason).toBe("Missing API key");
  });

  it("should reject invalid API key", () => {
    const auth = new ApiKeyAuthenticator(authConfig);
    const result = auth.validate("Bearer wrong-key", undefined);
    expect(result.valid).toBe(false);
    expect(result.reason).toBe("Invalid API key");
  });

  it("should skip authentication when disabled", () => {
    const auth = new ApiKeyAuthenticator({ enabled: false, keys: [] });
    const result = auth.validate(undefined, undefined);
    expect(result.valid).toBe(true);
  });

  it("should ignore inactive keys", () => {
    const auth = new ApiKeyAuthenticator({
      enabled: true,
      keys: [
        {
          keyHash: testKeyHash,
          enterpriseId: "enterprise-001",
          label: "revoked",
          active: false,
        },
      ],
    });
    const result = auth.validate(`Bearer ${testKey}`, undefined);
    expect(result.valid).toBe(false);
  });

  it("should produce deterministic hashes", () => {
    const h1 = hashApiKey("same-key");
    const h2 = hashApiKey("same-key");
    expect(h1).toBe(h2);
    expect(h1).toHaveLength(64);
  });

  it("should produce different hashes for different keys", () => {
    const h1 = hashApiKey("key-a");
    const h2 = hashApiKey("key-b");
    expect(h1).not.toBe(h2);
  });
});
