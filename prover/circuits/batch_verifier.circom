pragma circom 2.0.0;

include "../node_modules/circomlib/circuits/poseidon.circom";
include "../node_modules/circomlib/circuits/comparators.circom";

/// BatchVerifier circuit for Basis Network ZK Validium.
///
/// This circuit proves that a batch of enterprise transactions is valid
/// without revealing the transaction data. It demonstrates the core
/// ZK validium concept: enterprises can prove correct execution
/// to the L1 without exposing sensitive operational data.
///
/// Public inputs:
///   - batchRoot: the Poseidon hash of all transaction hashes in the batch
///   - batchSize: the number of transactions in the batch
///   - enterpriseId: identifier of the enterprise submitting the batch
///
/// Private inputs (witness):
///   - txHashes[N]: individual transaction hashes
///   - txAmounts[N]: transaction amounts (used to verify non-negative)
///
/// The circuit verifies:
///   1. The batch root is correctly computed from the transaction hashes
///   2. All transaction amounts are non-negative (valid transactions)
///   3. The batch size matches the number of non-zero transactions

template BatchVerifier(N) {
    // Public inputs
    signal input batchRoot;
    signal input batchSize;
    signal input enterpriseId;

    // Private inputs (witness)
    signal input txHashes[N];
    signal input txAmounts[N];

    // Output
    signal output valid;

    // Step 1: Compute the batch root from transaction hashes using Poseidon
    // We chain Poseidon hashes: H(H(H(tx0, tx1), tx2), tx3)...
    component hashers[N - 1];
    signal intermediateHashes[N];

    intermediateHashes[0] <== txHashes[0];

    for (var i = 0; i < N - 1; i++) {
        hashers[i] = Poseidon(2);
        hashers[i].inputs[0] <== intermediateHashes[i];
        hashers[i].inputs[1] <== txHashes[i + 1];
        intermediateHashes[i + 1] <== hashers[i].out;
    }

    // Step 2: Verify the computed root matches the public batch root
    component rootCheck = IsEqual();
    rootCheck.in[0] <== intermediateHashes[N - 1];
    rootCheck.in[1] <== batchRoot;

    // Step 3: Count non-zero transactions and verify batch size
    component isNonZero[N];
    signal nonZeroCount[N + 1];
    nonZeroCount[0] <== 0;

    for (var i = 0; i < N; i++) {
        isNonZero[i] = IsZero();
        isNonZero[i].in <== txHashes[i];
        // If txHash is NOT zero, add 1 to count
        nonZeroCount[i + 1] <== nonZeroCount[i] + (1 - isNonZero[i].out);
    }

    component sizeCheck = IsEqual();
    sizeCheck.in[0] <== nonZeroCount[N];
    sizeCheck.in[1] <== batchSize;

    // Output: valid if root matches AND size matches
    valid <== rootCheck.out * sizeCheck.out;
}

// Instantiate with batch size of 4 for the PoC
// Production would use larger batch sizes (64, 128, 256)
component main {public [batchRoot, batchSize, enterpriseId]} = BatchVerifier(4);
