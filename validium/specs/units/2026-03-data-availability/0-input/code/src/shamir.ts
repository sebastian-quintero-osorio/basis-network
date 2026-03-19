// RU-V6: Shamir's Secret Sharing over BN128 scalar field
//
// Implements (k,n)-threshold secret sharing:
// - Share generation: polynomial evaluation at n points
// - Reconstruction: Lagrange interpolation from k shares
// - Field: BN128 scalar field (254-bit prime)
//
// Reference: Shamir, A. "How to Share a Secret." CACM 22(11):612-613, 1979.

import { BN128_PRIME, FIELD_ELEMENT_BYTES, type Share, type ShareSet } from './types.js';
import { createHash, randomBytes } from 'crypto';

/** Modular arithmetic over BN128 scalar field */
function modAdd(a: bigint, b: bigint): bigint {
  return ((a + b) % BN128_PRIME + BN128_PRIME) % BN128_PRIME;
}

function modSub(a: bigint, b: bigint): bigint {
  return ((a - b) % BN128_PRIME + BN128_PRIME) % BN128_PRIME;
}

function modMul(a: bigint, b: bigint): bigint {
  return ((a * b) % BN128_PRIME + BN128_PRIME) % BN128_PRIME;
}

/** Modular exponentiation via square-and-multiply */
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
  return modPow(a, BN128_PRIME - 2n, BN128_PRIME);
}

/** Generate a random field element in [0, BN128_PRIME) */
function randomFieldElement(): bigint {
  // Generate 32 random bytes, reduce modulo BN128_PRIME
  const bytes = randomBytes(32);
  let value = 0n;
  for (let i = 0; i < 32; i++) {
    value = (value << 8n) | BigInt(bytes[i]);
  }
  return value % BN128_PRIME;
}

/**
 * Generate (k,n) Shamir shares for a single field element.
 *
 * Constructs a random polynomial f(x) of degree k-1 with f(0) = secret,
 * then evaluates at points x = 1, 2, ..., n.
 */
export function generateShares(secret: bigint, k: number, n: number): ShareSet {
  if (k < 2 || k > n) {
    throw new Error(`Invalid threshold: k=${k}, n=${n}. Require 2 <= k <= n.`);
  }
  if (secret < 0n || secret >= BN128_PRIME) {
    throw new Error(`Secret out of field range: must be in [0, ${BN128_PRIME})`);
  }

  // Generate random coefficients a_1, ..., a_{k-1}
  const coefficients: bigint[] = [secret];
  for (let i = 1; i < k; i++) {
    coefficients.push(randomFieldElement());
  }

  // Evaluate polynomial at points 1..n using Horner's method
  const shares: Share[] = [];
  for (let i = 1; i <= n; i++) {
    const x = BigInt(i);
    let y = coefficients[k - 1];
    for (let j = k - 2; j >= 0; j--) {
      y = modAdd(modMul(y, x), coefficients[j]);
    }
    shares.push({ index: i, value: y });
  }

  return { threshold: k, total: n, shares };
}

/**
 * Reconstruct secret from k shares using Lagrange interpolation.
 *
 * Computes f(0) = SUM_{i} y_i * PRODUCT_{j != i} (x_j / (x_j - x_i))
 */
export function reconstructSecret(shares: Share[], k: number): bigint {
  if (shares.length < k) {
    throw new Error(`Need at least ${k} shares, got ${shares.length}`);
  }

  // Use first k shares
  const used = shares.slice(0, k);
  let secret = 0n;

  for (let i = 0; i < k; i++) {
    const xi = BigInt(used[i].index);
    const yi = used[i].value;

    // Compute Lagrange basis polynomial L_i(0) = PRODUCT_{j != i} (0 - x_j) / (x_i - x_j)
    //                                          = PRODUCT_{j != i} (-x_j) / (x_i - x_j)
    //                                          = PRODUCT_{j != i} x_j / (x_j - x_i)
    let numerator = 1n;
    let denominator = 1n;
    for (let j = 0; j < k; j++) {
      if (i === j) continue;
      const xj = BigInt(used[j].index);
      numerator = modMul(numerator, xj);
      denominator = modMul(denominator, modSub(xj, xi));
    }

    const lagrange = modMul(numerator, modInv(denominator));
    secret = modAdd(secret, modMul(yi, lagrange));
  }

  return secret;
}

