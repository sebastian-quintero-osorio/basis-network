/// Deploy a fresh BasisRollup and initialize the enterprise with the real Poseidon genesis root.
///
/// Usage:
///   npx hardhat run scripts/deploy-fresh-rollup.ts --network basis

import { ethers } from "hardhat";

const ENTERPRISE_REGISTRY = "0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5";

// Real Poseidon SMT genesis root from Go node (computed by cmd/genesis-root)
const GENESIS_ROOT = "0x051bd9624f8e73bd4b90264dde147423adb94c1933487669ec269afb1f80bbf4";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=== Deploy Fresh BasisRollup + Initialize Enterprise ===\n");
  console.log("Deployer:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "LITHOS");
  console.log("Chain ID:", (await ethers.provider.getNetwork()).chainId.toString());
  console.log("");

  // Deploy BasisRollup
  console.log("[1/2] Deploying BasisRollup...");
  const BasisRollup = await ethers.getContractFactory("BasisRollup");
  const rollup = await BasisRollup.deploy(ENTERPRISE_REGISTRY);
  await rollup.waitForDeployment();
  const rollupAddr = await rollup.getAddress();
  console.log("  BasisRollup deployed at:", rollupAddr);

  // Initialize enterprise with real Poseidon genesis root
  console.log("\n[2/2] Initializing enterprise with Poseidon SMT genesis root...");
  console.log("  Enterprise:", deployer.address);
  console.log("  Genesis root:", GENESIS_ROOT);
  const tx = await rollup.initializeEnterprise(deployer.address, GENESIS_ROOT);
  const receipt = await tx.wait();
  console.log("  Gas used:", receipt!.gasUsed.toString());

  // Verify
  const currentRoot = await rollup.getCurrentRoot(deployer.address);
  if (currentRoot !== GENESIS_ROOT) {
    throw new Error(`Root mismatch after init: ${currentRoot} vs ${GENESIS_ROOT}`);
  }

  console.log("\n=== SUCCESS ===");
  console.log("BasisRollup:", rollupAddr);
  console.log("Enterprise initialized with correct Poseidon genesis root");
  console.log("");
  console.log("Update zkl2/node config with:");
  console.log(`  BASIS_ROLLUP=${rollupAddr}`);
  console.log(`  or set in config.yaml: contracts.basisRollup: "${rollupAddr}"`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("FAILED:", error.message || error);
    process.exit(1);
  });
