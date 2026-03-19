#!/bin/bash
# benchmark.sh -- Compile, generate witness, and benchmark the state transition circuit.
#
# Usage: bash benchmark.sh [depth] [batchSize]
# Default: depth=10, batchSize=4

set -e

DEPTH=${1:-10}
BATCH_SIZE=${2:-4}
CIRCUIT_NAME="state_transition_d${DEPTH}_b${BATCH_SIZE}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPERIMENT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="${EXPERIMENT_DIR}/results"
BUILD_DIR="${RESULTS_DIR}/build_${CIRCUIT_NAME}"
CIRCUITS_DIR="$(cd "${SCRIPT_DIR}/../../../../circuits" && pwd)"

echo "=== State Transition Circuit Benchmark ==="
echo "Depth: ${DEPTH}, Batch Size: ${BATCH_SIZE}"
echo "Build dir: ${BUILD_DIR}"
echo ""

mkdir -p "${BUILD_DIR}"
mkdir -p "${RESULTS_DIR}"

# Step 0: Generate parameterized circuit
echo "--- Step 0: Generate parameterized circuit ---"
PARAM_CIRCUIT="${BUILD_DIR}/${CIRCUIT_NAME}.circom"
CIRCOMLIB_DIR="${CIRCUITS_DIR}/node_modules"
cat > "${PARAM_CIRCUIT}" << EOF
pragma circom 2.0.0;

include "circomlib/circuits/poseidon.circom";
include "circomlib/circuits/comparators.circom";
include "circomlib/circuits/mux1.circom";

template MerklePathVerifier(depth) {
    signal input leaf;
    signal input siblings[depth];
    signal input pathBits[depth];
    signal output root;

    signal intermediateHashes[depth + 1];
    intermediateHashes[0] <== leaf;

    component hashers[depth];
    component muxLeft[depth];
    component muxRight[depth];

    for (var i = 0; i < depth; i++) {
        muxLeft[i] = Mux1();
        muxLeft[i].c[0] <== intermediateHashes[i];
        muxLeft[i].c[1] <== siblings[i];
        muxLeft[i].s <== pathBits[i];

        muxRight[i] = Mux1();
        muxRight[i].c[0] <== siblings[i];
        muxRight[i].c[1] <== intermediateHashes[i];
        muxRight[i].s <== pathBits[i];

        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== muxLeft[i].out;
        hashers[i].inputs[1] <== muxRight[i].out;

        intermediateHashes[i + 1] <== hashers[i].out;
    }

    root <== intermediateHashes[depth];
}

template ChainedBatchStateTransition(depth, batchSize) {
    signal input prevStateRoot;
    signal input newStateRoot;
    signal input batchNum;
    signal input enterpriseId;

    signal input keys[batchSize];
    signal input oldValues[batchSize];
    signal input newValues[batchSize];
    signal input siblings[batchSize][depth];
    signal input pathBits[batchSize][depth];

    component oldLeafHashers[batchSize];
    component newLeafHashers[batchSize];
    component oldPathVerifiers[batchSize];
    component newPathVerifiers[batchSize];
    component oldRootChecks[batchSize];

    signal chainedRoots[batchSize + 1];
    chainedRoots[0] <== prevStateRoot;

    for (var i = 0; i < batchSize; i++) {
        oldLeafHashers[i] = Poseidon(2);
        oldLeafHashers[i].inputs[0] <== keys[i];
        oldLeafHashers[i].inputs[1] <== oldValues[i];

        newLeafHashers[i] = Poseidon(2);
        newLeafHashers[i].inputs[0] <== keys[i];
        newLeafHashers[i].inputs[1] <== newValues[i];

        oldPathVerifiers[i] = MerklePathVerifier(depth);
        oldPathVerifiers[i].leaf <== oldLeafHashers[i].out;
        for (var j = 0; j < depth; j++) {
            oldPathVerifiers[i].siblings[j] <== siblings[i][j];
            oldPathVerifiers[i].pathBits[j] <== pathBits[i][j];
        }

        oldRootChecks[i] = IsEqual();
        oldRootChecks[i].in[0] <== oldPathVerifiers[i].root;
        oldRootChecks[i].in[1] <== chainedRoots[i];
        oldRootChecks[i].out === 1;

        newPathVerifiers[i] = MerklePathVerifier(depth);
        newPathVerifiers[i].leaf <== newLeafHashers[i].out;
        for (var j = 0; j < depth; j++) {
            newPathVerifiers[i].siblings[j] <== siblings[i][j];
            newPathVerifiers[i].pathBits[j] <== pathBits[i][j];
        }

        chainedRoots[i + 1] <== newPathVerifiers[i].root;
    }

    component finalCheck = IsEqual();
    finalCheck.in[0] <== chainedRoots[batchSize];
    finalCheck.in[1] <== newStateRoot;
    finalCheck.out === 1;
}

