/// Deploy BasisRollupHarness with enterprise initialization and dummy VK.
/// This harness skips ZK proof verification, using the commitment-based model
/// (off-chain Rust prover verifies proofs before submission, L1 accepts them).
///
/// Usage: npx hardhat run scripts/deploy-rollup-harness.ts --network basis

import { ethers } from "hardhat";

const ENTERPRISE_REGISTRY = "0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5";
const GENESIS_ROOT = "0x051bd9624f8e73bd4b90264dde147423adb94c1933487669ec269afb1f80bbf4";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=== Deploy BasisRollupHarness ===\n");
  console.log("Deployer:", deployer.address);
  console.log("Chain ID:", (await ethers.provider.getNetwork()).chainId.toString());

  // Deploy harness
  console.log("\n[1/3] Deploying BasisRollupHarness...");
  const Harness = await ethers.getContractFactory("BasisRollupHarness");
  const rollup = await Harness.deploy(ENTERPRISE_REGISTRY);
  await rollup.waitForDeployment();
  const addr = await rollup.getAddress();
  console.log("  Deployed at:", addr);

  // Set dummy VK (required by proveBatch check)
  // IC length = 1 means 0 public signals accepted (we'll override anyway)
  console.log("\n[2/3] Setting verifying key...");
  const g1 = [1n, 2n] as [bigint, bigint];
  const g2 = [[1n, 0n], [0n, 1n]] as [[bigint, bigint], [bigint, bigint]];
  // IC with 4 entries: IC.length = publicSignals.length + 1
  // Our submitter sends 3 public signals (from proof bytes), so IC needs 4 entries
  const ic: [bigint, bigint][] = [[1n, 2n], [1n, 2n], [1n, 2n], [1n, 2n]];
  const vkTx = await rollup.setVerifyingKey(g1, g2, g2, g2, ic);
  await vkTx.wait();
  console.log("  VK set (IC length: 4, signals: 3)");

  // Initialize enterprise
  console.log("\n[3/3] Initializing enterprise...");
  const initTx = await rollup.initializeEnterprise(deployer.address, GENESIS_ROOT);
  await initTx.wait();
  console.log("  Enterprise initialized with genesis root:", GENESIS_ROOT);

  // Verify
  const root = await rollup.getCurrentRoot(deployer.address);
  const vkSet = await rollup.verifyingKeySet();
  console.log("\n=== Verification ===");
  console.log("  currentRoot:", root);
  console.log("  rootMatch:", root === GENESIS_ROOT);
  console.log("  verifyingKeySet:", vkSet);

  console.log("\n=== SUCCESS ===");
  console.log("BasisRollupHarness:", addr);
  console.log("Use this address for BASIS_ROLLUP_ADDRESS env var");
}

main()
  .then(() => process.exit(0))
  .catch((e) => { console.error("FAILED:", e.message || e); process.exit(1); });
