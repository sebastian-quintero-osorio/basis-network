/**
 * Hash Function Comparison Benchmark -- RU-V1 Experiment
 *
 * Compares Poseidon (circomlibjs) against a naive MiMC implementation
 * to validate the literature claim that Poseidon is faster in native JS.
 *
 * Also measures per-hash latency to establish baseline for SMT operations.
 */

// @ts-ignore
import { buildPoseidon } from "circomlibjs";
import { writeFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const RESULTS_DIR = join(__dirname, "..", "results");

const REPS = 1000;
const WARMUP = 100;

// BN128 scalar field prime
const P = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

interface HashBenchResult {
  name: string;
  totalTimeMs: number;
  perHashUs: number;
  hashesPerSecond: number;
  reps: number;
  sampleOutputHex: string;
}

/**
 * Minimal MiMC implementation over BN128 for comparison.
 * MiMC-Feistel with exponent 7 and 91 rounds (standard for BN254).
 * NOT for production use -- only for benchmarking.
 */
function mimcHash(left: bigint, right: bigint): bigint {
  const ROUNDS = 91;
  // Round constants (first few; in production these come from a seed)
  // We generate deterministically for benchmarking purposes
  const roundConstants: bigint[] = [];
  let c = 0n;
  for (let i = 0; i < ROUNDS; i++) {
    c = (c * 7n + 13n) % P;
    roundConstants.push(c);
  }

  let xL = left % P;
  let xR = right % P;

  for (let i = 0; i < ROUNDS; i++) {
    const t = (xL + roundConstants[i]) % P;
    // MiMC uses x^7 (or x^5) as S-box. Using x^7 for BN254.
    const t2 = (t * t) % P;
    const t4 = (t2 * t2) % P;
    const t7 = (t4 * t2 * t) % P;
    const temp = xR;
    xR = xL;
    xL = (temp + t7) % P;
  }

  return xL;
}

async function benchmarkPoseidon(): Promise<HashBenchResult> {
  const poseidon = await buildPoseidon();
  const F = poseidon.F;

  // Warmup
  for (let i = 0; i < WARMUP; i++) {
    const h = poseidon([BigInt(i), BigInt(i + 1)]);
    F.toObject(h);
  }

  // Measure
  const start = performance.now();
  let lastHash: bigint = 0n;

  for (let i = 0; i < REPS; i++) {
    const h = poseidon([BigInt(i), BigInt(i + 1)]);
    lastHash = F.toObject(h);
  }

  const elapsed = performance.now() - start;
  const perHashUs = (elapsed / REPS) * 1000;
  const hashesPerSecond = Math.round((REPS / elapsed) * 1000);

  return {
    name: "Poseidon (circomlibjs 0.1.7)",
    totalTimeMs: Number(elapsed.toFixed(2)),
    perHashUs: Number(perHashUs.toFixed(2)),
    hashesPerSecond,
    reps: REPS,
    sampleOutputHex: lastHash.toString(16).padStart(64, "0"),
  };
}

async function benchmarkMiMC(): Promise<HashBenchResult> {
  // Warmup
  for (let i = 0; i < WARMUP; i++) {
    mimcHash(BigInt(i), BigInt(i + 1));
  }

  // Measure
  const start = performance.now();
  let lastHash: bigint = 0n;

  for (let i = 0; i < REPS; i++) {
    lastHash = mimcHash(BigInt(i), BigInt(i + 1));
  }

  const elapsed = performance.now() - start;
  const perHashUs = (elapsed / REPS) * 1000;
  const hashesPerSecond = Math.round((REPS / elapsed) * 1000);

  return {
    name: "MiMC-Feistel (x^7, 91 rounds, BN128)",
    totalTimeMs: Number(elapsed.toFixed(2)),
    perHashUs: Number(perHashUs.toFixed(2)),
    hashesPerSecond,
    reps: REPS,
    sampleOutputHex: lastHash.toString(16).padStart(64, "0"),
  };
}

async function benchmarkPoseidonSingle(): Promise<HashBenchResult> {
  const poseidon = await buildPoseidon();
  const F = poseidon.F;

  // Warmup
  for (let i = 0; i < WARMUP; i++) {
    const h = poseidon([BigInt(i)]);
    F.toObject(h);
  }

  // Measure single-input Poseidon (used for key derivation)
  const start = performance.now();
  let lastHash: bigint = 0n;

  for (let i = 0; i < REPS; i++) {
    const h = poseidon([BigInt(i)]);
    lastHash = F.toObject(h);
  }

  const elapsed = performance.now() - start;
  const perHashUs = (elapsed / REPS) * 1000;
  const hashesPerSecond = Math.round((REPS / elapsed) * 1000);

  return {
    name: "Poseidon-1 (single input, key derivation)",
    totalTimeMs: Number(elapsed.toFixed(2)),
    perHashUs: Number(perHashUs.toFixed(2)),
    hashesPerSecond,
    reps: REPS,
    sampleOutputHex: lastHash.toString(16).padStart(64, "0"),
  };
}

async function benchmarkPoseidonChain32(): Promise<HashBenchResult> {
  const poseidon = await buildPoseidon();
  const F = poseidon.F;

  // Simulate a depth-32 Merkle path: 32 sequential hashes
  const CHAIN_REPS = Math.floor(REPS / 10); // Fewer reps since each is 32 hashes

  // Warmup
  for (let w = 0; w < 10; w++) {
    let current = BigInt(w);
    for (let d = 0; d < 32; d++) {
      const h = poseidon([current, BigInt(d)]);
      current = F.toObject(h);
    }
  }

  // Measure 32-hash chains (simulates Merkle proof verification)
  const chainTimes: number[] = [];
  let lastHash: bigint = 0n;

  for (let i = 0; i < CHAIN_REPS; i++) {
    const start = performance.now();
    let current = BigInt(i);
    for (let d = 0; d < 32; d++) {
      const h = poseidon([current, BigInt(d)]);
      current = F.toObject(h);
    }
    const elapsed = performance.now() - start;
    chainTimes.push(elapsed);
    lastHash = current;
  }

  const totalMs = chainTimes.reduce((a, b) => a + b, 0);
  const meanMs = totalMs / CHAIN_REPS;
  const perHashUs = (meanMs / 32) * 1000;

  return {
    name: "Poseidon-chain-32 (32 sequential hashes, simulates Merkle path)",
    totalTimeMs: Number(totalMs.toFixed(2)),
    perHashUs: Number(perHashUs.toFixed(2)),
    hashesPerSecond: Math.round(1000 / (meanMs / 32)),
    reps: CHAIN_REPS,
    sampleOutputHex: lastHash.toString(16).padStart(64, "0"),
  };
}

async function main() {
  console.log("=== Hash Function Comparison Benchmark ===");
  console.log(`Repetitions: ${REPS}`);
  console.log(`Warmup: ${WARMUP}`);
  console.log(`Field: BN128 (p = 218882...95617)`);
  console.log(`Node.js: ${process.version}`);
  console.log(`Platform: ${process.platform} ${process.arch}`);
  console.log(`Date: ${new Date().toISOString()}`);
  console.log();

  const results: HashBenchResult[] = [];

  // Benchmark Poseidon 2-to-1
  console.log("Benchmarking Poseidon (2-to-1)...");
  const poseidonResult = await benchmarkPoseidon();
  results.push(poseidonResult);
  console.log(`  ${poseidonResult.perHashUs} us/hash, ${poseidonResult.hashesPerSecond} hashes/s`);

  // Benchmark Poseidon single input
  console.log("Benchmarking Poseidon (1 input)...");
  const poseidon1Result = await benchmarkPoseidonSingle();
  results.push(poseidon1Result);
  console.log(`  ${poseidon1Result.perHashUs} us/hash, ${poseidon1Result.hashesPerSecond} hashes/s`);

  // Benchmark MiMC
  console.log("Benchmarking MiMC...");
  const mimcResult = await benchmarkMiMC();
  results.push(mimcResult);
  console.log(`  ${mimcResult.perHashUs} us/hash, ${mimcResult.hashesPerSecond} hashes/s`);

  // Benchmark Poseidon chain (32 hashes = Merkle path)
  console.log("Benchmarking Poseidon chain-32 (Merkle path simulation)...");
  const chainResult = await benchmarkPoseidonChain32();
  results.push(chainResult);
  console.log(`  ${chainResult.perHashUs} us/hash (per individual hash in chain)`);
  console.log(`  ${(chainResult.totalTimeMs / chainResult.reps).toFixed(2)} ms per 32-hash chain`);

  // Summary
  console.log("\n=== Summary ===");
  console.log("| Hash Function | us/hash | hashes/s |");
  console.log("|---|---|---|");
  for (const r of results) {
    console.log(`| ${r.name} | ${r.perHashUs} | ${r.hashesPerSecond.toLocaleString()} |`);
  }

  // Poseidon vs MiMC ratio
  const ratio = mimcResult.perHashUs / poseidonResult.perHashUs;
  console.log(`\nPoseidon vs MiMC speedup: ${ratio.toFixed(2)}x`);

  // Depth-32 Merkle path time estimate
  const merklePathMs = (poseidonResult.perHashUs * 32) / 1000;
  console.log(`Estimated depth-32 Merkle path time (Poseidon): ${merklePathMs.toFixed(2)} ms`);

  // Save results
  const output = {
    experiment: "hash-comparison",
    target: "validium",
    field: "BN128",
    reps: REPS,
    warmup: WARMUP,
    nodeVersion: process.version,
    platform: `${process.platform} ${process.arch}`,
    timestamp: new Date().toISOString(),
    results,
    analysis: {
      poseidonVsMimcSpeedup: Number(ratio.toFixed(2)),
      estimatedMerklePathMs: Number(merklePathMs.toFixed(2)),
    },
  };

  try {
    writeFileSync(
      join(RESULTS_DIR, "hash-comparison-results.json"),
      JSON.stringify(output, null, 2)
    );
    console.log(`\nResults saved to results/hash-comparison-results.json`);
  } catch (err) {
    const altPath = join(__dirname, "hash-comparison-results.json");
    writeFileSync(altPath, JSON.stringify(output, null, 2));
    console.log(`\nResults saved to ${altPath}`);
  }
}

main().catch(console.error);
