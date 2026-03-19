/**
 * Unit tests for Shamir's (k,n)-threshold Secret Sharing.
 *
 * [Spec: validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/specs/DataAvailability/DataAvailability.tla]
 *
 * Tests cover:
 *   - Correctness: split + recover round-trips for various (k,n) configs
 *   - Privacy (INV-DA1): k-1 shares produce incorrect reconstruction
 *   - Byte conversion: arbitrary data round-trips through field elements
 *   - Error handling: invalid threshold, field overflow
 *   - Share consistency verification
 */

import {
  split,
  recover,
  bytesToFieldElements,
  fieldElementsToBytes,
  shareData,
  reconstructData,
  verifyShareConsistency,
} from "../shamir";
import { BN128_PRIME, DACError, DACErrorCode } from "../types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Deterministic test secret (arbitrary field element). */
const TEST_SECRET = 42n;
const LARGE_SECRET = BN128_PRIME - 1n;

// ---------------------------------------------------------------------------
// split + recover
// ---------------------------------------------------------------------------

describe("Shamir split/recover", () => {
  it("should reconstruct secret from exactly k shares (2-of-3)", () => {
    const shareSet = split(TEST_SECRET, 3, 2);
    expect(shareSet.shares).toHaveLength(3);
    expect(shareSet.threshold).toBe(2);
    expect(shareSet.total).toBe(3);

    // Recover from first 2 shares
    const recovered = recover(shareSet.shares.slice(0, 2));
    expect(recovered).toBe(TEST_SECRET);
  });

  it("should reconstruct from any k-subset of n shares", () => {
    const shareSet = split(TEST_SECRET, 5, 3);

    // Try several subsets
    expect(recover(shareSet.shares.slice(0, 3))).toBe(TEST_SECRET);
    expect(recover(shareSet.shares.slice(1, 4))).toBe(TEST_SECRET);
    expect(recover(shareSet.shares.slice(2, 5))).toBe(TEST_SECRET);
    expect(recover([shareSet.shares[0]!, shareSet.shares[2]!, shareSet.shares[4]!])).toBe(
      TEST_SECRET
    );
  });

  it("should reconstruct from all n shares", () => {
    const shareSet = split(TEST_SECRET, 5, 3);
    const recovered = recover(shareSet.shares);
    expect(recovered).toBe(TEST_SECRET);
  });

  it("should handle zero secret", () => {
    const shareSet = split(0n, 3, 2);
    const recovered = recover(shareSet.shares.slice(0, 2));
    expect(recovered).toBe(0n);
  });

  it("should handle maximum field element (p-1)", () => {
    const shareSet = split(LARGE_SECRET, 3, 2);
    const recovered = recover(shareSet.shares.slice(0, 2));
    expect(recovered).toBe(LARGE_SECRET);
  });

  it("should handle 3-of-5 threshold", () => {
    const shareSet = split(TEST_SECRET, 5, 3);
    const recovered = recover(shareSet.shares.slice(0, 3));
    expect(recovered).toBe(TEST_SECRET);
  });

  it("should handle 5-of-5 threshold (all parties required)", () => {
    const shareSet = split(TEST_SECRET, 5, 5);
    const recovered = recover(shareSet.shares);
    expect(recovered).toBe(TEST_SECRET);
  });
});

// ---------------------------------------------------------------------------
// Privacy Invariant (INV-DA1)
// ---------------------------------------------------------------------------

describe("Privacy (INV-DA1)", () => {
  it("k-1 shares should NOT reconstruct the correct secret", () => {
    // For a 3-of-5 scheme, using only 2 shares (k-1) should NOT recover the secret.
    // Lagrange interpolation with fewer than k points for a degree k-1 polynomial
    // is underdetermined and produces an incorrect result (with overwhelming probability).
    const shareSet = split(TEST_SECRET, 5, 3);
    const wrongResult = recover(shareSet.shares.slice(0, 2));
    expect(wrongResult).not.toBe(TEST_SECRET);
  });

  it("each share reveals no information about the secret", () => {
    // Generate shares for two different secrets with same (k,n)
    const shares1 = split(100n, 3, 2);
    const shares2 = split(200n, 3, 2);

    // Individual share values at the same index should be different
    // (because random polynomial coefficients differ)
    // This is a statistical test -- collision probability is 1/p ~ 0
    expect(shares1.shares[0]!.value).not.toBe(shares2.shares[0]!.value);
  });
});

// ---------------------------------------------------------------------------
// Error Handling
// ---------------------------------------------------------------------------

describe("Error handling", () => {
  it("should reject k < 2", () => {
    expect(() => split(TEST_SECRET, 3, 1)).toThrow(DACError);
    expect(() => split(TEST_SECRET, 3, 1)).toThrow(DACErrorCode.INVALID_THRESHOLD);
  });

  it("should reject k > n", () => {
    expect(() => split(TEST_SECRET, 2, 3)).toThrow(DACError);
    expect(() => split(TEST_SECRET, 2, 3)).toThrow(DACErrorCode.INVALID_THRESHOLD);
  });

  it("should reject secret outside field", () => {
    expect(() => split(BN128_PRIME, 3, 2)).toThrow(DACErrorCode.INVALID_FIELD_ELEMENT);
    expect(() => split(-1n, 3, 2)).toThrow(DACErrorCode.INVALID_FIELD_ELEMENT);
  });

  it("should reject recover with < 2 shares", () => {
    expect(() => recover([{ index: 1, value: 42n }])).toThrow(
      DACErrorCode.INSUFFICIENT_SHARES
    );
  });
});

