/// Deploy BasisRollupV2 + PlonkVerifier with real PLONK-KZG verification.
/// Usage: npx hardhat run scripts/deploy-rollup-v2.ts --network basis

import { ethers } from "hardhat";

const ENTERPRISE_REGISTRY = "0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5";
const GENESIS_ROOT = "0x051bd9624f8e73bd4b90264dde147423adb94c1933487669ec269afb1f80bbf4";

// BN254 field prime
const BN254_P = 21888242871839275222246405745257275088696311157297823662689037894645226208583n;

// SRS G2 point [s]_2 -- extracted from prover's srs_k8.bin (last 128 bytes).
// IMPORTANT: Values are stored in EIP-197 order [x_im, x_re, y_im, y_re] = [c1, c0, c1, c0]
// because PlonkVerifier.sol loads storage slots sequentially into pairing precompile input.
// Raw from srs_k8.bin: x_c0, x_c1, y_c0, y_c1 -> swap to: x_c1, x_c0, y_c1, y_c0
const SRS_G2: [bigint, bigint, bigint, bigint] = [
  2774928779652883445308576906053599272829312001650464460343323818059945932295n,   // x_c1 (im)
  732948610097057034243540629714181771975732218873181707971662536395319172753n,    // x_c0 (re)
  11369161436646506818663685590760975229861917155415574567801499804903916296000n,  // y_c1 (im)
  12463083803411924700131709876838824828992696709321039385790180151355705267957n,  // y_c0 (re)
];

// Negative G2 generator -[1]_2 -- extracted from srs_k8.bin (offset -256).
// Raw: x_c0, x_c1, y_c0, y_c1 -> swap to: x_c1, x_c0, -(y_c1), -(y_c0)
const NEG_G2: [bigint, bigint, bigint, bigint] = [
  9496696083199853777875401760424613833161720860855390556979200160215841136960n,   // x_c1 (im)
  11461925177900819176832270005713103520318409907105193817603008068482420711462n,  // x_c0 (re)
  BN254_P - 6170940445994484564222204938066213705353407449799250191249554538140978927342n,   // -(y_c1)
  BN254_P - 18540402224736191443939503902445128293982106376239432540843647066670759668214n,  // -(y_c0)
];

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("=== Deploy BasisRollupV2 + PlonkVerifier ===\n");
  console.log("Deployer:", deployer.address);
  console.log("Chain ID:", (await ethers.provider.getNetwork()).chainId.toString());

  // 1. Deploy PlonkVerifier
  console.log("\n[1/4] Deploying PlonkVerifier...");
  const PlonkVerifier = await ethers.getContractFactory("PlonkVerifier");
  const plonk = await PlonkVerifier.deploy();
  await plonk.waitForDeployment();
  const plonkAddr = await plonk.getAddress();
  console.log("  PlonkVerifier:", plonkAddr);

  // Configure VK with real BN254 G2 constants
  console.log("  Configuring VK (k=14, numPublicInputs=3, real BN254 G2 points)...");
  const vkDigest = ethers.keccak256(ethers.toUtf8Bytes("basis-l2-plonk-vk-v1"));
  const configTx = await plonk.configureVK(SRS_G2, NEG_G2, 14, 3, vkDigest);
  await configTx.wait();
  console.log("  VK configured");

  // 2. Deploy BasisRollupV2
  console.log("\n[2/4] Deploying BasisRollupV2...");
  const BasisRollupV2 = await ethers.getContractFactory("BasisRollupV2");
  const rollup = await BasisRollupV2.deploy(ENTERPRISE_REGISTRY);
  await rollup.waitForDeployment();
  const rollupAddr = await rollup.getAddress();
  console.log("  BasisRollupV2:", rollupAddr);

  // Set PlonkVerifier on BasisRollupV2
  console.log("  Setting PlonkVerifier...");
  const setTx = await rollup.setPlonkVerifier(plonkAddr);
  await setTx.wait();
  console.log("  PlonkVerifier set");

  // 3. Initialize enterprise
  console.log("\n[3/4] Initializing enterprise...");
  const initTx = await rollup.initializeEnterprise(deployer.address, GENESIS_ROOT);
  await initTx.wait();
  console.log("  Enterprise initialized with genesis root:", GENESIS_ROOT);

  // 4. Verify
  console.log("\n[4/4] Verification...");
  const root = await rollup.getCurrentRoot(deployer.address);
  const pvSet = await rollup.plonkVerifierSet();
  console.log("  currentRoot:", root);
  console.log("  rootMatch:", root === GENESIS_ROOT);
  console.log("  plonkVerifierSet:", pvSet);

  console.log("\n=== SUCCESS ===");
  console.log("PlonkVerifier:", plonkAddr);
  console.log("BasisRollupV2:", rollupAddr);
  console.log("\nUpdate config:");
  console.log(`  BASIS_ROLLUP_ADDRESS=${rollupAddr}`);
}

main()
  .then(() => process.exit(0))
  .catch((e) => { console.error("FAILED:", e.message || e); process.exit(1); });
