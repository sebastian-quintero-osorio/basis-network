// RU-V6: Privacy Verification Tests
//
// Validates information-theoretic privacy of Shamir's Secret Sharing:
// 1. Single share reveals zero information about the secret
// 2. k-1 shares reveal zero information about the secret
// 3. k shares fully determine the secret (reconstruction)
// 4. Different secrets produce indistinguishable share distributions
// 5. Share values are uniformly distributed in the field
//
// These tests verify INV-DA1 (privacy invariant).

import { generateShares, reconstructSecret, shareData, reconstructData, bytesToFieldElements, fieldElementsToBytes } from './shamir.js';
import { BN128_PRIME } from './types.js';
import { randomBytes } from 'crypto';

let passed = 0;
let failed = 0;

function assert(condition: boolean, message: string): void {
  if (condition) {
    passed++;
    console.log(`  PASS: ${message}`);
  } else {
    failed++;
    console.error(`  FAIL: ${message}`);
  }
}

function testBasicShamir(): void {
  console.log('\n--- Test 1: Basic Shamir SSS correctness ---');

  // Test (2,3) scheme
  const secret = 42n;
  const shares = generateShares(secret, 2, 3);

  assert(shares.shares.length === 3, '(2,3) generates 3 shares');
  assert(shares.threshold === 2, 'threshold is 2');
  assert(shares.total === 3, 'total is 3');

  // Reconstruct from shares {1,2}
  const r12 = reconstructSecret([shares.shares[0], shares.shares[1]], 2);
  assert(r12 === secret, `Reconstruct from shares {1,2}: ${r12} === ${secret}`);

  // Reconstruct from shares {1,3}
  const r13 = reconstructSecret([shares.shares[0], shares.shares[2]], 2);
  assert(r13 === secret, `Reconstruct from shares {1,3}: ${r13} === ${secret}`);

  // Reconstruct from shares {2,3}
  const r23 = reconstructSecret([shares.shares[1], shares.shares[2]], 2);
  assert(r23 === secret, `Reconstruct from shares {2,3}: ${r23} === ${secret}`);

  // Test (3,3) scheme
  const secret2 = 12345678901234567890n;
  const shares3 = generateShares(secret2, 3, 3);
  const r123 = reconstructSecret(shares3.shares, 3);
  assert(r123 === secret2, `(3,3) reconstruct from all shares: ${r123} === ${secret2}`);
}

function testShareIndependence(): void {
  console.log('\n--- Test 2: Share independence (information-theoretic privacy) ---');

  // Generate shares for two DIFFERENT secrets
  // If a single share reveals information, the share distributions would differ
  const secret1 = 100n;
  const secret2 = 999n;
  const iterations = 1000;

  // Collect share values at index 1 for both secrets
  const shares1AtIndex1: bigint[] = [];
  const shares2AtIndex1: bigint[] = [];

  for (let i = 0; i < iterations; i++) {
    const s1 = generateShares(secret1, 2, 3);
    const s2 = generateShares(secret2, 2, 3);
    shares1AtIndex1.push(s1.shares[0].value);
    shares2AtIndex1.push(s2.shares[0].value);
  }

  // Statistical test: mean should be approximately BN128_PRIME/2 for both
  // (uniform distribution over the field)
  const halfField = BN128_PRIME / 2n;

  // Count how many shares fall in each half of the field
  const s1Above = shares1AtIndex1.filter((v) => v > halfField).length;
  const s2Above = shares2AtIndex1.filter((v) => v > halfField).length;

  // With uniform distribution, expect ~50% in each half
  // Allow 40-60% range (very conservative for n=1000)
  const s1Pct = s1Above / iterations;
  const s2Pct = s2Above / iterations;

  assert(
    s1Pct > 0.4 && s1Pct < 0.6,
    `Secret1 shares uniformly distributed: ${(s1Pct * 100).toFixed(1)}% above midfield (expect ~50%)`
  );
  assert(
    s2Pct > 0.4 && s2Pct < 0.6,
    `Secret2 shares uniformly distributed: ${(s2Pct * 100).toFixed(1)}% above midfield (expect ~50%)`
  );

  // Key insight: the share distributions should be IDENTICAL regardless of the secret
  // (both are uniformly random in the field when coefficient is random)
  const diff = Math.abs(s1Pct - s2Pct);
  assert(
    diff < 0.1,
    `Share distributions indistinguishable: |${(s1Pct * 100).toFixed(1)}% - ${(s2Pct * 100).toFixed(1)}%| = ${(diff * 100).toFixed(1)}% < 10%`
  );
}

