/// Deployment script for Basis Network zkEVM L2 settlement contracts.
///
/// Deploys all 6 contracts to the Basis Network L1 (Avalanche Subnet-EVM)
/// in the correct dependency order:
///
///   1. BasisVerifier    (proof verification -- no dependencies)
///   2. BasisRollup      (state root management -- depends on EnterpriseRegistry)
///   3. BasisBridge      (asset transfers -- depends on BasisRollup)
///   4. BasisDAC         (data availability -- no dependencies)
///   5. BasisAggregator  (proof aggregation -- no dependencies)
///   6. BasisHub         (cross-enterprise -- depends on EnterpriseRegistry)
///
/// Usage:
///   npx hardhat run scripts/deploy.ts --network basis
///
/// Prerequisites:
///   - DEPLOYER_KEY environment variable set in .env
///   - EnterpriseRegistry already deployed on L1 (from l1/contracts/)

import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // EnterpriseRegistry address from L1 deployment.
  const ENTERPRISE_REGISTRY = process.env.ENTERPRISE_REGISTRY_ADDRESS
    || "0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5";

  // Deployment parameters.
  const MAX_MIGRATION_STEPS = 1000;
  const ESCAPE_TIMEOUT = 7200;       // ~24 hours at 12s blocks
  const HUB_TIMEOUT_BLOCKS = 3600;   // ~12 hours at 12s blocks
  const DAC_THRESHOLD = 5;

  console.log("\n--- Deployment Parameters ---");
  console.log("Enterprise Registry:", ENTERPRISE_REGISTRY);
  console.log("Max Migration Steps:", MAX_MIGRATION_STEPS);
  console.log("Escape Timeout:", ESCAPE_TIMEOUT, "blocks");
  console.log("Hub Timeout:", HUB_TIMEOUT_BLOCKS, "blocks");
  console.log("DAC Threshold:", DAC_THRESHOLD, "of", "7");

  // --- 1. Deploy BasisVerifier ---
  console.log("\n[1/6] Deploying BasisVerifier...");
  const BasisVerifier = await ethers.getContractFactory("BasisVerifier");
  const verifier = await BasisVerifier.deploy(MAX_MIGRATION_STEPS);
  await verifier.waitForDeployment();
  const verifierAddr = await verifier.getAddress();
  console.log("  BasisVerifier deployed at:", verifierAddr);

  // --- 2. Deploy BasisRollup ---
  console.log("\n[2/6] Deploying BasisRollup...");
  const BasisRollup = await ethers.getContractFactory("BasisRollup");
  const rollup = await BasisRollup.deploy(ENTERPRISE_REGISTRY);
  await rollup.waitForDeployment();
  const rollupAddr = await rollup.getAddress();
  console.log("  BasisRollup deployed at:", rollupAddr);

  // --- 3. Deploy BasisBridge ---
  console.log("\n[3/6] Deploying BasisBridge...");
  const BasisBridge = await ethers.getContractFactory("BasisBridge");
  const bridge = await BasisBridge.deploy(rollupAddr, ESCAPE_TIMEOUT);
  await bridge.waitForDeployment();
  const bridgeAddr = await bridge.getAddress();
  console.log("  BasisBridge deployed at:", bridgeAddr);

  // --- 4. Deploy BasisDAC ---
  console.log("\n[4/6] Deploying BasisDAC...");
  // Initial committee: deployer address only (add more via addMember later).
  const BasisDAC = await ethers.getContractFactory("BasisDAC");
  const dac = await BasisDAC.deploy(1, [deployer.address]);
  await dac.waitForDeployment();
  const dacAddr = await dac.getAddress();
  console.log("  BasisDAC deployed at:", dacAddr);

  // --- 5. Deploy BasisAggregator ---
  console.log("\n[5/6] Deploying BasisAggregator...");
  const BasisAggregator = await ethers.getContractFactory("BasisAggregator");
  const aggregator = await BasisAggregator.deploy(deployer.address);
  await aggregator.waitForDeployment();
  const aggregatorAddr = await aggregator.getAddress();
  console.log("  BasisAggregator deployed at:", aggregatorAddr);

  // --- 6. Deploy BasisHub ---
  console.log("\n[6/6] Deploying BasisHub...");
  const BasisHub = await ethers.getContractFactory("BasisHub");
  const hub = await BasisHub.deploy(ENTERPRISE_REGISTRY, HUB_TIMEOUT_BLOCKS);
  await hub.waitForDeployment();
  const hubAddr = await hub.getAddress();
  console.log("  BasisHub deployed at:", hubAddr);

  // --- Summary ---
  console.log("\n=== Deployment Complete ===");
  console.log("Network:", (await ethers.provider.getNetwork()).chainId.toString());
  console.log("");
  console.log("Contract Addresses:");
  console.log("  BasisVerifier:      ", verifierAddr);
  console.log("  BasisRollup:        ", rollupAddr);
  console.log("  BasisBridge:        ", bridgeAddr);
  console.log("  BasisDAC:           ", dacAddr);
  console.log("  BasisAggregator:    ", aggregatorAddr);
  console.log("  BasisHub:           ", hubAddr);
  console.log("");
  console.log("External Dependencies:");
  console.log("  EnterpriseRegistry: ", ENTERPRISE_REGISTRY);
  console.log("");
  console.log("Add these addresses to zkl2/node/.env before starting the L2 node.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