/**
 * Convert arbitrary bytes into field elements.
 * Packs bytes into 31-byte chunks (to fit within 254-bit field).
 */
export function bytesToFieldElements(data: Buffer): bigint[] {
  const CHUNK_SIZE = 31; // 31 bytes < 254 bits, guaranteed to fit in field
  const elements: bigint[] = [];

  for (let offset = 0; offset < data.length; offset += CHUNK_SIZE) {
    const chunk = data.subarray(offset, Math.min(offset + CHUNK_SIZE, data.length));
    let value = 0n;
    for (let i = 0; i < chunk.length; i++) {
      value = (value << 8n) | BigInt(chunk[i]);
    }
    // Encode chunk length in the high bits to handle padding correctly
    value = value | (BigInt(chunk.length) << (BigInt(CHUNK_SIZE) * 8n));
    // Ensure value is within field (guaranteed since 32 bytes max and field is 254 bits)
    if (value >= BN128_PRIME) {
      throw new Error('Field element overflow -- should not happen with 31-byte chunks');
    }
    elements.push(value);
  }

  return elements;
}

/**
 * Convert field elements back to bytes.
 */
export function fieldElementsToBytes(elements: bigint[]): Buffer {
  const CHUNK_SIZE = 31;
  const chunks: Buffer[] = [];

  for (const element of elements) {
    // Extract chunk length from high bits
    const chunkLen = Number(element >> (BigInt(CHUNK_SIZE) * 8n));
    // Extract data from low bits
    let value = element & ((1n << (BigInt(CHUNK_SIZE) * 8n)) - 1n);

    const chunk = Buffer.alloc(chunkLen);
    for (let i = chunkLen - 1; i >= 0; i--) {
      chunk[i] = Number(value & 0xFFn);
      value >>= 8n;
    }
    chunks.push(chunk);
  }

  return Buffer.concat(chunks);
}

/**
 * Generate shares for an entire data blob.
 * Returns n arrays of shares (one array per DAC member).
 */
export function shareData(
  data: Buffer,
  k: number,
  n: number
): { fieldElements: bigint[]; memberShares: bigint[][]; commitment: string } {
  const fieldElements = bytesToFieldElements(data);
  const commitment = createHash('sha256').update(data).digest('hex');

  // memberShares[i] = all share values for member i
  const memberShares: bigint[][] = Array.from({ length: n }, () => []);

  for (const element of fieldElements) {
    const shareSet = generateShares(element, k, n);
    for (let i = 0; i < n; i++) {
      memberShares[i].push(shareSet.shares[i].value);
    }
  }

  return { fieldElements, memberShares, commitment };
}

/**
 * Reconstruct data from k members' shares.
 */
export function reconstructData(
  memberShares: bigint[][],
  memberIndices: number[],
  k: number,
  elementCount: number
): Buffer {
  if (memberShares.length < k || memberIndices.length < k) {
    throw new Error(`Need at least ${k} members, got ${memberShares.length}`);
  }

  const reconstructed: bigint[] = [];

  for (let e = 0; e < elementCount; e++) {
    const shares: Share[] = [];
    for (let m = 0; m < k; m++) {
      shares.push({ index: memberIndices[m], value: memberShares[m][e] });
    }
    reconstructed.push(reconstructSecret(shares, k));
  }

  return fieldElementsToBytes(reconstructed);
}

/**
 * Verify that a share is consistent with other shares (without revealing the secret).
 * Uses the property that k+1 shares should NOT be consistent with a degree k-1 polynomial
 * if one share is altered.
 * For verification: reconstruct from different subsets and check consistency.
 */
export function verifyShareConsistency(
  shares: Share[],
  k: number
): boolean {
  if (shares.length <= k) return true; // Cannot verify with exactly k shares

  // Reconstruct from first k shares
  const secret1 = reconstructSecret(shares.slice(0, k), k);

  // Reconstruct from last k shares
  const secret2 = reconstructSecret(shares.slice(-k), k);

  return secret1 === secret2;
}
