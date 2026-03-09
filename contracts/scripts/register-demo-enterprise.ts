import { ethers } from "hardhat";

/// Registers the deployer (ewoq) as a demo enterprise so the adapter demo can run.
async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Registering demo enterprise with:", deployer.address);

  const registry = await ethers.getContractAt(
    "EnterpriseRegistry",
    "0x4Ac1d98D9cEF99EC6546dEd4Bd550b0b287aaD6D"
  );

  // Register the deployer as "Ingenio Sancarlos" (demo enterprise)
  const metadata = ethers.toUtf8Bytes(JSON.stringify({
    industry: "agroindustry",
    country: "CO",
    city: "Cali",
    product: "PLASMA"
  }));

  await registry.registerEnterprise(
    deployer.address,
    "Ingenio Sancarlos",
    metadata
  );
  console.log("Registered: Ingenio Sancarlos");

  // Verify registration
  const enterprise = await registry.getEnterprise(deployer.address);
  console.log("Enterprise:", enterprise.name, "| Active:", enterprise.active);
  console.log("Total enterprises:", (await registry.enterpriseCount()).toString());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
