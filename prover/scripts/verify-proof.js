const snarkjs = require("snarkjs");
const fs = require("fs");
const path = require("path");

/// Verifies a Groth16 proof locally before submitting to the on-chain verifier.
/// This is a sanity check to ensure the proof is valid before paying for an on-chain transaction.
async function main() {
  const buildDir = path.join(__dirname, "..", "build");

  console.log("=== Verifying ZK Proof (local) ===\n");

  const vKeyPath = path.join(buildDir, "verification_key.json");
  const proofPath = path.join(buildDir, "proof.json");
  const publicPath = path.join(buildDir, "public.json");

  if (!fs.existsSync(vKeyPath) || !fs.existsSync(proofPath) || !fs.existsSync(publicPath)) {
    console.log("Missing files. Run setup and prove first:");
    console.log("  npm run setup");
    console.log("  npm run prove");
    return;
  }

  const vKey = JSON.parse(fs.readFileSync(vKeyPath));
  const proof = JSON.parse(fs.readFileSync(proofPath));
  const publicSignals = JSON.parse(fs.readFileSync(publicPath));

  console.log("Verifying proof...");
  const isValid = await snarkjs.groth16.verify(vKey, publicSignals, proof);

  if (isValid) {
    console.log("\nResult: VALID");
    console.log("The proof correctly attests that the batch of transactions is valid.");
    console.log("This proof can now be submitted to ZKVerifier.sol on Basis Network L1.");
  } else {
    console.log("\nResult: INVALID");
    console.log("The proof failed verification. Check inputs and circuit.");
  }
}

main().catch(console.error);
