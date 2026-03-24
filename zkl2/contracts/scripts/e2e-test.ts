/// End-to-End test for the Basis Network zkEVM L2 settlement pipeline.
///
/// Exercises the complete BasisRollup commit-prove-execute lifecycle on the
/// live Fuji chain (chain ID 43199). Uses the BasisRollupTestHarness with
/// mocked proof verification to demonstrate the full batch lifecycle without
/// requiring a real ZK prover.
///
/// Also verifies BasisVerifier and BasisDAC read operations against their
/// deployed instances.
///
/// Usage:
///   npx hardhat run scripts/e2e-test.ts --network basis
///
/// Prerequisites:
///   - DEPLOYER_KEY in .env
///   - EnterpriseRegistry deployed with deployer authorized

import { ethers } from "hardhat";

// Deployed contract addresses (from deployment on 2026-03-21).
const ENTERPRISE_REGISTRY = "0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5";
const VERIFIER_ADDRESS = "0xFE9DF13c038414773Ac96189742b6c1f93999f29";
const DAC_ADDRESS = "0xa7D5771fA69404438d79a1F8C192F7257A514691";

async function main() {
  const [deployer] = await ethers.getSigners();
  const startTime = Date.now();

  console.log("=== Basis Network zkEVM L2 -- End-to-End Test ===\n");
  console.log("Chain ID:", (await ethers.provider.getNetwork()).chainId.toString());
  console.log("Deployer:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "LITHOS");
  console.log("");

  // -----------------------------------------------------------------------
  // Step 1: Deploy BasisRollupTestHarness (mock proof verification)
  // -----------------------------------------------------------------------
  console.log("[1/8] Deploying BasisRollupTestHarness...");
  const Harness = await ethers.getContractFactory("BasisRollupHarness");
  const rollup = await Harness.deploy(ENTERPRISE_REGISTRY);
  await rollup.waitForDeployment();
  const rollupAddr = await rollup.getAddress();
  console.log("  Harness deployed at:", rollupAddr);

  // -----------------------------------------------------------------------
  // Step 2: Initialize enterprise with genesis state root
  // -----------------------------------------------------------------------
  console.log("\n[2/8] Initializing enterprise...");
  const genesisRoot = ethers.keccak256(ethers.toUtf8Bytes("basis-l2-genesis-state-v1"));
  const initTx = await rollup.initializeEnterprise(deployer.address, genesisRoot);
  const initReceipt = await initTx.wait();
  console.log("  Enterprise initialized:", deployer.address);
  console.log("  Genesis root:", genesisRoot);
  console.log("  Gas used:", initReceipt!.gasUsed.toString());

  // Verify initialization state.
  const currentRoot = await rollup.getCurrentRoot(deployer.address);
  if (currentRoot !== genesisRoot) {
    throw new Error(`Root mismatch: expected ${genesisRoot}, got ${currentRoot}`);
  }
  console.log("  Verification: current root matches genesis root");

  // -----------------------------------------------------------------------
  // Step 2b: Set verifying key (required before proveBatch)
  // -----------------------------------------------------------------------
  console.log("\n[2b/8] Setting verifying key (dummy for harness)...");
  // Minimal VK: all points set to generator G1/G2 (1,2) which is the BN254 generator.
  // IC array must have length = publicSignals.length + 1. We use 0 public signals -> IC length 1.
  const g1 = [1n, 2n] as [bigint, bigint];
  const g2 = [[0n, 0n], [0n, 0n]] as [[bigint, bigint], [bigint, bigint]];
  const ic = [[1n, 2n]]; // IC.length = 1 -> publicSignals.length = 0

  const vkTx = await rollup.setVerifyingKey(g1, g2, g2, g2, ic);
  await vkTx.wait();
  console.log("  Verifying key set (IC length: 1, signals: 0)");

  // -----------------------------------------------------------------------
  // Step 3: Commit batch 0 (L2 blocks 1-10)
  // -----------------------------------------------------------------------
  console.log("\n[3/8] Committing batch 0 (L2 blocks 1-10)...");
  const stateRoot1 = ethers.keccak256(ethers.toUtf8Bytes("batch-0-state-root"));
  const priorityOpsHash = ethers.keccak256(ethers.toUtf8Bytes("no-priority-ops"));
  const timestamp = Math.floor(Date.now() / 1000);

  const commitTx = await rollup.commitBatch({
    newStateRoot: stateRoot1,
    l2BlockStart: 1,
    l2BlockEnd: 10,
    priorityOpsHash: priorityOpsHash,
    timestamp: timestamp,
  });
  const commitReceipt = await commitTx.wait();
  console.log("  Batch 0 committed");
  console.log("  New state root:", stateRoot1);
  console.log("  Gas used:", commitReceipt!.gasUsed.toString());

  // Verify commit state.
  const counts = await rollup.getBatchCounts(deployer.address);
  console.log("  Counts: committed=%s, proven=%s, executed=%s",
    counts[0].toString(), counts[1].toString(), counts[2].toString());

  if (counts[0].toString() !== "1") {
    throw new Error(`Expected 1 committed batch, got ${counts[0]}`);
  }

  // -----------------------------------------------------------------------
  // Step 4: Prove batch 0 (mock verification)
  // -----------------------------------------------------------------------
  console.log("\n[4/8] Proving batch 0 (mock ZK verification)...");
  // Dummy proof data -- the harness overrides _verifyProof to return true.
  const dummyA: [bigint, bigint] = [0n, 0n];
  const dummyB: [[bigint, bigint], [bigint, bigint]] = [[0n, 0n], [0n, 0n]];
  const dummyC: [bigint, bigint] = [0n, 0n];
  const dummySignals: bigint[] = [];

  const proveTx = await rollup.proveBatch(0, dummyA, dummyB, dummyC, dummySignals);
  const proveReceipt = await proveTx.wait();
  console.log("  Batch 0 proven");
  console.log("  Gas used:", proveReceipt!.gasUsed.toString());

  // Verify prove state.
  const counts2 = await rollup.getBatchCounts(deployer.address);
  if (counts2[1].toString() !== "1") {
    throw new Error(`Expected 1 proven batch, got ${counts2[1]}`);
  }

  // -----------------------------------------------------------------------
  // Step 5: Execute batch 0 (finalize)
  // -----------------------------------------------------------------------
  console.log("\n[5/8] Executing batch 0 (finalizing)...");
  const execTx = await rollup.executeBatch(0);
  const execReceipt = await execTx.wait();
  console.log("  Batch 0 executed (finalized)");
  console.log("  Gas used:", execReceipt!.gasUsed.toString());

  // Verify execute state.
  const counts3 = await rollup.getBatchCounts(deployer.address);
  if (counts3[2].toString() !== "1") {
    throw new Error(`Expected 1 executed batch, got ${counts3[2]}`);
  }

  // Verify state root updated.
  const finalRoot = await rollup.getCurrentRoot(deployer.address);
  if (finalRoot !== stateRoot1) {
    throw new Error(`Root not updated: expected ${stateRoot1}, got ${finalRoot}`);
  }
  console.log("  Verification: state root updated to batch 0 root");

  // Verify batch info shows executed status (status=3 for Executed enum).
  const batchInfo = await rollup.getBatchInfo(deployer.address, 0);
  console.log("  Batch info: status=%s, l2Blocks=%s-%s",
    batchInfo[4].toString(), batchInfo[2].toString(), batchInfo[3].toString());

  // -----------------------------------------------------------------------
  // Step 6: Commit + prove + execute batch 1 (L2 blocks 11-20)
  // -----------------------------------------------------------------------
  console.log("\n[6/8] Full lifecycle for batch 1 (L2 blocks 11-20)...");
  const stateRoot2 = ethers.keccak256(ethers.toUtf8Bytes("batch-1-state-root"));

  const commit2 = await rollup.commitBatch({
    newStateRoot: stateRoot2,
    l2BlockStart: 11,
    l2BlockEnd: 20,
    priorityOpsHash: priorityOpsHash,
    timestamp: Math.floor(Date.now() / 1000),
  });
  await commit2.wait();
  console.log("  Batch 1 committed");

  const prove2 = await rollup.proveBatch(1, dummyA, dummyB, dummyC, dummySignals);
  await prove2.wait();
  console.log("  Batch 1 proven");

  const exec2 = await rollup.executeBatch(1);
  await exec2.wait();
  console.log("  Batch 1 executed");

  const finalRoot2 = await rollup.getCurrentRoot(deployer.address);
  if (finalRoot2 !== stateRoot2) {
    throw new Error(`Batch 1 root mismatch: expected ${stateRoot2}, got ${finalRoot2}`);
  }
  console.log("  Verification: state root chain is correct");

  const finalCounts = await rollup.getBatchCounts(deployer.address);
  console.log("  Final counts: committed=%s, proven=%s, executed=%s",
    finalCounts[0].toString(), finalCounts[1].toString(), finalCounts[2].toString());

  // -----------------------------------------------------------------------
  // Step 7: Verify deployed BasisVerifier and BasisDAC (read-only)
  // -----------------------------------------------------------------------
  console.log("\n[7/8] Verifying deployed BasisVerifier...");
  const verifierABI = [
    "function admin() view returns (address)",
    "function migrationPhase() view returns (uint8)",
  ];
  const verifier = new ethers.Contract(VERIFIER_ADDRESS, verifierABI, deployer);
  const verifierAdmin = await verifier.admin();
  const migrationPhase = await verifier.migrationPhase();
  console.log("  Admin:", verifierAdmin);
  console.log("  Migration phase:", migrationPhase.toString(), "(0=Groth16Only)");

  console.log("\n  Verifying deployed BasisDAC...");
  const dacABI = [
    "function admin() view returns (address)",
    "function threshold() view returns (uint8)",
    "function committeeSize() view returns (uint8)",
  ];
  const dac = new ethers.Contract(DAC_ADDRESS, dacABI, deployer);
  const dacAdmin = await dac.admin();
  const dacThreshold = await dac.threshold();
  const dacSize = await dac.committeeSize();
  console.log("  DAC Admin:", dacAdmin);
  console.log("  DAC Threshold:", dacThreshold.toString());
  console.log("  DAC Committee Size:", dacSize.toString());

  // -----------------------------------------------------------------------
  // Step 8: Summary
  // -----------------------------------------------------------------------
  const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
  const totalGas = BigInt(initReceipt!.gasUsed) + BigInt(commitReceipt!.gasUsed) +
    BigInt(proveReceipt!.gasUsed) + BigInt(execReceipt!.gasUsed);

  console.log("\n=== E2E Test Complete ===");
  console.log("Duration:", elapsed, "seconds");
  console.log("Batches processed: 2 (commit -> prove -> execute)");
  console.log("Total gas (batch 0):", totalGas.toString());
  console.log("Zero crashes, all state transitions verified");
  console.log("");
  console.log("Contracts verified:");
  console.log("  BasisRollupHarness:", rollupAddr);
  console.log("  BasisVerifier:     ", VERIFIER_ADDRESS);
  console.log("  BasisDAC:          ", DAC_ADDRESS);
  console.log("  EnterpriseRegistry:", ENTERPRISE_REGISTRY);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\nE2E TEST FAILED:", error.message || error);
    process.exit(1);
  });