// ---------------------------------------------------------------------------
// Byte Conversion
// ---------------------------------------------------------------------------

describe("bytesToFieldElements / fieldElementsToBytes", () => {
  it("should round-trip small data", () => {
    const data = Buffer.from("hello world");
    const elements = bytesToFieldElements(data);
    const recovered = fieldElementsToBytes(elements);
    expect(recovered.equals(data)).toBe(true);
  });

  it("should round-trip data larger than one chunk (31 bytes)", () => {
    const data = Buffer.alloc(100, 0xab);
    const elements = bytesToFieldElements(data);
    expect(elements.length).toBe(Math.ceil(100 / 31));
    const recovered = fieldElementsToBytes(elements);
    expect(recovered.equals(data)).toBe(true);
  });

  it("should round-trip exact chunk boundary", () => {
    const data = Buffer.alloc(31, 0xcd);
    const elements = bytesToFieldElements(data);
    expect(elements.length).toBe(1);
    const recovered = fieldElementsToBytes(elements);
    expect(recovered.equals(data)).toBe(true);
  });

  it("should round-trip empty-ish single byte", () => {
    const data = Buffer.from([0x00]);
    const elements = bytesToFieldElements(data);
    const recovered = fieldElementsToBytes(elements);
    expect(recovered.equals(data)).toBe(true);
  });

  it("should round-trip 1KB data", () => {
    const data = Buffer.alloc(1024);
    for (let i = 0; i < 1024; i++) {
      data[i] = i % 256;
    }
    const elements = bytesToFieldElements(data);
    const recovered = fieldElementsToBytes(elements);
    expect(recovered.equals(data)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Data-Level Sharing (shareData / reconstructData)
// ---------------------------------------------------------------------------

describe("shareData / reconstructData", () => {
  const testData = Buffer.from("enterprise batch data for DAC test");

  it("should reconstruct data from k members (2-of-3)", () => {
    const { memberShares, commitment } = shareData(testData, 2, 3);
    expect(memberShares).toHaveLength(3);

    // Use members 0 and 1 (indices 1 and 2)
    const recovered = reconstructData(
      [memberShares[0]!, memberShares[1]!],
      [1, 2],
      2,
      memberShares[0]!.length
    );
    expect(recovered.equals(testData)).toBe(true);
    expect(commitment).toBe(
      require("crypto").createHash("sha256").update(testData).digest("hex")
    );
  });

  it("should reconstruct from any k members", () => {
    const { memberShares } = shareData(testData, 2, 3);

    // Members 1 and 3 (indices 1, 3)
    const recovered = reconstructData(
      [memberShares[0]!, memberShares[2]!],
      [1, 3],
      2,
      memberShares[0]!.length
    );
    expect(recovered.equals(testData)).toBe(true);
  });

  it("should fail reconstruction with k-1 members", () => {
    const { memberShares } = shareData(testData, 3, 5);

    // Only 2 members for a 3-of-5 scheme
    expect(() =>
      reconstructData(
        [memberShares[0]!, memberShares[1]!],
        [1, 2],
        3,
        memberShares[0]!.length
      )
    ).toThrow(DACErrorCode.INSUFFICIENT_SHARES);
  });

  it("should handle larger batch data (10KB)", () => {
    const largeData = Buffer.alloc(10240);
    for (let i = 0; i < largeData.length; i++) {
      largeData[i] = i % 256;
    }
    const { memberShares } = shareData(largeData, 2, 3);
    const recovered = reconstructData(
      [memberShares[0]!, memberShares[1]!],
      [1, 2],
      2,
      memberShares[0]!.length
    );
    expect(recovered.equals(largeData)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Share Consistency Verification
// ---------------------------------------------------------------------------

describe("verifyShareConsistency", () => {
  it("should return true for honest shares", () => {
    const shareSet = split(TEST_SECRET, 5, 3);
    expect(verifyShareConsistency(shareSet.shares, 3)).toBe(true);
  });

  it("should detect a corrupted share", () => {
    const shareSet = split(TEST_SECRET, 5, 3);
    // Corrupt one share
    const corrupted = [...shareSet.shares];
    corrupted[2] = { index: corrupted[2]!.index, value: corrupted[2]!.value + 1n };
    expect(verifyShareConsistency(corrupted, 3)).toBe(false);
  });

  it("should return true for exactly k shares (cannot cross-check)", () => {
    const shareSet = split(TEST_SECRET, 3, 2);
    const subset = shareSet.shares.slice(0, 2);
    expect(verifyShareConsistency(subset, 2)).toBe(true);
  });
});
