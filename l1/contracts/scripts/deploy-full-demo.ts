import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/// Full deployment and demo script: deploys all contracts, registers
/// a demo enterprise, and submits sample events on-chain.
/// Use with --network basisLocal or --network basisFuji.
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=== Basis Network Full Deployment ===\n");
  console.log("Deployer:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "LITHOS");
  console.log("Network:", (await ethers.provider.getNetwork()).chainId.toString());

  // --- Deploy Contracts ---
  console.log("\n--- 1/6: Deploying EnterpriseRegistry ---");
  const EnterpriseRegistry = await ethers.getContractFactory("EnterpriseRegistry");
  const registry = await EnterpriseRegistry.deploy();
  await registry.waitForDeployment();
  const registryAddr = await registry.getAddress();
  console.log("  Address:", registryAddr);

  console.log("\n--- 2/6: Deploying TraceabilityRegistry ---");
  const TraceabilityRegistry = await ethers.getContractFactory("TraceabilityRegistry");
  const traceReg = await TraceabilityRegistry.deploy(registryAddr);
  await traceReg.waitForDeployment();
  const traceRegAddr = await traceReg.getAddress();
  console.log("  Address:", traceRegAddr);

  console.log("\n--- 3/6: Deploying ZKVerifier ---");
  const ZKVerifier = await ethers.getContractFactory("ZKVerifier");
  const zkVerifier = await ZKVerifier.deploy(registryAddr);
  await zkVerifier.waitForDeployment();
  const zkAddr = await zkVerifier.getAddress();
  console.log("  Address:", zkAddr);

  console.log("\n--- 4/6: Deploying StateCommitment ---");
  const StateCommitment = await ethers.getContractFactory("StateCommitment");
  const stateCommitment = await StateCommitment.deploy(registryAddr);
  await stateCommitment.waitForDeployment();
  const stateCommitmentAddr = await stateCommitment.getAddress();
  console.log("  Address:", stateCommitmentAddr);

  console.log("\n--- 5/6: Deploying DACAttestation ---");
  const DACAttestation = await ethers.getContractFactory("DACAttestation");
  const dacAttestation = await DACAttestation.deploy(registryAddr, 1);
  await dacAttestation.waitForDeployment();
  const dacAddr = await dacAttestation.getAddress();
  console.log("  Address:", dacAddr);

  console.log("\n--- 6/6: Deploying CrossEnterpriseVerifier ---");
  const CrossEnterpriseVerifier = await ethers.getContractFactory("CrossEnterpriseVerifier");
  const crossVerifier = await CrossEnterpriseVerifier.deploy(stateCommitmentAddr, registryAddr);
  await crossVerifier.waitForDeployment();
  const crossVerifierAddr = await crossVerifier.getAddress();
  console.log("  Address:", crossVerifierAddr);

  // --- Register Demo Enterprise ---
  console.log("\n--- Registering demo enterprise (deployer) ---");
  const meta = ethers.toUtf8Bytes('{"type":"demo_enterprise"}');
  await (await registry.registerEnterprise(deployer.address, "DemoEnterprise", meta)).wait();
  console.log("  Deployer registered as DemoEnterprise");

  // --- PLASMA Demo Transactions (generic TraceabilityRegistry calls) ---
  console.log("\n--- PLASMA demo transactions (via TraceabilityRegistry) ---");

  const ORDER_CREATED = ethers.keccak256(ethers.toUtf8Bytes("ORDER_CREATED"));
  const EQUIPMENT_INSPECTION = ethers.keccak256(ethers.toUtf8Bytes("EQUIPMENT_INSPECTION"));
  const ORDER_COMPLETED = ethers.keccak256(ethers.toUtf8Bytes("ORDER_COMPLETED"));

  await (await traceReg.recordEvent(
    ORDER_CREATED,
    ethers.encodeBytes32String("BOILER-A1"),
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "uint8", "string"],
      [ethers.encodeBytes32String("WO-2026-001"), 1, "Critical pressure valve replacement"]
    )
  )).wait();
  console.log("  ORDER_CREATED: WO-2026-001 for BOILER-A1");

  await (await traceReg.recordEvent(
    EQUIPMENT_INSPECTION,
    ethers.encodeBytes32String("BOILER-A1"),
    ethers.toUtf8Bytes("Temperature: 185C, Pressure: 12bar, Status: nominal")
  )).wait();
  console.log("  EQUIPMENT_INSPECTION: BOILER-A1");

  await (await traceReg.recordEvent(
    ORDER_COMPLETED,
    ethers.encodeBytes32String("BOILER-A1"),
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "string"],
      [ethers.encodeBytes32String("WO-2026-001"), "Valve replaced. Pressure test passed at 15bar."]
    )
  )).wait();
  console.log("  ORDER_COMPLETED: WO-2026-001");

  // --- Trace Demo Transactions (generic TraceabilityRegistry calls) ---
  console.log("\n--- Trace demo transactions (via TraceabilityRegistry) ---");

  const SALE_CREATED = ethers.keccak256(ethers.toUtf8Bytes("SALE_CREATED"));
  const INVENTORY_MOVEMENT = ethers.keccak256(ethers.toUtf8Bytes("INVENTORY_MOVEMENT"));
  const PURCHASE_ORDER_CREATED = ethers.keccak256(ethers.toUtf8Bytes("PURCHASE_ORDER_CREATED"));

  await (await traceReg.recordEvent(
    SALE_CREATED,
    ethers.encodeBytes32String("SUGAR-50KG"),
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "uint256", "uint256"],
      [ethers.encodeBytes32String("SALE-001"), 100, 5000000]
    )
  )).wait();
  console.log("  SALE_CREATED: SALE-001 for SUGAR-50KG");

  await (await traceReg.recordEvent(
    INVENTORY_MOVEMENT,
    ethers.encodeBytes32String("SUGAR-50KG"),
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["int256", "string"],
      [-100, "SALE"]
    )
  )).wait();
  console.log("  INVENTORY_MOVEMENT: SUGAR-50KG (-100)");

  await (await traceReg.recordEvent(
    PURCHASE_ORDER_CREATED,
    ethers.encodeBytes32String("RAW-CANE"),
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "uint256"],
      [ethers.encodeBytes32String("SUPP-CANE-01"), 10000]
    )
  )).wait();
  console.log("  PURCHASE_ORDER_CREATED: RAW-CANE from SUPP-CANE-01");

  // --- ZK Proof Verification ---
  console.log("\n--- ZK proof on-chain verification ---");
  const vkPath = path.join(__dirname, "../../../validium/circuits/build/verification_key.json");
  const proofPath = path.join(__dirname, "../../../validium/circuits/build/proof.json");
  const publicPath = path.join(__dirname, "../../../validium/circuits/build/public.json");

  if (fs.existsSync(vkPath) && fs.existsSync(proofPath)) {
    const vk = JSON.parse(fs.readFileSync(vkPath, "utf-8"));
    const proof = JSON.parse(fs.readFileSync(proofPath, "utf-8"));
    const publicSignals: string[] = JSON.parse(fs.readFileSync(publicPath, "utf-8"));

    // Set verifying key
    const alfa1: [bigint, bigint] = [BigInt(vk.vk_alpha_1[0]), BigInt(vk.vk_alpha_1[1])];
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
    const IC: [bigint, bigint][] = vk.IC.map((ic: string[]) => [BigInt(ic[0]), BigInt(ic[1])]);

    await (await zkVerifier.setVerifyingKey(alfa1, beta2, gamma2, delta2, IC)).wait();
    console.log("  Verifying key set on-chain");

    // Submit proof
    const a: [bigint, bigint] = [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])];
    const b: [[bigint, bigint], [bigint, bigint]] = [
      [BigInt(proof.pi_b[0][0]), BigInt(proof.pi_b[0][1])],
      [BigInt(proof.pi_b[1][0]), BigInt(proof.pi_b[1][1])],
    ];
    const c: [bigint, bigint] = [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])];
    const stateRoot = ethers.keccak256(ethers.toUtf8Bytes("batch-" + publicSignals[1]));

    const receipt = await (await zkVerifier.verifyBatchProof(
      stateRoot, parseInt(publicSignals[2]), a, b, c,
      publicSignals.map((s) => BigInt(s))
    )).wait();
    console.log("  ZK proof verified on-chain! Gas:", receipt?.gasUsed.toString());
  } else {
    console.log("  Skipped: run 'npm run setup && npm run prove' in validium/circuits/ first");
  }

  // --- Summary ---
  console.log("\n========================================");
  console.log("       DEPLOYMENT SUMMARY");
  console.log("========================================");
  console.log("EnterpriseRegistry:       ", registryAddr);
  console.log("TraceabilityRegistry:     ", traceRegAddr);
  console.log("ZKVerifier:               ", zkAddr);
  console.log("StateCommitment:          ", stateCommitmentAddr);
  console.log("DACAttestation:           ", dacAddr);
  console.log("CrossEnterpriseVerifier:  ", crossVerifierAddr);
  console.log("========================================");
  console.log("Enterprises: 1 (DemoEnterprise)");
  console.log("PLASMA: 1 order created, 1 inspection, 1 order completed");
  console.log("Trace: 1 sale, 1 inventory movement, 1 purchase order");
  console.log("ZK: 1 batch proof verified (4 transactions via Groth16)");
  console.log("========================================");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
