const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

/// Trusted setup script for the BatchVerifier circuit.
/// Uses snarkjs CLI for cross-platform compatibility.
/// In production, a multi-party computation (MPC) ceremony would be used.
function run(cmd) {
  console.log(`  $ ${cmd}`);
  execSync(cmd, { stdio: "inherit", cwd: path.join(__dirname, "..") });
}

async function main() {
  const buildDir = path.join(__dirname, "..", "build");
  const potDir = path.join(__dirname, "..", "pot");

  if (!fs.existsSync(buildDir)) fs.mkdirSync(buildDir, { recursive: true });
  if (!fs.existsSync(potDir)) fs.mkdirSync(potDir, { recursive: true });

  console.log("=== ZK Trusted Setup for Basis Network ===\n");

  // Step 1: Powers of Tau ceremony (phase 1)
  console.log("Step 1: Starting Powers of Tau ceremony...");
  run(`npx snarkjs powersoftau new bn128 14 pot/pot14_0000.ptau`);
  console.log("  - Initial accumulator created");

  run(`npx snarkjs powersoftau contribute pot/pot14_0000.ptau pot/pot14_0001.ptau --name="Basis Network Contribution 1" -e="basis-network-entropy-${Date.now()}"`);
  console.log("  - Contribution added");

  // Step 2: Prepare phase 2
  console.log("\nStep 2: Preparing phase 2...");
  run(`npx snarkjs powersoftau prepare phase2 pot/pot14_0001.ptau pot/pot14_final.ptau`);
  console.log("  - Phase 2 prepared");

  // Step 3: Generate zkey (circuit-specific setup)
  const r1csPath = path.join(buildDir, "batch_verifier.r1cs");
  if (!fs.existsSync(r1csPath)) {
    console.log("\nWARNING: Circuit not compiled yet.");
    console.log("Run: circom circuits/batch_verifier.circom --r1cs --wasm --sym -o build/");
    return;
  }

  console.log("\nStep 3: Generating proving key (zkey)...");
  run(`npx snarkjs groth16 setup build/batch_verifier.r1cs pot/pot14_final.ptau build/batch_verifier_0000.zkey`);

  run(`npx snarkjs zkey contribute build/batch_verifier_0000.zkey build/batch_verifier_final.zkey --name="Basis Network zKey Contribution" -e="basis-zkey-entropy-${Date.now()}"`);
  console.log("  - Proving key generated");

  // Step 4: Export verification key
  console.log("\nStep 4: Exporting verification key...");
  run(`npx snarkjs zkey export verificationkey build/batch_verifier_final.zkey build/verification_key.json`);
  console.log("  - Verification key exported to build/verification_key.json");

  console.log("\n=== Setup Complete ===");
  console.log("Files generated:");
  console.log("  - pot/pot14_final.ptau (Powers of Tau)");
  console.log("  - build/batch_verifier_final.zkey (Proving key)");
  console.log("  - build/verification_key.json (Verification key)");
}

main().catch(console.error);
