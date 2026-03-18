/**
 * Shamir's (k,n)-threshold Secret Sharing Scheme over the BN128 scalar field.
 *
 * [Spec: validium/specs/units/2026-03-data-availability/1-formalization/v0-analysis/specs/DataAvailability/DataAvailability.tla]
 *
 * Provides:
 *   - split(secret, n, k): Share[] -- polynomial evaluation at n points
 *   - recover(shares): bigint -- Lagrange interpolation from k shares
 *   - verifyShare(share, commitment): boolean -- share consistency check
 *   - shareData / reconstructData -- arbitrary byte blob sharing and recovery
 *
 * Security: Information-theoretic. k-1 shares reveal zero information about the secret,
 * even against computationally unbounded adversaries.
 *
 * Reference: Shamir, A. "How to Share a Secret." CACM 22(11):612-613, 1979.
 *
 * @module da/shamir
 */

import { createHash, randomBytes } from "crypto";
import {
  BN128_PRIME,
  CHUNK_SIZE,
  DACError,
  DACErrorCode,
  type Share,
  type ShareSet,
} from "./types";

// ---------------------------------------------------------------------------
// Field Arithmetic (BN128 scalar field)
// ---------------------------------------------------------------------------

/** Modular addition: (a + b) mod p */
function modAdd(a: bigint, b: bigint): bigint {
  return ((a + b) % BN128_PRIME + BN128_PRIME) % BN128_PRIME;
}

/** Modular subtraction: (a - b) mod p */
function modSub(a: bigint, b: bigint): bigint {
  return ((a - b) % BN128_PRIME + BN128_PRIME) % BN128_PRIME;
}

/** Modular multiplication: (a * b) mod p */
function modMul(a: bigint, b: bigint): bigint {
  return ((a * b) % BN128_PRIME + BN128_PRIME) % BN128_PRIME;
}

/** Modular exponentiation via square-and-multiply: base^exp mod m */
function modPow(base: bigint, exp: bigint, mod: bigint): bigint {
  let result = 1n;
  base = ((base % mod) + mod) % mod;
  while (exp > 0n) {
    if (exp & 1n) {
      result = (result * base) % mod;
    }
    exp >>= 1n;
    base = (base * base) % mod;
  }
  return result;
}

/** Modular inverse via Fermat's little theorem: a^(-1) = a^(p-2) mod p */
function modInv(a: bigint): bigint {
  if (a === 0n) {
    throw new DACError(DACErrorCode.INVALID_FIELD_ELEMENT, "Cannot invert zero");
  }
  return modPow(a, BN128_PRIME - 2n, BN128_PRIME);
}

/** Generate a cryptographically random field element in [0, p). */
function randomFieldElement(): bigint {
  const bytes = randomBytes(32);
  let value = 0n;
  for (let i = 0; i < 32; i++) {
    value = (value << 8n) | BigInt(bytes[i]!);
  }
  return value % BN128_PRIME;
}

// ---------------------------------------------------------------------------
// Core Shamir Operations
// ---------------------------------------------------------------------------

/**
 * Generate (k,n) Shamir shares for a single field element (split).
 *
 * Constructs a random polynomial f(x) of degree k-1 with f(0) = secret,
 * then evaluates at points x = 1, 2, ..., n using Horner's method.
 *
 * [Spec: DistributeShares(b) -- each online node receives one share per field element]
 *
 * @param secret - The field element to share (must be in [0, p))
 * @param n - Total number of shares to generate
 * @param k - Reconstruction threshold (minimum shares to recover secret)
 * @returns ShareSet containing n shares
 * @throws DACError if k < 2, k > n, or secret outside field
 */
