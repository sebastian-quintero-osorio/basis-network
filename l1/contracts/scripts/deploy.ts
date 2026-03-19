import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);
  console.log("Balance:", (await ethers.provider.getBalance(deployer.address)).toString());

  // 1. EnterpriseRegistry
  console.log("\n[1/7] EnterpriseRegistry");
  const ER = await ethers.getContractFactory("EnterpriseRegistry");
  const er = await ER.deploy();
  await er.waitForDeployment();
  const erAddr = await er.getAddress();
  console.log("  ->", erAddr);

  // 2. TraceabilityRegistry
  console.log("[2/7] TraceabilityRegistry");
  const TR = await ethers.getContractFactory("TraceabilityRegistry");
  const tr = await TR.deploy(erAddr);
  await tr.waitForDeployment();
  console.log("  ->", await tr.getAddress());

  // 3. ZKVerifier
  console.log("[3/7] ZKVerifier");
  const ZK = await ethers.getContractFactory("ZKVerifier");
  const zk = await ZK.deploy(erAddr);
  await zk.waitForDeployment();
  console.log("  ->", await zk.getAddress());

  // 4. Groth16Verifier (snarkjs-generated, VK baked in)
  console.log("[4/7] Groth16Verifier");
  const GV = await ethers.getContractFactory("Groth16Verifier");
  const gv = await GV.deploy();
  await gv.waitForDeployment();
  const gvAddr = await gv.getAddress();
  console.log("  ->", gvAddr);

  // 5. StateCommitment
  console.log("[5/7] StateCommitment");
  const SC = await ethers.getContractFactory("StateCommitment");
  const sc = await SC.deploy(erAddr);
  await sc.waitForDeployment();
  const scAddr = await sc.getAddress();
  console.log("  ->", scAddr);

  // Set Groth16Verifier on StateCommitment
  await sc.setVerifier(gvAddr);
  console.log("  Verifier set!");

  // 6. DACAttestation
  console.log("[6/7] DACAttestation");
  const DAC = await ethers.getContractFactory("DACAttestation");
  const dac = await DAC.deploy(erAddr, 2);
  await dac.waitForDeployment();
  console.log("  ->", await dac.getAddress());

  // 7. CrossEnterpriseVerifier
  console.log("[7/7] CrossEnterpriseVerifier");
  const CEV = await ethers.getContractFactory("CrossEnterpriseVerifier");
  const cev = await CEV.deploy(scAddr, erAddr);
  await cev.waitForDeployment();
  console.log("  ->", await cev.getAddress());

  console.log("\n========================================");
  console.log("EnterpriseRegistry:     ", erAddr);
  console.log("TraceabilityRegistry:   ", await tr.getAddress());
  console.log("ZKVerifier:             ", await zk.getAddress());
  console.log("Groth16Verifier:        ", gvAddr);
  console.log("StateCommitment:        ", scAddr);
  console.log("DACAttestation:         ", await dac.getAddress());
  console.log("CrossEnterpriseVerifier:", await cev.getAddress());
  console.log("========================================");
}

main().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
