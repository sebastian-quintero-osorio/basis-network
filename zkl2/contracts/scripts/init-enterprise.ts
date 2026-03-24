/// Initialize the submitter enterprise on BasisRollup.sol with the real Poseidon SMT genesis root.
///
/// The genesis root 0x051bd962... is computed by the Go node after funding 2 genesis accounts:
///   1. 0x8db97C7cEcE249c2b98bDC0226Cc4C2A57BF52FC (ewoq test default, 1M LITHOS)
///   2. 0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD (deployer/admin, 1M LITHOS)
///
/// The root is computed using Poseidon hash over BN254 field elements in a depth-32 SMT.
///
/// Usage:
///   npx hardhat run scripts/init-enterprise.ts --network basis
///
/// Prerequisites:
///   - DEPLOYER_KEY in .env (admin of BasisRollup)
///   - BasisRollup deployed at the address below

import { ethers } from "hardhat";

// Deployed BasisRollup address (from 2026-03-21 deployment)
const BASIS_ROLLUP = "0x65219ceCe953f1CA4ce789aa351295618fe81183";

// Real Poseidon SMT genesis root (computed by Go node after funding genesis accounts).
// This MUST match what the Go node computes in initNode() -> cmd/basis-l2/main.go
const GENESIS_ROOT = "0x051bd9624f8e73bd4b90264dde147423adb94c1933487669ec269afb1f80bbf4";

// Enterprise = submitter address (same as deployer/admin)
const ENTERPRISE = "0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD";

async function main() {
  const [signer] = await ethers.getSigners();

  console.log("=== Initialize Enterprise on BasisRollup ===\n");
  console.log("Signer:", signer.address);
  console.log("BasisRollup:", BASIS_ROLLUP);
  console.log("Enterprise:", ENTERPRISE);
  console.log("Genesis Root:", GENESIS_ROOT);
  console.log("");

  // Minimal ABI for initializeEnterprise and enterprises mapping
  const abi = [
    "function initializeEnterprise(address enterprise, bytes32 genesisRoot) external",
    "function enterprises(address) view returns (bytes32 currentRoot, uint64 committedBatches, uint64 provenBatches, uint64 executedBatches, bool initialized, uint64 lastL2Block)",
    "function admin() view returns (address)",
  ];

  const rollup = new ethers.Contract(BASIS_ROLLUP, abi, signer);

  // Check admin
  const admin = await rollup.admin();
  console.log("BasisRollup admin:", admin);
  if (admin.toLowerCase() !== signer.address.toLowerCase()) {
    console.error("ERROR: signer is not the admin of BasisRollup");
    console.error("  Expected:", admin);
    console.error("  Got:", signer.address);
    process.exit(1);
  }

  // Check if already initialized
  const state = await rollup.enterprises(ENTERPRISE);
  if (state.initialized) {
    console.log("\nEnterprise is ALREADY initialized!");
    console.log("  currentRoot:", state.currentRoot);
    console.log("  committedBatches:", state.committedBatches.toString());
    console.log("  executedBatches:", state.executedBatches.toString());
    if (state.currentRoot === GENESIS_ROOT) {
      console.log("  Status: Root matches -- ready for batch submission");
    } else {
      console.log("  Status: Root does NOT match genesis -- batches have been submitted");
    }
    return;
  }

  // Initialize
  console.log("Sending initializeEnterprise transaction...");
  const tx = await rollup.initializeEnterprise(ENTERPRISE, GENESIS_ROOT);
  console.log("  TX hash:", tx.hash);

  const receipt = await tx.wait();
  console.log("  Confirmed in block:", receipt!.blockNumber);
  console.log("  Gas used:", receipt!.gasUsed.toString());

  // Verify
  const newState = await rollup.enterprises(ENTERPRISE);
  if (!newState.initialized) {
    throw new Error("Enterprise not initialized after tx confirmed!");
  }
  if (newState.currentRoot !== GENESIS_ROOT) {
    throw new Error(`Root mismatch: expected ${GENESIS_ROOT}, got ${newState.currentRoot}`);
  }

  console.log("\nSUCCESS! Enterprise initialized with Poseidon SMT genesis root.");
  console.log("The zkL2 node can now submit batches via L1Submitter.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\nFAILED:", error.message || error);
    process.exit(1);
  });
