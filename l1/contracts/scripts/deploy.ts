import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // 1. Deploy EnterpriseRegistry
  console.log("\n--- Deploying EnterpriseRegistry ---");
  const EnterpriseRegistry = await ethers.getContractFactory("EnterpriseRegistry");
  const enterpriseRegistry = await EnterpriseRegistry.deploy();
  await enterpriseRegistry.waitForDeployment();
  const enterpriseRegistryAddress = await enterpriseRegistry.getAddress();
  console.log("EnterpriseRegistry deployed to:", enterpriseRegistryAddress);

  // 2. Deploy TraceabilityRegistry
  console.log("\n--- Deploying TraceabilityRegistry ---");
  const TraceabilityRegistry = await ethers.getContractFactory("TraceabilityRegistry");
  const traceabilityRegistry = await TraceabilityRegistry.deploy(enterpriseRegistryAddress);
  await traceabilityRegistry.waitForDeployment();
  const traceabilityRegistryAddress = await traceabilityRegistry.getAddress();
  console.log("TraceabilityRegistry deployed to:", traceabilityRegistryAddress);

  // 3. Deploy ZKVerifier
  console.log("\n--- Deploying ZKVerifier ---");
  const ZKVerifier = await ethers.getContractFactory("ZKVerifier");
  const zkVerifier = await ZKVerifier.deploy(enterpriseRegistryAddress);
  await zkVerifier.waitForDeployment();
  const zkVerifierAddress = await zkVerifier.getAddress();
  console.log("ZKVerifier deployed to:", zkVerifierAddress);

  // 4. Deploy StateCommitment
  console.log("\n--- Deploying StateCommitment ---");
  const StateCommitment = await ethers.getContractFactory("StateCommitment");
  const stateCommitment = await StateCommitment.deploy(enterpriseRegistryAddress);
  await stateCommitment.waitForDeployment();
  const stateCommitmentAddress = await stateCommitment.getAddress();
  console.log("StateCommitment deployed to:", stateCommitmentAddress);

  // 5. Deploy DACAttestation
  console.log("\n--- Deploying DACAttestation ---");
  const DACAttestation = await ethers.getContractFactory("DACAttestation");
  const dacAttestation = await DACAttestation.deploy(enterpriseRegistryAddress, 1);
  await dacAttestation.waitForDeployment();
  const dacAttestationAddress = await dacAttestation.getAddress();
  console.log("DACAttestation deployed to:", dacAttestationAddress);

  // 6. Deploy CrossEnterpriseVerifier
  console.log("\n--- Deploying CrossEnterpriseVerifier ---");
  const CrossEnterpriseVerifier = await ethers.getContractFactory("CrossEnterpriseVerifier");
  const crossEnterpriseVerifier = await CrossEnterpriseVerifier.deploy(
    stateCommitmentAddress,
    enterpriseRegistryAddress
  );
  await crossEnterpriseVerifier.waitForDeployment();
  const crossEnterpriseVerifierAddress = await crossEnterpriseVerifier.getAddress();
  console.log("CrossEnterpriseVerifier deployed to:", crossEnterpriseVerifierAddress);

  // Summary
  console.log("\n========================================");
  console.log("       DEPLOYMENT SUMMARY");
  console.log("========================================");
  console.log("EnterpriseRegistry:       ", enterpriseRegistryAddress);
  console.log("TraceabilityRegistry:     ", traceabilityRegistryAddress);
  console.log("ZKVerifier:               ", zkVerifierAddress);
  console.log("StateCommitment:          ", stateCommitmentAddress);
  console.log("DACAttestation:           ", dacAttestationAddress);
  console.log("CrossEnterpriseVerifier:  ", crossEnterpriseVerifierAddress);
  console.log("========================================");
  console.log("\nSave these addresses in your .env files.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