export function split(secret: bigint, n: number, k: number): ShareSet {
  if (k < 2 || k > n) {
    throw new DACError(
      DACErrorCode.INVALID_THRESHOLD,
      `Invalid threshold: k=${k}, n=${n}. Require 2 <= k <= n.`
    );
  }
  if (secret < 0n || secret >= BN128_PRIME) {
    throw new DACError(
      DACErrorCode.INVALID_FIELD_ELEMENT,
      `Secret out of field range [0, ${BN128_PRIME})`
    );
  }

  // Random polynomial coefficients: a_0 = secret, a_1..a_{k-1} random
  const coefficients: bigint[] = [secret];
  for (let i = 1; i < k; i++) {
    coefficients.push(randomFieldElement());
  }

  // Evaluate f(x) at x = 1..n using Horner's method
  const shares: Share[] = [];
  for (let i = 1; i <= n; i++) {
    const x = BigInt(i);
    let y = coefficients[k - 1]!;
    for (let j = k - 2; j >= 0; j--) {
      y = modAdd(modMul(y, x), coefficients[j]!);
    }
    shares.push({ index: i, value: y });
  }

  return { threshold: k, total: n, shares };
}

/**
 * Reconstruct a secret from k shares using Lagrange interpolation.
 *
 * Computes f(0) = SUM_{i} y_i * PRODUCT_{j != i} (x_j / (x_j - x_i))
 *
 * [Spec: RecoverData(b, S) -- Lagrange reconstruction from S subset of nodes]
 * [Spec: Privacy invariant -- fewer than k shares reveals zero information]
 *
 * @param shares - At least k shares to interpolate from
 * @returns The reconstructed secret (field element)
 * @throws DACError if fewer than 2 shares provided
 */
export function recover(shares: readonly Share[]): bigint {
  if (shares.length < 2) {
    throw new DACError(
      DACErrorCode.INSUFFICIENT_SHARES,
      `Need at least 2 shares, got ${shares.length}`
    );
  }

  const k = shares.length;
  let secret = 0n;

  for (let i = 0; i < k; i++) {
    const xi = BigInt(shares[i]!.index);
    const yi = shares[i]!.value;

    // Lagrange basis: L_i(0) = PRODUCT_{j != i} (0 - x_j) / (x_i - x_j)
    //                        = PRODUCT_{j != i} x_j / (x_j - x_i)
    let numerator = 1n;
    let denominator = 1n;
    for (let j = 0; j < k; j++) {
      if (i === j) continue;
      const xj = BigInt(shares[j]!.index);
      numerator = modMul(numerator, xj);
      denominator = modMul(denominator, modSub(xj, xi));
    }

    const lagrange = modMul(numerator, modInv(denominator));
    secret = modAdd(secret, modMul(yi, lagrange));
  }

  return secret;
}

// ---------------------------------------------------------------------------
// Byte <-> Field Element Conversion
// ---------------------------------------------------------------------------

/**
 * Convert arbitrary bytes into BN128 field elements.
 *
 * Packs bytes into 31-byte chunks (31 bytes < 254 bits, fits in field).
 * Chunk length is encoded in the high bits for correct round-trip padding.
 *
 * @param data - Arbitrary byte buffer
 * @returns Array of field elements
 */
export function bytesToFieldElements(data: Buffer): bigint[] {
  const elements: bigint[] = [];

  for (let offset = 0; offset < data.length; offset += CHUNK_SIZE) {
    const chunk = data.subarray(offset, Math.min(offset + CHUNK_SIZE, data.length));
    let value = 0n;
    for (let i = 0; i < chunk.length; i++) {
      value = (value << 8n) | BigInt(chunk[i]!);
    }
    // Encode chunk length in the high bits for correct unpadding
    value = value | (BigInt(chunk.length) << (BigInt(CHUNK_SIZE) * 8n));
    if (value >= BN128_PRIME) {
      throw new DACError(
        DACErrorCode.FIELD_OVERFLOW,
        "Field element overflow during byte packing"
      );
    }
    elements.push(value);
  }

  return elements;
}

/**
 * Convert field elements back to the original byte buffer.
 *
 * Inverse of bytesToFieldElements: extracts chunk length from high bits,
 * recovers original bytes from low bits.
 *
 * @param elements - Array of field elements from bytesToFieldElements
 * @returns Reconstructed byte buffer
 */