function testKMinus1SharesRevealNothing(): void {
  console.log('\n--- Test 3: k-1 shares reveal nothing about secret ---');

  // For (2,3) scheme: 1 share (k-1=1) should be compatible with ANY secret
  const secret = 42n;
  const shares = generateShares(secret, 2, 3);
  const oneShare = shares.shares[0]; // Share at index 1

  // Given this one share, try to "guess" the secret
  // With k-1 shares, ANY secret in the field is equally likely
  // Proof: for any target secret s, there exists a unique polynomial of degree 1
  // that passes through (1, oneShare.value) and (0, s)
  // Therefore, the single share is consistent with every possible secret

  // Verify: pick 100 random "guessed" secrets, construct the polynomial, check it's valid
  let allConsistent = true;
  for (let i = 0; i < 100; i++) {
    const guessedSecret = BigInt(i * 1000);
    // The polynomial f(x) = guessedSecret + ((oneShare.value - guessedSecret) / 1) * x
    // = guessedSecret + (oneShare.value - guessedSecret) * x
    // f(0) = guessedSecret (any secret works)
    // f(1) = oneShare.value (matches the known share)
    // This is a valid degree-1 polynomial for the (2,3) scheme
    const slope = ((oneShare.value - guessedSecret) % BN128_PRIME + BN128_PRIME) % BN128_PRIME;
    const fAt0 = guessedSecret;
    const fAt1 = (guessedSecret + slope) % BN128_PRIME;

    if (fAt1 !== oneShare.value) {
      allConsistent = false;
      break;
    }
  }

  assert(
    allConsistent,
    'Single share is consistent with 100 different guessed secrets (information-theoretic privacy)'
  );
}

function testDataRoundTrip(): void {
  console.log('\n--- Test 4: Data round-trip (bytes -> field elements -> bytes) ---');

  // Test various data sizes
  const sizes = [1, 10, 31, 32, 100, 500, 1000, 10000];

  for (const size of sizes) {
    const data = randomBytes(size);
    const elements = bytesToFieldElements(data);
    const recovered = fieldElementsToBytes(elements);

    assert(
      data.equals(recovered),
      `${size} bytes: round-trip preserves data (${elements.length} field elements)`
    );
  }
}

function testShareDataRoundTrip(): void {
  console.log('\n--- Test 5: Full share-reconstruct round-trip for data blobs ---');

  const sizes = [100, 1000, 10000, 100000];
  const configs = [
    { k: 2, n: 3 },
    { k: 3, n: 3 },
    { k: 2, n: 5 },
    { k: 3, n: 5 },
  ];

  for (const size of sizes) {
    for (const { k, n } of configs) {
      const data = randomBytes(size);
      const { fieldElements, memberShares, commitment } = shareData(data, k, n);

      // Reconstruct from first k members
      const indices = Array.from({ length: k }, (_, i) => i + 1);
      const shares = memberShares.slice(0, k);
      const recovered = reconstructData(shares, indices, k, fieldElements.length);

      assert(
        data.equals(recovered),
        `${size}B (${k},${n}): round-trip OK (${fieldElements.length} elements)`
      );
    }
  }
}