component main {public [prevStateRoot, newStateRoot, batchNum, enterpriseId]} = ChainedBatchStateTransition(${DEPTH}, ${BATCH_SIZE});
EOF
echo "Generated parameterized circuit: ${PARAM_CIRCUIT}"

# Step 1: Compile circuit
echo ""
echo "--- Step 1: Compile circuit ---"
COMPILE_START=$(date +%s%3N)
circom "${PARAM_CIRCUIT}" \
    --r1cs \
    --wasm \
    --sym \
    -l "${CIRCOMLIB_DIR}" \
    -o "${BUILD_DIR}" \
    2>&1 | tee "${BUILD_DIR}/compile.log"
COMPILE_END=$(date +%s%3N)
COMPILE_TIME=$((COMPILE_END - COMPILE_START))
echo "Compilation time: ${COMPILE_TIME}ms"

# Step 2: Get R1CS info (constraint count)
echo ""
echo "--- Step 2: R1CS Info ---"
npx snarkjs r1cs info "${BUILD_DIR}/${CIRCUIT_NAME}.r1cs" 2>&1 | tee "${BUILD_DIR}/r1cs_info.log"

# Extract constraint count
CONSTRAINTS=$(grep -oP 'Constraints: \K[0-9]+' "${BUILD_DIR}/r1cs_info.log" || echo "unknown")
echo "Constraint count: ${CONSTRAINTS}"

# Step 3: Generate input
echo ""
echo "--- Step 3: Generate input ---"
INPUT_PATH="${BUILD_DIR}/input.json"
node "${SCRIPT_DIR}/generate_input.js" "${DEPTH}" "${BATCH_SIZE}" "${INPUT_PATH}"

# Step 4: Generate witness
echo ""
echo "--- Step 4: Generate witness ---"
WITNESS_START=$(date +%s%3N)
node "${BUILD_DIR}/${CIRCUIT_NAME}_js/generate_witness.js" \
    "${BUILD_DIR}/${CIRCUIT_NAME}_js/${CIRCUIT_NAME}.wasm" \
    "${INPUT_PATH}" \
    "${BUILD_DIR}/witness.wtns"
WITNESS_END=$(date +%s%3N)
WITNESS_TIME=$((WITNESS_END - WITNESS_START))
echo "Witness generation time: ${WITNESS_TIME}ms"

# Step 5: Trusted setup (Powers of Tau + Groth16 setup)
echo ""
echo "--- Step 5: Trusted setup ---"

# Determine powers of tau size needed
# Need 2^n >= constraints. Calculate n.
if [ "$CONSTRAINTS" != "unknown" ]; then
    POT_POWER=$(python -c "import math; print(max(12, math.ceil(math.log2(${CONSTRAINTS}))))" 2>/dev/null || echo "16")
else
    POT_POWER=16
fi
echo "Powers of Tau power: ${POT_POWER} (2^${POT_POWER} = $(python -c "print(2**${POT_POWER})" 2>/dev/null || echo "N/A"))"

# Check if we already have a suitable ptau file in the circuits directory
PTAU_FILE="${CIRCUITS_DIR}/pot/pot${POT_POWER}_final.ptau"
if [ ! -f "${PTAU_FILE}" ]; then
    echo "Generating Powers of Tau (power ${POT_POWER})..."
    PTAU_FILE="${BUILD_DIR}/pot${POT_POWER}_final.ptau"
    SETUP_START=$(date +%s%3N)
    npx snarkjs powersoftau new bn128 ${POT_POWER} "${BUILD_DIR}/pot${POT_POWER}_0000.ptau" -v
    npx snarkjs powersoftau contribute "${BUILD_DIR}/pot${POT_POWER}_0000.ptau" "${BUILD_DIR}/pot${POT_POWER}_0001.ptau" --name="Benchmark contribution" -v -e="random entropy for benchmark"
    npx snarkjs powersoftau prepare phase2 "${BUILD_DIR}/pot${POT_POWER}_0001.ptau" "${PTAU_FILE}" -v
    rm -f "${BUILD_DIR}/pot${POT_POWER}_0000.ptau" "${BUILD_DIR}/pot${POT_POWER}_0001.ptau"
    SETUP_END=$(date +%s%3N)
    PTAU_TIME=$((SETUP_END - SETUP_START))
    echo "Powers of Tau generation time: ${PTAU_TIME}ms"
