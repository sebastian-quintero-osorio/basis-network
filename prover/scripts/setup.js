const snarkjs = require("snarkjs");
const fs = require("fs");
const path = require("path");

/// Trusted setup script for the BatchVerifier circuit.
/// This performs the Powers of Tau ceremony and generates the proving/verification keys.
/// In production, a multi-party computation (MPC) ceremony would be used.
async function main() {
  const buildDir = path.join(__dirname, "..", "build");
  const potDir = path.join(__dirname, "..", "pot");

  if (!fs.existsSync(buildDir)) fs.mkdirSync(buildDir, { recursive: true });
  if (!fs.existsSync(potDir)) fs.mkdirSync(potDir, { recursive: true });

  console.log("=== ZK Trusted Setup for Basis Network ===\n");

  // Step 1: Powers of Tau ceremony (phase 1)
  console.log("Step 1: Starting Powers of Tau ceremony...");
  await snarkjs.powersOfTau.newAccumulator(14, path.join(potDir, "pot14_0000.ptau"));
  console.log("  - Initial accumulator created");

  await snarkjs.powersOfTau.contribute(
    path.join(potDir, "pot14_0000.ptau"),
    path.join(potDir, "pot14_0001.ptau"),
    "Basis Network Contribution 1",
    "basis-network-entropy-seed-" + Date.now()
  );
  console.log("  - Contribution added");

  // Step 2: Prepare phase 2
  console.log("\nStep 2: Preparing phase 2...");
  await snarkjs.powersOfTau.preparePhase2(
    path.join(potDir, "pot14_0001.ptau"),
    path.join(potDir, "pot14_final.ptau")
  );
  console.log("  - Phase 2 prepared");

  // Step 3: Generate zkey (circuit-specific setup)
  // NOTE: The circuit must be compiled first with circom
  const r1csPath = path.join(buildDir, "batch_verifier.r1cs");
  if (!fs.existsSync(r1csPath)) {
    console.log("\nWARNING: Circuit not compiled yet.");
    console.log("Run the following command first:");
    console.log("  circom circuits/batch_verifier.circom --r1cs --wasm --sym -o build/");
    console.log("\nThen run this setup script again.");
    return;
  }

  console.log("\nStep 3: Generating proving key (zkey)...");
  await snarkjs.zKey.newZKey(
    r1csPath,
    path.join(potDir, "pot14_final.ptau"),
    path.join(buildDir, "batch_verifier_0000.zkey")
  );

  await snarkjs.zKey.contribute(
    path.join(buildDir, "batch_verifier_0000.zkey"),
    path.join(buildDir, "batch_verifier_final.zkey"),
    "Basis Network zKey Contribution",
    "basis-zkey-entropy-" + Date.now()
  );
  console.log("  - Proving key generated");

  // Step 4: Export verification key
  console.log("\nStep 4: Exporting verification key...");
  const vKey = await snarkjs.zKey.exportVerificationKey(
    path.join(buildDir, "batch_verifier_final.zkey")
  );
  fs.writeFileSync(
    path.join(buildDir, "verification_key.json"),
    JSON.stringify(vKey, null, 2)
  );
  console.log("  - Verification key exported to build/verification_key.json");

  console.log("\n=== Setup Complete ===");
  console.log("Files generated:");
  console.log("  - pot/pot14_final.ptau (Powers of Tau)");
  console.log("  - build/batch_verifier_final.zkey (Proving key)");
  console.log("  - build/verification_key.json (Verification key)");
}

main().catch(console.error);
