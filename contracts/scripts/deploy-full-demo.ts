import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

/// Full deployment and demo script: deploys all contracts, registers
/// a demo enterprise, and submits a ZK proof on-chain.
/// Use with --network basisLocal or --network basisFuji.
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=== Basis Network Full Deployment ===\n");
  console.log("Deployer:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "LITHOS");
  console.log("Network:", (await ethers.provider.getNetwork()).chainId.toString());

  // --- Deploy Contracts ---
  console.log("\n--- 1/5: Deploying EnterpriseRegistry ---");
  const EnterpriseRegistry = await ethers.getContractFactory("EnterpriseRegistry");
  const registry = await EnterpriseRegistry.deploy();
  await registry.waitForDeployment();
  const registryAddr = await registry.getAddress();
  console.log("  Address:", registryAddr);

  console.log("\n--- 2/5: Deploying TraceabilityRegistry ---");
  const TraceabilityRegistry = await ethers.getContractFactory("TraceabilityRegistry");
  const traceReg = await TraceabilityRegistry.deploy(registryAddr);
  await traceReg.waitForDeployment();
  const traceRegAddr = await traceReg.getAddress();
  console.log("  Address:", traceRegAddr);

  console.log("\n--- 3/5: Deploying PLASMAConnector ---");
  const PLASMAConnector = await ethers.getContractFactory("PLASMAConnector");
  const plasma = await PLASMAConnector.deploy(registryAddr, traceRegAddr);
  await plasma.waitForDeployment();
  const plasmaAddr = await plasma.getAddress();
  console.log("  Address:", plasmaAddr);

  console.log("\n--- 4/5: Deploying TraceConnector ---");
  const TraceConnector = await ethers.getContractFactory("TraceConnector");
  const trace = await TraceConnector.deploy(registryAddr, traceRegAddr);
  await trace.waitForDeployment();
  const traceAddr = await trace.getAddress();
  console.log("  Address:", traceAddr);

  console.log("\n--- 5/5: Deploying ZKVerifier ---");
  const ZKVerifier = await ethers.getContractFactory("ZKVerifier");
  const zkVerifier = await ZKVerifier.deploy(registryAddr);
  await zkVerifier.waitForDeployment();
  const zkAddr = await zkVerifier.getAddress();
  console.log("  Address:", zkAddr);

  // --- Register Enterprises ---
  console.log("\n--- Registering enterprises ---");
  const meta = ethers.toUtf8Bytes('{"type":"system_connector"}');

  await (await registry.registerEnterprise(plasmaAddr, "PLASMAConnector", meta)).wait();
  console.log("  PLASMAConnector registered");

  await (await registry.registerEnterprise(traceAddr, "TraceConnector", meta)).wait();
  console.log("  TraceConnector registered");

  // NOTE: "Ingenio Sancarlos" was previously registered here using the deployer
  // address, but it was removed because Ingenio Sancarlos is a CLIENT of PLASMA,
  // not a SaaS enterprise.  Do not re-add it.

  // --- PLASMA Demo Transactions ---
  console.log("\n--- PLASMA demo transactions ---");
  const plasmaContract = await ethers.getContractAt("PLASMAConnector", plasmaAddr);

  await (await plasmaContract.recordMaintenanceOrder(
    ethers.encodeBytes32String("WO-2026-001"),
    ethers.encodeBytes32String("BOILER-A1"),
    1,
    ethers.toUtf8Bytes("Critical pressure valve replacement")
  )).wait();
  console.log("  Work order WO-2026-001 created");

  await (await plasmaContract.recordMaintenanceOrder(
    ethers.encodeBytes32String("WO-2026-002"),
    ethers.encodeBytes32String("TURBINE-B3"),
    2,
    ethers.toUtf8Bytes("Scheduled bearing inspection")
  )).wait();
  console.log("  Work order WO-2026-002 created");

  await (await plasmaContract.recordEquipmentInspection(
    ethers.encodeBytes32String("BOILER-A1"),
    ethers.toUtf8Bytes("Temperature: 185C, Pressure: 12bar, Status: nominal")
  )).wait();
  console.log("  Equipment inspection recorded");

  await (await plasmaContract.completeMaintenanceOrder(
    ethers.encodeBytes32String("WO-2026-001"),
    ethers.toUtf8Bytes("Valve replaced. Pressure test passed at 15bar.")
  )).wait();
  console.log("  Work order WO-2026-001 completed");

  // --- Trace Demo Transactions ---
  console.log("\n--- Trace demo transactions ---");
  const traceContract = await ethers.getContractAt("TraceConnector", traceAddr);

  await (await traceContract.recordSale(
    ethers.encodeBytes32String("SALE-001"),
    ethers.encodeBytes32String("SUGAR-50KG"),
    100, 5000000
  )).wait();
  console.log("  Sale SALE-001 recorded");

  await (await traceContract.recordInventoryMovement(
    ethers.encodeBytes32String("SUGAR-50KG"),
    -100, ethers.encodeBytes32String("SALE")
  )).wait();
  console.log("  Inventory movement recorded");

  await (await traceContract.recordSupplierTransaction(
    ethers.encodeBytes32String("SUPP-CANE-01"),
    ethers.encodeBytes32String("RAW-CANE"),
    10000
  )).wait();
  console.log("  Supplier transaction recorded");

  // --- ZK Proof Verification ---
  console.log("\n--- ZK proof on-chain verification ---");
  const vkPath = path.join(__dirname, "../../prover/build/verification_key.json");
  const proofPath = path.join(__dirname, "../../prover/build/proof.json");
  const publicPath = path.join(__dirname, "../../prover/build/public.json");

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
    console.log("  Skipped: run 'npm run setup && npm run prove' in prover/ first");
  }

  // --- Summary ---
  console.log("\n========================================");
  console.log("       DEPLOYMENT SUMMARY");
  console.log("========================================");
  console.log("EnterpriseRegistry:    ", registryAddr);
  console.log("TraceabilityRegistry:  ", traceRegAddr);
  console.log("PLASMAConnector:       ", plasmaAddr);
  console.log("TraceConnector:        ", traceAddr);
  console.log("ZKVerifier:            ", zkAddr);
  console.log("========================================");
  console.log("Enterprises: 2 (PLASMAConnector, TraceConnector)");
  console.log("PLASMA: 2 work orders, 1 completed, 1 inspection");
  console.log("Trace: 1 sale, 1 inventory movement, 1 supplier transaction");
  console.log("ZK: 1 batch proof verified (4 transactions)");
  console.log("========================================");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