else
    echo "Using existing ptau file: ${PTAU_FILE}"
fi

# Groth16 setup
echo ""
echo "--- Step 5b: Groth16 key generation ---"
KEYGEN_START=$(date +%s%3N)
npx snarkjs groth16 setup "${BUILD_DIR}/${CIRCUIT_NAME}.r1cs" "${PTAU_FILE}" "${BUILD_DIR}/${CIRCUIT_NAME}_0000.zkey"
npx snarkjs zkey contribute "${BUILD_DIR}/${CIRCUIT_NAME}_0000.zkey" "${BUILD_DIR}/${CIRCUIT_NAME}_final.zkey" --name="Benchmark" -v -e="random entropy"
npx snarkjs zkey export verificationkey "${BUILD_DIR}/${CIRCUIT_NAME}_final.zkey" "${BUILD_DIR}/verification_key.json"
KEYGEN_END=$(date +%s%3N)
KEYGEN_TIME=$((KEYGEN_END - KEYGEN_START))
echo "Key generation time: ${KEYGEN_TIME}ms"

# Step 6: Generate proof
echo ""
echo "--- Step 6: Generate Groth16 proof ---"
PROVE_START=$(date +%s%3N)
npx snarkjs groth16 prove \
    "${BUILD_DIR}/${CIRCUIT_NAME}_final.zkey" \
    "${BUILD_DIR}/witness.wtns" \
    "${BUILD_DIR}/proof.json" \
    "${BUILD_DIR}/public.json"
PROVE_END=$(date +%s%3N)
PROVE_TIME=$((PROVE_END - PROVE_START))
echo "Proof generation time: ${PROVE_TIME}ms"

# Step 7: Verify proof
echo ""
echo "--- Step 7: Verify proof ---"
VERIFY_START=$(date +%s%3N)
npx snarkjs groth16 verify \
    "${BUILD_DIR}/verification_key.json" \
    "${BUILD_DIR}/public.json" \
    "${BUILD_DIR}/proof.json"
VERIFY_END=$(date +%s%3N)
VERIFY_TIME=$((VERIFY_END - VERIFY_START))
echo "Verification time: ${VERIFY_TIME}ms"

# Step 8: Compute proof size
PROOF_SIZE=$(wc -c < "${BUILD_DIR}/proof.json")
echo "Proof size: ${PROOF_SIZE} bytes"

# Summary
echo ""
echo "=== BENCHMARK RESULTS ==="
echo "Circuit:          ${CIRCUIT_NAME}"
echo "Tree Depth:       ${DEPTH}"
echo "Batch Size:       ${BATCH_SIZE}"
echo "Constraints:      ${CONSTRAINTS}"
echo "Compilation:      ${COMPILE_TIME}ms"
echo "Witness Gen:      ${WITNESS_TIME}ms"
echo "Key Gen:          ${KEYGEN_TIME}ms"
echo "Proving Time:     ${PROVE_TIME}ms"
echo "Verification:     ${VERIFY_TIME}ms"
echo "Proof Size:       ${PROOF_SIZE} bytes"

# Write results JSON
cat > "${RESULTS_DIR}/benchmark_d${DEPTH}_b${BATCH_SIZE}.json" << EOJSON
{
  "circuit": "${CIRCUIT_NAME}",
  "depth": ${DEPTH},
  "batchSize": ${BATCH_SIZE},
  "constraints": ${CONSTRAINTS:-0},
  "compilationTimeMs": ${COMPILE_TIME},
  "witnessGenTimeMs": ${WITNESS_TIME},
  "keyGenTimeMs": ${KEYGEN_TIME},
  "provingTimeMs": ${PROVE_TIME},
  "verificationTimeMs": ${VERIFY_TIME},
  "proofSizeBytes": ${PROOF_SIZE},
  "potPower": ${POT_POWER},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "platform": "$(uname -s) $(uname -m)",
  "nodeVersion": "$(node --version)",
  "circomVersion": "$(circom --version 2>&1 | head -1)",
  "snarkjsVersion": "0.7.6"
}
EOJSON

echo ""
echo "Results saved to: ${RESULTS_DIR}/benchmark_d${DEPTH}_b${BATCH_SIZE}.json"
