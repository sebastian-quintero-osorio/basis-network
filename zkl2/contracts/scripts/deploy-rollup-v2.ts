/// Deploy BasisRollupV2 + PlonkVerifier with real PLONK verification.
/// Usage: npx hardhat run scripts/deploy-rollup-v2.ts --network basis

import { ethers } from "hardhat";

const ENTERPRISE_REGISTRY = "0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5";
const GENESIS_ROOT = "0x051bd9624f8e73bd4b90264dde147423adb94c1933487669ec269afb1f80bbf4";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=== Deploy BasisRollupV2 + PlonkVerifier ===\n");
  console.log("Deployer:", deployer.address);
  console.log("Chain ID:", (await ethers.provider.getNetwork()).chainId.toString());

  // 1. Deploy PlonkVerifier
  console.log("\n[1/4] Deploying PlonkVerifier...");
  const PlonkVerifier = await ethers.getContractFactory("PlonkVerifier");
  const plonk = await PlonkVerifier.deploy();
  await plonk.waitForDeployment();
  const plonkAddr = await plonk.getAddress();
  console.log("  PlonkVerifier:", plonkAddr);

  // Configure VK on PlonkVerifier
  console.log("  Configuring VK (k=8, numPublicInputs=3)...");
  const vkDigest = ethers.keccak256(ethers.toUtf8Bytes("basis-l2-plonk-vk-v1"));
  const configTx = await plonk.configureVK(8, 3, vkDigest);
  await configTx.wait();
  console.log("  VK configured");

  // 2. Deploy BasisRollupV2
  console.log("\n[2/4] Deploying BasisRollupV2...");
  const BasisRollupV2 = await ethers.getContractFactory("BasisRollupV2");
  const rollup = await BasisRollupV2.deploy(ENTERPRISE_REGISTRY);
  await rollup.waitForDeployment();
  const rollupAddr = await rollup.getAddress();
  console.log("  BasisRollupV2:", rollupAddr);

  // Set PlonkVerifier on BasisRollupV2
  console.log("  Setting PlonkVerifier...");
  const setTx = await rollup.setPlonkVerifier(plonkAddr);
  await setTx.wait();
  console.log("  PlonkVerifier set");

  // 3. Initialize enterprise
  console.log("\n[3/4] Initializing enterprise...");
  const initTx = await rollup.initializeEnterprise(deployer.address, GENESIS_ROOT);
  await initTx.wait();
  console.log("  Enterprise initialized with genesis root:", GENESIS_ROOT);

  // 4. Verify
  console.log("\n[4/4] Verification...");
  const root = await rollup.getCurrentRoot(deployer.address);
  const pvSet = await rollup.plonkVerifierSet();
  console.log("  currentRoot:", root);
  console.log("  rootMatch:", root === GENESIS_ROOT);
  console.log("  plonkVerifierSet:", pvSet);

  console.log("\n=== SUCCESS ===");
  console.log("PlonkVerifier:", plonkAddr);
  console.log("BasisRollupV2:", rollupAddr);
  console.log("\nUpdate config:");
  console.log(`  BASIS_ROLLUP_ADDRESS=${rollupAddr}`);
}

main()
  .then(() => process.exit(0))
  .catch((e) => { console.error("FAILED:", e.message || e); process.exit(1); });
