/**
 * Deploy Validium-specific contracts to Basis Network (Fuji).
 *
 * Deploys 3 new contracts that integrate with the existing L1 infrastructure:
 *   1. StateCommitment -- per-enterprise ZK state root chains
 *   2. DACAttestation  -- Data Availability Committee on-chain attestation
 *   3. CrossEnterpriseVerifier -- hub-and-spoke cross-enterprise proof verification
 *
 * Prerequisites:
 *   - EnterpriseRegistry must already be deployed (address in .env or below)
 *   - Deployer account must have LITHOS for gas (zero-fee, but needs funded account)
 *   - StateCommitment needs StateCommitment address and EnterpriseRegistry
 *
 * Usage:
 *   PRIVATE_KEY=0x... npx hardhat run scripts/deploy-validium.ts --network basisFuji
 *
 * Environment variables:
 *   PRIVATE_KEY            -- Deployer private key (hex with 0x)
 *   ENTERPRISE_REGISTRY    -- Existing EnterpriseRegistry address on Fuji
 *   STATE_COMMITMENT_ADDR  -- (output) Set after deployment for node config
 */

import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

// Existing contract addresses on Fuji (from .internal/deployments.md)
const FUJI_ENTERPRISE_REGISTRY =
  process.env.ENTERPRISE_REGISTRY || "0xe10CCf26c7Cb6CB81b47C8Da72E427628c8a5E09";

// DAC configuration: 2-of-3 threshold (matches Shamir (2,3)-SS in node)
const DAC_THRESHOLD = 2;

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=== Validium Contract Deployment ===\n");
  console.log("Deployer:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "LITHOS");
  console.log("EnterpriseRegistry:", FUJI_ENTERPRISE_REGISTRY);

  // Verify EnterpriseRegistry is accessible
  const registryCode = await ethers.provider.getCode(FUJI_ENTERPRISE_REGISTRY);
  if (registryCode === "0x") {
    throw new Error(
      `EnterpriseRegistry not found at ${FUJI_ENTERPRISE_REGISTRY}. ` +
        "Ensure the address is correct and the network is accessible."
    );
  }
  console.log("EnterpriseRegistry verified (bytecode present)\n");

  // -----------------------------------------------------------------------
  // 1. Deploy StateCommitment
  // -----------------------------------------------------------------------
  console.log("--- [1/3] Deploying StateCommitment ---");
  const StateCommitment = await ethers.getContractFactory("StateCommitment");
  const stateCommitment = await StateCommitment.deploy(FUJI_ENTERPRISE_REGISTRY);
  await stateCommitment.waitForDeployment();
  const stateCommitmentAddress = await stateCommitment.getAddress();
  console.log("StateCommitment deployed to:", stateCommitmentAddress);

  // -----------------------------------------------------------------------
  // 2. Deploy DACAttestation
  // -----------------------------------------------------------------------
  console.log("\n--- [2/3] Deploying DACAttestation ---");
  const DACAttestation = await ethers.getContractFactory("DACAttestation");
  const dacAttestation = await DACAttestation.deploy(
    FUJI_ENTERPRISE_REGISTRY,
    DAC_THRESHOLD
  );
  await dacAttestation.waitForDeployment();
  const dacAttestationAddress = await dacAttestation.getAddress();
  console.log("DACAttestation deployed to:", dacAttestationAddress);
  console.log("  Threshold: k =", DAC_THRESHOLD);

  // -----------------------------------------------------------------------
  // 3. Deploy CrossEnterpriseVerifier
  // -----------------------------------------------------------------------
  console.log("\n--- [3/3] Deploying CrossEnterpriseVerifier ---");
  const CrossEnterpriseVerifier = await ethers.getContractFactory(
    "CrossEnterpriseVerifier"
  );
  const crossVerifier = await CrossEnterpriseVerifier.deploy(
    FUJI_ENTERPRISE_REGISTRY,
    stateCommitmentAddress
  );
  await crossVerifier.waitForDeployment();
  const crossVerifierAddress = await crossVerifier.getAddress();
  console.log("CrossEnterpriseVerifier deployed to:", crossVerifierAddress);
  console.log("  References StateCommitment at:", stateCommitmentAddress);

  // -----------------------------------------------------------------------
  // Summary
  // -----------------------------------------------------------------------
  console.log("\n========================================");
  console.log("   VALIDIUM DEPLOYMENT SUMMARY");
  console.log("========================================");
  console.log("Network:                Basis Network (Fuji)");
  console.log("Deployer:              ", deployer.address);
  console.log("EnterpriseRegistry:    ", FUJI_ENTERPRISE_REGISTRY, "(existing)");
  console.log("StateCommitment:       ", stateCommitmentAddress, "(NEW)");
  console.log("DACAttestation:        ", dacAttestationAddress, "(NEW)");
  console.log("CrossEnterpriseVerifier:", crossVerifierAddress, "(NEW)");
  console.log("DAC Threshold:          k =", DAC_THRESHOLD);
  console.log("========================================");

  // Write deployment record
  const deploymentRecord = {
    network: "basisFuji",
    chainId: 43199,
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    contracts: {
      enterpriseRegistry: {
        address: FUJI_ENTERPRISE_REGISTRY,
        status: "existing",
      },
      stateCommitment: {
        address: stateCommitmentAddress,
        status: "new",
      },
      dacAttestation: {
        address: dacAttestationAddress,
        status: "new",
        threshold: DAC_THRESHOLD,
      },
      crossEnterpriseVerifier: {
        address: crossVerifierAddress,
        status: "new",
        referencesStateCommitment: stateCommitmentAddress,
      },
    },
  };

  const recordPath = path.join(__dirname, "..", "deployments", "validium-fuji.json");
  const recordDir = path.dirname(recordPath);
  if (!fs.existsSync(recordDir)) {
    fs.mkdirSync(recordDir, { recursive: true });
  }
  fs.writeFileSync(recordPath, JSON.stringify(deploymentRecord, null, 2));
  console.log("\nDeployment record saved to:", recordPath);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("Deployment failed:", error);
    process.exit(1);
  });
