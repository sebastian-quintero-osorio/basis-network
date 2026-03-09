const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

/// Exports the Groth16 verifier as a Solidity contract.
/// The generated contract can be deployed to Basis Network L1 to verify proofs on-chain.
/// Note: For Basis Network, we use a custom ZKVerifier.sol that wraps this logic
/// with enterprise authorization checks.
async function main() {
  const buildDir = path.join(__dirname, "..", "build");

  console.log("=== Exporting Solidity Verifier ===\n");

  const zkeyPath = path.join(buildDir, "batch_verifier_final.zkey");
  if (!fs.existsSync(zkeyPath)) {
    console.log("Missing zkey. Run setup first: npm run setup");
    return;
  }

  console.log("Exporting Solidity verifier from zkey...");
  execSync(
    `npx snarkjs zkey export solidityverifier build/batch_verifier_final.zkey build/Groth16Verifier.sol`,
    { stdio: "inherit", cwd: path.join(__dirname, "..") }
  );

  const outputPath = path.join(buildDir, "Groth16Verifier.sol");
  console.log(`\nSolidity verifier exported to: ${outputPath}`);
  console.log("This contract provides the raw Groth16 verification logic.");
  console.log("ZKVerifier.sol in contracts/verification/ wraps this with enterprise checks.");
}

main().catch(console.error);
