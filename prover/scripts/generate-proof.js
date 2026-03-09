const snarkjs = require("snarkjs");
const fs = require("fs");
const path = require("path");

/// Generates a Groth16 proof for a batch of enterprise transactions.
/// This simulates what an enterprise prover would do in production:
/// take a batch of private transactions, generate a proof, and prepare
/// it for on-chain verification via ZKVerifier.sol.
async function main() {
  const buildDir = path.join(__dirname, "..", "build");

  console.log("=== Generating ZK Proof for Basis Network ===\n");

  // Check prerequisites
  const wasmPath = path.join(buildDir, "batch_verifier_js", "batch_verifier.wasm");
  const zkeyPath = path.join(buildDir, "batch_verifier_final.zkey");

  if (!fs.existsSync(wasmPath) || !fs.existsSync(zkeyPath)) {
    console.log("Prerequisites missing. Run setup first:");
    console.log("  1. circom circuits/batch_verifier.circom --r1cs --wasm --sym -o build/");
    console.log("  2. npm run setup");
    return;
  }

  // Sample enterprise transaction data (private inputs)
  // In production, these would come from the enterprise's off-chain system
  const input = {
    // Public inputs
    batchRoot: "0", // Will be computed
    batchSize: "4",
    enterpriseId: "12345",

    // Private inputs (witness) - the actual transaction data stays private
    txHashes: [
      "1234567890123456789",
      "9876543210987654321",
      "1111111111111111111",
      "2222222222222222222",
    ],
    txAmounts: [
      "5000000",  // 5M COP sale
      "1500000",  // 1.5M COP sale
      "300000",   // 300K COP inventory adjustment
      "10000000", // 10M COP supplier payment
    ],
  };

  // Compute the batch root (must match circuit logic)
  // The circuit uses chained Poseidon hashes
  const { buildPoseidon } = require("circomlibjs");
  const poseidon = await buildPoseidon();

  let currentHash = BigInt(input.txHashes[0]);
  for (let i = 1; i < input.txHashes.length; i++) {
    const hashResult = poseidon([currentHash, BigInt(input.txHashes[i])]);
    currentHash = poseidon.F.toObject(hashResult);
  }
  input.batchRoot = currentHash.toString();

  console.log("Input prepared:");
  console.log(`  Batch size: ${input.batchSize}`);
  console.log(`  Enterprise ID: ${input.enterpriseId}`);
  console.log(`  Batch root: ${input.batchRoot}`);
  console.log(`  Transaction hashes: [private]`);
  console.log(`  Transaction amounts: [private]\n`);

  // Generate the proof
  console.log("Generating Groth16 proof...");
  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    input,
    wasmPath,
    zkeyPath
  );

  console.log("Proof generated successfully!\n");

  // Save proof and public signals
  fs.writeFileSync(
    path.join(buildDir, "proof.json"),
    JSON.stringify(proof, null, 2)
  );
  fs.writeFileSync(
    path.join(buildDir, "public.json"),
    JSON.stringify(publicSignals, null, 2)
  );

  console.log("Files saved:");
  console.log("  - build/proof.json");
  console.log("  - build/public.json");

  // Format for on-chain submission
  const calldata = await snarkjs.groth16.exportSolidityCallData(proof, publicSignals);
  fs.writeFileSync(
    path.join(buildDir, "calldata.txt"),
    calldata
  );
  console.log("  - build/calldata.txt (formatted for Solidity)");

  console.log("\nPublic signals (visible on-chain):");
  publicSignals.forEach((s, i) => console.log(`  [${i}]: ${s}`));
  console.log("\nPrivate data (transaction details) remains hidden.");
}

main().catch(console.error);
