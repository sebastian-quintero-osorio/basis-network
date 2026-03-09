const snarkjs = require("snarkjs");
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

  const solidityVerifier = await snarkjs.zKey.exportSolidityVerifier(
    zkeyPath,
    { groth16: fs.readFileSync(
        path.join(__dirname, "..", "node_modules", "snarkjs", "templates", "verifier_groth16.sol.ejs"),
        "utf8"
      )
    }
  );

  const outputPath = path.join(buildDir, "Groth16Verifier.sol");
  fs.writeFileSync(outputPath, solidityVerifier);

  console.log(`Solidity verifier exported to: ${outputPath}`);
  console.log("This contract provides the raw Groth16 verification logic.");
  console.log("ZKVerifier.sol in contracts/verification/ wraps this with enterprise checks.");
}

main().catch(console.error);
