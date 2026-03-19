/**
 * Deploy ALL Basis Network contracts to a fresh L1.
 *
 * Deploys the complete contract suite in dependency order:
 *   1. EnterpriseRegistry         -- Identity and access control
 *   2. TraceabilityRegistry       -- Immutable event ledger
 *   3. PLASMAConnector            -- PLASMA bridge
 *   4. TraceConnector             -- Trace bridge
 *   5. ZKVerifier                 -- Groth16 batch verification (legacy)
 *   6. StateCommitment            -- Per-enterprise ZK state root chains
 *   7. DACAttestation             -- Data Availability Committee attestation
 *   8. CrossEnterpriseVerifier    -- Hub-and-spoke cross-enterprise verification
 *
 * After deployment, registers system connectors as authorized enterprises,
 * and writes a deployment record JSON for reference.
 *
 * Usage:
 *   npx hardhat run scripts/deploy-all.ts --network basisLocal
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

const DAC_THRESHOLD = 2;

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=== Basis Network -- Full Contract Deployment ===\n");
  console.log("Deployer:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "LITHOS\n");

  // -----------------------------------------------------------------------
  // 1. EnterpriseRegistry
  // -----------------------------------------------------------------------
  console.log("[1/8] EnterpriseRegistry...");
  const EnterpriseRegistry = await ethers.getContractFactory("EnterpriseRegistry");
  const registry = await EnterpriseRegistry.deploy();
  await registry.waitForDeployment();
  const registryAddr = await registry.getAddress();
  console.log("  ->", registryAddr);

  // -----------------------------------------------------------------------
  // 2. TraceabilityRegistry
  // -----------------------------------------------------------------------
  console.log("[2/8] TraceabilityRegistry...");
  const TraceabilityRegistry = await ethers.getContractFactory("TraceabilityRegistry");
  const traceReg = await TraceabilityRegistry.deploy(registryAddr);
  await traceReg.waitForDeployment();
  const traceRegAddr = await traceReg.getAddress();
  console.log("  ->", traceRegAddr);

  // -----------------------------------------------------------------------
  // 3. PLASMAConnector
  // -----------------------------------------------------------------------
  console.log("[3/8] PLASMAConnector...");
  const PLASMAConnector = await ethers.getContractFactory("PLASMAConnector");
  const plasma = await PLASMAConnector.deploy(registryAddr, traceRegAddr);
  await plasma.waitForDeployment();
  const plasmaAddr = await plasma.getAddress();
  console.log("  ->", plasmaAddr);

  // -----------------------------------------------------------------------
  // 4. TraceConnector
  // -----------------------------------------------------------------------
  console.log("[4/8] TraceConnector...");
  const TraceConnector = await ethers.getContractFactory("TraceConnector");
  const trace = await TraceConnector.deploy(registryAddr, traceRegAddr);
  await trace.waitForDeployment();
  const traceAddr = await trace.getAddress();
  console.log("  ->", traceAddr);

  // -----------------------------------------------------------------------
  // 5. ZKVerifier
  // -----------------------------------------------------------------------
  console.log("[5/8] ZKVerifier...");
  const ZKVerifier = await ethers.getContractFactory("ZKVerifier");
  const zkVerifier = await ZKVerifier.deploy(registryAddr);
  await zkVerifier.waitForDeployment();
  const zkVerifierAddr = await zkVerifier.getAddress();
  console.log("  ->", zkVerifierAddr);

  // -----------------------------------------------------------------------
  // 6. StateCommitment
  // -----------------------------------------------------------------------
  console.log("[6/8] StateCommitment...");
  const StateCommitment = await ethers.getContractFactory("StateCommitment");
  const stateCommitment = await StateCommitment.deploy(registryAddr);
  await stateCommitment.waitForDeployment();
  const stateCommitAddr = await stateCommitment.getAddress();
  console.log("  ->", stateCommitAddr);

  // -----------------------------------------------------------------------
  // 7. DACAttestation
  // -----------------------------------------------------------------------
  console.log("[7/8] DACAttestation...");
  const DACAttestation = await ethers.getContractFactory("DACAttestation");
  const dac = await DACAttestation.deploy(registryAddr, DAC_THRESHOLD);
  await dac.waitForDeployment();
  const dacAddr = await dac.getAddress();
  console.log("  ->", dacAddr);

  // -----------------------------------------------------------------------
  // 8. CrossEnterpriseVerifier
  // -----------------------------------------------------------------------
  console.log("[8/8] CrossEnterpriseVerifier...");
  const CrossEnterpriseVerifier = await ethers.getContractFactory("CrossEnterpriseVerifier");
  const crossVerifier = await CrossEnterpriseVerifier.deploy(registryAddr, stateCommitAddr);
  await crossVerifier.waitForDeployment();
  const crossVerifierAddr = await crossVerifier.getAddress();
  console.log("  ->", crossVerifierAddr);

  // -----------------------------------------------------------------------
  // Register system connectors as authorized enterprises
  // -----------------------------------------------------------------------
  console.log("\nRegistering system connectors...");
  const connectorMeta = ethers.toUtf8Bytes('{"type":"system_connector"}');

  await registry.registerEnterprise(plasmaAddr, "PLASMAConnector", connectorMeta);
  console.log("  PLASMAConnector registered");

  await registry.registerEnterprise(traceAddr, "TraceConnector", connectorMeta);
  console.log("  TraceConnector registered");

  // -----------------------------------------------------------------------
  // Summary
  // -----------------------------------------------------------------------
  console.log("\n========================================");
  console.log("   DEPLOYMENT COMPLETE");
  console.log("========================================");
  console.log("EnterpriseRegistry:     ", registryAddr);
  console.log("TraceabilityRegistry:   ", traceRegAddr);
  console.log("PLASMAConnector:        ", plasmaAddr);
  console.log("TraceConnector:         ", traceAddr);
  console.log("ZKVerifier:             ", zkVerifierAddr);
  console.log("StateCommitment:        ", stateCommitAddr);
  console.log("DACAttestation:         ", dacAddr, "(threshold:", DAC_THRESHOLD, ")");
  console.log("CrossEnterpriseVerifier:", crossVerifierAddr);
  console.log("========================================");

  // Write deployment record
  const record = {
    network: "basisFuji",
    chainId: 43199,
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    subnetId: "AYdFRP6MsbHq51MnUqmg5o4Eb92jPTgyPvq92dDQULVo9pwAk",
    blockchainId: "2VtYqDeZ5RabHM8zA4x94T6DMdzs3svkfcpF7TLEmTpETUTufR",
    contracts: {
      enterpriseRegistry: registryAddr,
      traceabilityRegistry: traceRegAddr,
      plasmaConnector: plasmaAddr,
      traceConnector: traceAddr,
      zkVerifier: zkVerifierAddr,
      stateCommitment: stateCommitAddr,
      dacAttestation: { address: dacAddr, threshold: DAC_THRESHOLD },
      crossEnterpriseVerifier: crossVerifierAddr,
    },
  };

  const recordDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(recordDir)) fs.mkdirSync(recordDir, { recursive: true });
  fs.writeFileSync(
    path.join(recordDir, "basis-fuji-v2.json"),
    JSON.stringify(record, null, 2)
  );
  console.log("\nDeployment record saved to deployments/basis-fuji-v2.json");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });
