/**
 * Token bucket rate limiter for API endpoints.
 *
 * Implements a per-IP token bucket algorithm with configurable capacity and
 * refill rate. Each unique client IP gets its own bucket. Stale buckets are
 * periodically cleaned up to prevent memory growth.
 *
 * Security purpose: Prevent transaction submission flooding (ATK-API-01)
 * and protect the batch formation pipeline from being overwhelmed.
 *
 * @module api/rate-limiter
 */

import { createLogger } from "../logger";

const log = createLogger("rate-limiter");

export interface RateLimiterConfig {
  /** Maximum tokens (requests) per bucket. */
  readonly maxTokens: number;
  /** Tokens added per second. */
  readonly refillRate: number;
  /** Cleanup interval for stale buckets (ms). */
  readonly cleanupIntervalMs: number;
  /** Time after which an unused bucket is considered stale (ms). */
  readonly staleBucketMs: number;
}

interface Bucket {
  tokens: number;
  lastRefill: number;
  lastAccess: number;
}

export class RateLimiter {
  private readonly buckets: Map<string, Bucket> = new Map();
  private readonly config: RateLimiterConfig;
  private cleanupTimer: ReturnType<typeof setInterval> | null = null;

  constructor(config: Partial<RateLimiterConfig> = {}) {
    this.config = {
      maxTokens: config.maxTokens ?? 100,
      refillRate: config.refillRate ?? 10,
      cleanupIntervalMs: config.cleanupIntervalMs ?? 60000,
      staleBucketMs: config.staleBucketMs ?? 300000,
    };
  }

  /**
   * Start the periodic cleanup of stale buckets.
   */
  start(): void {
    if (this.cleanupTimer) return;
    this.cleanupTimer = setInterval(() => {
      this.cleanup();
    }, this.config.cleanupIntervalMs);
  }

  /**
   * Stop the cleanup timer.
   */
  stop(): void {
    if (this.cleanupTimer) {
      clearInterval(this.cleanupTimer);
      this.cleanupTimer = null;
    }
  }

  /**
   * Attempt to consume a token for the given client identifier.
   * Returns true if the request is allowed, false if rate limited.
   */
  allow(clientId: string): boolean {
    const now = Date.now();
    let bucket = this.buckets.get(clientId);

    if (!bucket) {
      bucket = {
        tokens: this.config.maxTokens - 1,
        lastRefill: now,
        lastAccess: now,
      };
      this.buckets.set(clientId, bucket);
      return true;
    }

    // Refill tokens based on elapsed time
    const elapsed = (now - bucket.lastRefill) / 1000;
    const newTokens = elapsed * this.config.refillRate;
    bucket.tokens = Math.min(this.config.maxTokens, bucket.tokens + newTokens);
    bucket.lastRefill = now;
    bucket.lastAccess = now;

    if (bucket.tokens >= 1) {
      bucket.tokens -= 1;
      return true;
    }

    return false;
  }

  /**
   * Get remaining tokens for a client (for X-RateLimit-Remaining header).
   */
  remaining(clientId: string): number {
    const bucket = this.buckets.get(clientId);
    if (!bucket) return this.config.maxTokens;
    return Math.floor(bucket.tokens);
  }

  /**
   * Remove buckets that haven't been accessed recently.
   */
  private cleanup(): void {
    const now = Date.now();
    let removed = 0;
    for (const [key, bucket] of this.buckets) {
      if (now - bucket.lastAccess > this.config.staleBucketMs) {
        this.buckets.delete(key);
        removed++;
      }
    }
    if (removed > 0) {
      log.debug("Rate limiter cleanup", { removed, remaining: this.buckets.size });
    }
  }
}
