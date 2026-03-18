import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/// End-to-end ZK verification demo: sets the verifying key and submits
/// a Groth16 proof for on-chain verification on Basis Network L1.
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=== ZK On-Chain Verification Demo ===\n");
  console.log("Sender:", deployer.address);

  const zkVerifier = await ethers.getContractAt(
    "ZKVerifier",
    "0x95CA0a568236fC7413Cd2b794A7da24422c2BBb6"
  );

  // Load verification key from prover build
  const vkPath = path.join(__dirname, "../../../validium/circuits/build/verification_key.json");
  const vk = JSON.parse(fs.readFileSync(vkPath, "utf-8"));

  // Step 1: Set the verifying key on-chain
  console.log("\nStep 1: Setting verifying key on-chain...");

  const alfa1: [bigint, bigint] = [
    BigInt(vk.vk_alpha_1[0]),
    BigInt(vk.vk_alpha_1[1]),
  ];

  const beta2: [[bigint, bigint], [bigint, bigint]] = [
    [BigInt(vk.vk_beta_2[0][0]), BigInt(vk.vk_beta_2[0][1])],
    [BigInt(vk.vk_beta_2[1][0]), BigInt(vk.vk_beta_2[1][1])],
  ];

  const gamma2: [[bigint, bigint], [bigint, bigint]] = [
    [BigInt(vk.vk_gamma_2[0][0]), BigInt(vk.vk_gamma_2[0][1])],
    [BigInt(vk.vk_gamma_2[1][0]), BigInt(vk.vk_gamma_2[1][1])],
  ];

  const delta2: [[bigint, bigint], [bigint, bigint]] = [
    [BigInt(vk.vk_delta_2[0][0]), BigInt(vk.vk_delta_2[0][1])],
    [BigInt(vk.vk_delta_2[1][0]), BigInt(vk.vk_delta_2[1][1])],
  ];

  const IC: [bigint, bigint][] = vk.IC.map((ic: string[]) => [
    BigInt(ic[0]),
    BigInt(ic[1]),
  ]);

  const setVkTx = await zkVerifier.setVerifyingKey(alfa1, beta2, gamma2, delta2, IC);
  await setVkTx.wait();
  console.log("  Verifying key set. TX:", setVkTx.hash);

  const vkSet = await zkVerifier.verifyingKeySet();
  console.log("  verifyingKeySet:", vkSet);

  // Step 2: Load proof and public signals
  console.log("\nStep 2: Loading proof and public signals...");
  const proofPath = path.join(__dirname, "../../../validium/circuits/build/proof.json");
  const publicPath = path.join(__dirname, "../../../validium/circuits/build/public.json");

  const proof = JSON.parse(fs.readFileSync(proofPath, "utf-8"));
  const publicSignals: string[] = JSON.parse(fs.readFileSync(publicPath, "utf-8"));

  console.log("  Public signals:", publicSignals);
  console.log("  Signal [0] = valid (1 = true)");
  console.log("  Signal [1] = batchRoot");
  console.log("  Signal [2] = batchSize");
  console.log("  Signal [3] = enterpriseId");

  // Step 3: Submit proof on-chain
  console.log("\nStep 3: Submitting proof on-chain...");

  const a: [bigint, bigint] = [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])];

  const b: [[bigint, bigint], [bigint, bigint]] = [
    [BigInt(proof.pi_b[0][0]), BigInt(proof.pi_b[0][1])],
    [BigInt(proof.pi_b[1][0]), BigInt(proof.pi_b[1][1])],
  ];

  const c: [bigint, bigint] = [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])];

  const stateRoot = ethers.keccak256(
    ethers.toUtf8Bytes("batch-" + publicSignals[1])
  );
  const batchSize = parseInt(publicSignals[2]);

  const verifyTx = await zkVerifier.verifyBatchProof(
    stateRoot,
    batchSize,
    a,
    b,
    c,
    publicSignals.map((s) => BigInt(s))
  );
  const receipt = await verifyTx.wait();
  console.log("  Proof submitted. TX:", verifyTx.hash);
  console.log("  Gas used:", receipt?.gasUsed.toString());

  // Step 4: Verify on-chain state
  console.log("\nStep 4: Checking on-chain state...");
  const totalBatches = await zkVerifier.totalBatches();
  const totalVerified = await zkVerifier.totalVerified();
  const totalTxVerified = await zkVerifier.totalTransactionsVerified();

  console.log(`  Total batches: ${totalBatches}`);
  console.log(`  Total verified: ${totalVerified}`);
  console.log(`  Total transactions verified: ${totalTxVerified}`);

  console.log("\n=== ZK Verification Complete ===");
  console.log("Enterprise transactions verified on-chain without revealing data.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
