/// setup_state_transition.js -- Trusted setup for the StateTransition circuit.
///
/// Performs a Groth16 trusted setup:
///   1. Powers of Tau ceremony (phase 1) -- reuses existing pot if available
///   2. Phase 2 preparation
///   3. Circuit-specific proving key (zkey) generation
///   4. Verification key export
///
/// The state_transition circuit at depth=10, batch=4 produces ~45K constraints,
/// requiring at least pot16 (2^16 = 65536). For production depth=32, pot18+ is needed.
///
/// Usage: node setup_state_transition.js [potPower]
///   potPower: Power of 2 for the ceremony (default: 16)
///
/// [Spec: validium/specs/units/2026-03-state-transition-circuit/1-formalization/v0-analysis/specs/StateTransitionCircuit/StateTransitionCircuit.tla]

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const POT_POWER = parseInt(process.argv[2]) || 16;

const ROOT = path.join(__dirname, "..");
const BUILD_DIR = path.join(ROOT, "build", "state_transition");
const POT_DIR = path.join(ROOT, "pot");

function run(cmd) {
    console.log(`  $ ${cmd}`);
    execSync(cmd, { stdio: "inherit", cwd: ROOT });
}

function fileExists(filePath) {
    return fs.existsSync(filePath);
}

async function main() {
    // Ensure directories exist
    if (!fs.existsSync(BUILD_DIR)) fs.mkdirSync(BUILD_DIR, { recursive: true });
    if (!fs.existsSync(POT_DIR)) fs.mkdirSync(POT_DIR, { recursive: true });

    const potName = `pot${POT_POWER}`;
    const potInitial = path.join(POT_DIR, `${potName}_0000.ptau`);
    const potContrib = path.join(POT_DIR, `${potName}_0001.ptau`);
    const potFinal = path.join(POT_DIR, `${potName}_final.ptau`);

    console.log("=== Trusted Setup: StateTransition Circuit ===\n");
    console.log(`Powers of Tau: 2^${POT_POWER} = ${Math.pow(2, POT_POWER)} max constraints\n`);

    // Step 1: Powers of Tau ceremony (skip if final ptau already exists)
    if (fileExists(potFinal)) {
        console.log(`Step 1: Reusing existing ${potName}_final.ptau`);
    } else {
        console.log("Step 1: Starting Powers of Tau ceremony...");
        run(`npx snarkjs powersoftau new bn128 ${POT_POWER} ${path.relative(ROOT, potInitial)}`);
        console.log("  - Initial accumulator created");

        run(`npx snarkjs powersoftau contribute ${path.relative(ROOT, potInitial)} ${path.relative(ROOT, potContrib)} --name="Basis Network StateTransition" -e="basis-st-entropy-${Date.now()}"`);
        console.log("  - Contribution added");

        console.log("\nStep 2: Preparing phase 2...");
        run(`npx snarkjs powersoftau prepare phase2 ${path.relative(ROOT, potContrib)} ${path.relative(ROOT, potFinal)}`);
        console.log("  - Phase 2 prepared");
    }

    // Step 2: Verify circuit is compiled
    const r1csPath = path.join(BUILD_DIR, "state_transition.r1cs");
    if (!fileExists(r1csPath)) {
        console.log("\nCircuit not compiled. Compiling now...");
        run(`circom circuits/state_transition.circom --r1cs --wasm --sym -o build/state_transition/`);
    }

    // Step 3: R1CS info
    console.log("\nCircuit info:");
    run(`npx snarkjs r1cs info ${path.relative(ROOT, r1csPath)}`);

    // Step 4: Generate proving key (zkey)
    const zkey0 = path.join(BUILD_DIR, "state_transition_0000.zkey");
    const zkeyFinal = path.join(BUILD_DIR, "state_transition_final.zkey");

    console.log("\nStep 3: Generating proving key (zkey)...");
    run(`npx snarkjs groth16 setup ${path.relative(ROOT, r1csPath)} ${path.relative(ROOT, potFinal)} ${path.relative(ROOT, zkey0)}`);

    run(`npx snarkjs zkey contribute ${path.relative(ROOT, zkey0)} ${path.relative(ROOT, zkeyFinal)} --name="Basis Network StateTransition zKey" -e="basis-st-zkey-${Date.now()}"`);
    console.log("  - Proving key generated");

    // Step 5: Export verification key
    const vkPath = path.join(BUILD_DIR, "verification_key.json");
    console.log("\nStep 4: Exporting verification key...");
    run(`npx snarkjs zkey export verificationkey ${path.relative(ROOT, zkeyFinal)} ${path.relative(ROOT, vkPath)}`);
    console.log("  - Verification key exported");

    // Step 6: Export Solidity verifier
    const solPath = path.join(BUILD_DIR, "StateTransitionVerifier.sol");
    console.log("\nStep 5: Exporting Solidity verifier...");
    run(`npx snarkjs zkey export solidityverifier ${path.relative(ROOT, zkeyFinal)} ${path.relative(ROOT, solPath)}`);
    console.log("  - Solidity verifier exported");

    console.log("\n=== Setup Complete ===");
    console.log("Files generated:");
    console.log(`  - ${path.relative(ROOT, potFinal)} (Powers of Tau)`);
    console.log(`  - ${path.relative(ROOT, zkeyFinal)} (Proving key)`);
    console.log(`  - ${path.relative(ROOT, vkPath)} (Verification key)`);
    console.log(`  - ${path.relative(ROOT, solPath)} (Solidity verifier)`);
}

main().catch(err => {
    console.error("Setup failed:", err);
    process.exit(1);
});