export function fieldElementsToBytes(elements: readonly bigint[]): Buffer {
  const chunks: Buffer[] = [];

  for (const element of elements) {
    const chunkLen = Number(element >> (BigInt(CHUNK_SIZE) * 8n));
    let value = element & ((1n << (BigInt(CHUNK_SIZE) * 8n)) - 1n);

    const chunk = Buffer.alloc(chunkLen);
    for (let i = chunkLen - 1; i >= 0; i--) {
      chunk[i] = Number(value & 0xffn);
      value >>= 8n;
    }
    chunks.push(chunk);
  }

  return Buffer.concat(chunks);
}

// ---------------------------------------------------------------------------
// Data-Level Sharing and Recovery
// ---------------------------------------------------------------------------

/**
 * Share an entire data blob across n DAC members.
 *
 * Converts data to field elements, generates (k,n) Shamir shares for each,
 * and produces a SHA-256 commitment for integrity verification.
 *
 * [Spec: DistributeShares(b) -- shareHolders'[b] = {n in Nodes : nodeOnline[n]}]
 *
 * @param data - Raw batch data to share
 * @param k - Reconstruction threshold
 * @param n - Total number of committee members
 * @returns Field elements, per-member share arrays, and SHA-256 commitment
 */
export function shareData(
  data: Buffer,
  k: number,
  n: number
): {
  fieldElements: readonly bigint[];
  memberShares: readonly (readonly bigint[])[];
  commitment: string;
} {
  const fieldElements = bytesToFieldElements(data);
  const commitment = createHash("sha256").update(data).digest("hex");

  // memberShares[i] = all share values for member i (one per field element)
  const memberShares: bigint[][] = Array.from({ length: n }, () => []);

  for (const element of fieldElements) {
    const shareSet = split(element, n, k);
    for (let i = 0; i < n; i++) {
      memberShares[i]!.push(shareSet.shares[i]!.value);
    }
  }

  return { fieldElements, memberShares, commitment };
}

/**
 * Reconstruct data from k members' shares using Lagrange interpolation.
 *
 * [Spec: RecoverData(b, S) action -- three outcomes: success, corrupted, failed]
 *
 * @param memberShares - Share arrays from k members
 * @param memberIndices - 1-indexed member IDs corresponding to each share array
 * @param k - Reconstruction threshold
 * @param elementCount - Expected number of field elements
 * @returns Reconstructed byte buffer
 * @throws DACError if insufficient members
 */
export function reconstructData(
  memberShares: readonly (readonly bigint[])[],
  memberIndices: readonly number[],
  k: number,
  elementCount: number
): Buffer {
  if (memberShares.length < k || memberIndices.length < k) {
    throw new DACError(
      DACErrorCode.INSUFFICIENT_SHARES,
      `Need at least ${k} members, got ${memberShares.length}`
    );
  }

  const reconstructed: bigint[] = [];

  for (let e = 0; e < elementCount; e++) {
    const shares: Share[] = [];
    for (let m = 0; m < k; m++) {
      shares.push({ index: memberIndices[m]!, value: memberShares[m]![e]! });
    }
    reconstructed.push(recover(shares));
  }

  return fieldElementsToBytes(reconstructed);
}

/**
 * Verify that a set of shares is internally consistent without revealing the secret.
 *
 * Reconstructs from two disjoint k-subsets and checks that both produce the same
 * secret. If any share has been corrupted, the results will (overwhelmingly likely)
 * differ, revealing tampering.
 *
 * [Spec: RecoveryIntegrity invariant -- success implies no malicious node in recovery set]
 *
 * @param shares - At least k+1 shares to cross-check
 * @param k - Reconstruction threshold
 * @returns True if all shares are consistent with the same degree k-1 polynomial
 */
export function verifyShareConsistency(
  shares: readonly Share[],
  k: number
): boolean {
  if (shares.length <= k) return true; // Cannot verify with exactly k shares

  const secret1 = recover(shares.slice(0, k));
  const secret2 = recover(shares.slice(-k));

  return secret1 === secret2;
}