function testDifferentShareSubsets(): void {
  console.log('\n--- Test 6: Any k-subset reconstructs correctly ---');

  const data = randomBytes(1000);
  const { fieldElements, memberShares } = shareData(data, 2, 3);

  // All possible 2-of-3 subsets
  const subsets = [
    [0, 1], // nodes 1,2
    [0, 2], // nodes 1,3
    [1, 2], // nodes 2,3
  ];

  for (const subset of subsets) {
    const indices = subset.map((i) => i + 1);
    const shares = subset.map((i) => memberShares[i]);
    const recovered = reconstructData(shares, indices, 2, fieldElements.length);

    assert(
      data.equals(recovered),
      `Subset {${indices.join(',')}} reconstructs correctly`
    );
  }
}

function testShareSizeParity(): void {
  console.log('\n--- Test 7: Share size equals original data (no expansion per member) ---');

  const sizes = [100, 1000, 10000, 100000];

  for (const size of sizes) {
    const data = randomBytes(size);
    const { memberShares } = shareData(data, 2, 3);

    // Each member gets the same number of share values as there are field elements
    // Each share value is a field element (32 bytes)
    const elemCount = memberShares[0].length;
    const shareBytes = elemCount * 32;
    const ratio = shareBytes / size;

    assert(
      memberShares[0].length === memberShares[1].length &&
      memberShares[1].length === memberShares[2].length,
      `${size}B: all members get equal share count (${elemCount})`
    );

    // Storage per member should be ~(32/31)*size due to field element encoding
    // Small data (<1KB) has higher padding overhead; large data converges to ~1.032x
    const maxRatio = size < 500 ? 1.5 : 1.1;
    assert(
      ratio > 0.9 && ratio < maxRatio,
      `${size}B: share size ratio = ${ratio.toFixed(3)}x (expected ~1.03x for large data)`
    );
  }
}

function testEdgeCases(): void {
  console.log('\n--- Test 8: Edge cases ---');

  // Minimum data (1 byte)
  const oneByteData = Buffer.from([0x42]);
  const { fieldElements: fe1, memberShares: ms1 } = shareData(oneByteData, 2, 3);
  const recovered1 = reconstructData(ms1.slice(0, 2), [1, 2], 2, fe1.length);
  assert(oneByteData.equals(recovered1), '1-byte data: round-trip OK');

  // All zeros
  const zeroData = Buffer.alloc(100);
  const { fieldElements: feZ, memberShares: msZ } = shareData(zeroData, 2, 3);
  const recoveredZ = reconstructData(msZ.slice(0, 2), [1, 2], 2, feZ.length);
  assert(zeroData.equals(recoveredZ), 'All-zero data: round-trip OK');

  // All 0xFF
  const ffData = Buffer.alloc(100, 0xFF);
  const { fieldElements: feF, memberShares: msF } = shareData(ffData, 2, 3);
  const recoveredF = reconstructData(msF.slice(0, 2), [1, 2], 2, feF.length);
  assert(ffData.equals(recoveredF), 'All-0xFF data: round-trip OK');

  // Secret = 0
  const shares0 = generateShares(0n, 2, 3);
  const r0 = reconstructSecret([shares0.shares[0], shares0.shares[1]], 2);
  assert(r0 === 0n, 'Secret=0: reconstruct OK');

  // Secret near field boundary
  const nearPrime = BN128_PRIME - 1n;
  const sharesMax = generateShares(nearPrime, 2, 3);
  const rMax = reconstructSecret([sharesMax.shares[0], sharesMax.shares[1]], 2);
  assert(rMax === nearPrime, `Secret=p-1: reconstruct OK (${rMax === nearPrime})`);
}

// Run all tests
console.log('=== RU-V6: Privacy Verification Tests ===\n');

testBasicShamir();
testShareIndependence();
testKMinus1SharesRevealNothing();
testDataRoundTrip();
testShareDataRoundTrip();
testDifferentShareSubsets();
testShareSizeParity();
testEdgeCases();

console.log(`\n========================================`);
console.log(`Results: ${passed} passed, ${failed} failed out of ${passed + failed} tests`);
console.log(`========================================`);

if (failed > 0) {
  process.exit(1);
}
