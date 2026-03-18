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

  // 3. Deploy PLASMAConnector
  console.log("\n--- Deploying PLASMAConnector ---");
  const PLASMAConnector = await ethers.getContractFactory("PLASMAConnector");
  const plasmaConnector = await PLASMAConnector.deploy(
    enterpriseRegistryAddress,
    traceabilityRegistryAddress
  );
  await plasmaConnector.waitForDeployment();
  const plasmaConnectorAddress = await plasmaConnector.getAddress();
  console.log("PLASMAConnector deployed to:", plasmaConnectorAddress);

  // 4. Deploy TraceConnector
  console.log("\n--- Deploying TraceConnector ---");
  const TraceConnector = await ethers.getContractFactory("TraceConnector");
  const traceConnector = await TraceConnector.deploy(
    enterpriseRegistryAddress,
    traceabilityRegistryAddress
  );
  await traceConnector.waitForDeployment();
  const traceConnectorAddress = await traceConnector.getAddress();
  console.log("TraceConnector deployed to:", traceConnectorAddress);

  // 5. Deploy ZKVerifier
  console.log("\n--- Deploying ZKVerifier ---");
  const ZKVerifier = await ethers.getContractFactory("ZKVerifier");
  const zkVerifier = await ZKVerifier.deploy(enterpriseRegistryAddress);
  await zkVerifier.waitForDeployment();
  const zkVerifierAddress = await zkVerifier.getAddress();
  console.log("ZKVerifier deployed to:", zkVerifierAddress);

  // 6. Deploy StateCommitment
  console.log("\n--- Deploying StateCommitment ---");
  const StateCommitment = await ethers.getContractFactory("StateCommitment");
  const stateCommitment = await StateCommitment.deploy(enterpriseRegistryAddress);
  await stateCommitment.waitForDeployment();
  const stateCommitmentAddress = await stateCommitment.getAddress();
  console.log("StateCommitment deployed to:", stateCommitmentAddress);

  // 7. Register connector contracts as authorized enterprises
  console.log("\n--- Registering connector contracts as authorized ---");
  const connectorMetadata = ethers.toUtf8Bytes('{"type":"system_connector"}');

  await enterpriseRegistry.registerEnterprise(
    plasmaConnectorAddress,
    "PLASMAConnector",
    connectorMetadata
  );
  console.log("PLASMAConnector registered as authorized enterprise");

  await enterpriseRegistry.registerEnterprise(
    traceConnectorAddress,
    "TraceConnector",
    connectorMetadata
  );
  console.log("TraceConnector registered as authorized enterprise");

  // Summary
  console.log("\n========================================");
  console.log("       DEPLOYMENT SUMMARY");
  console.log("========================================");
  console.log("EnterpriseRegistry:    ", enterpriseRegistryAddress);
  console.log("TraceabilityRegistry:  ", traceabilityRegistryAddress);
  console.log("PLASMAConnector:       ", plasmaConnectorAddress);
  console.log("TraceConnector:        ", traceConnectorAddress);
  console.log("ZKVerifier:            ", zkVerifierAddress);
  console.log("StateCommitment:       ", stateCommitmentAddress);
  console.log("========================================");
  console.log("\nSave these addresses in your .env files.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
