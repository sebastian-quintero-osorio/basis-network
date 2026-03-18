import { ethers } from "hardhat";

/**
 * Deactivates the "Ingenio Sancarlos" enterprise from the EnterpriseRegistry.
 *
 * The deployer address was incorrectly registered as "Ingenio Sancarlos" —
 * it is actually a client of PLASMA, not a SaaS enterprise.  This script
 * calls deactivateEnterprise() on the already-deployed registry contract.
 *
 * Usage:
 *   npx hardhat run scripts/deactivate-ingenio.ts --network basisLocal
 */
async function main() {
  const REGISTRY_ADDRESS = "0xe10CCf26c7Cb6CB81b47C8Da72E427628c8a5E09";
  const [deployer] = await ethers.getSigners();

  console.log("=== Deactivate Ingenio Sancarlos ===\n");
  console.log("Deployer (admin):", deployer.address);
  console.log("Registry contract:", REGISTRY_ADDRESS);

  const registry = await ethers.getContractAt("EnterpriseRegistry", REGISTRY_ADDRESS);

  // Verify admin
  const admin = await registry.admin();
  console.log("On-chain admin:  ", admin);
  if (admin.toLowerCase() !== deployer.address.toLowerCase()) {
    throw new Error(`Deployer ${deployer.address} is not the admin (${admin}). Cannot deactivate.`);
  }

  // Check current state
  const [name, , active] = await registry.getEnterprise(deployer.address);
  console.log(`\nEnterprise "${name}" active: ${active}`);

  if (!active) {
    console.log("Enterprise is already deactivated. Nothing to do.");
    return;
  }

  // Deactivate
  console.log("\nSending deactivateEnterprise() transaction...");
  const tx = await registry.deactivateEnterprise(deployer.address);
  const receipt = await tx.wait();
  console.log("Transaction hash:", receipt?.hash);
  console.log("Gas used:        ", receipt?.gasUsed.toString());

  // Confirm
  const [, , activeAfter] = await registry.getEnterprise(deployer.address);
  console.log(`\nEnterprise "${name}" active after deactivation: ${activeAfter}`);
  console.log("\nDone. Ingenio Sancarlos has been deactivated.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
