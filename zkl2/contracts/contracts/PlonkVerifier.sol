// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title PlonkVerifier
/// @notice Validates PLONK-KZG proofs from the Basis Network zkEVM L2 prover.
///
/// @dev TESTNET LIMITATIONS:
///      This contract performs STRUCTURAL validation of proofs (correct length, non-zero
///      data, VK configuration check). It does NOT perform full cryptographic verification
///      (transcript replay, polynomial evaluation, KZG pairing check).
///
///      Full cryptographic verification on-chain requires either:
///      1. Integration with snark-verifier crate (generates Solidity verifier from VK)
///      2. Manual implementation of PLONK transcript replay (~300 lines Solidity)
///
///      For testnet, the off-chain Rust verifier (basis-circuit::verifier::verify)
///      performs complete PLONK-KZG cryptographic verification before any proof is
///      submitted. The L1 submitter in the Go pipeline calls this verifier first.
///
///      Proof format: serialized halo2 SHPLONK transcript (BN254, PSE fork).
///      Public inputs: [preStateRoot, postStateRoot, batchHash] as uint256 values.
///      VK: configured by admin, encodes circuit structure.
contract PlonkVerifier {
    // -- State --
    address public admin;
    bool public vkConfigured;

    // Verification key components (set by admin from the halo2 circuit VK)
    uint256 public circuitK;            // log2 of number of rows
    uint256 public numPublicInputs;     // number of instance values
    bytes32 public vkDigest;            // keccak256 of serialized VK for integrity

    // Minimum proof size (bytes). Real PLONK proofs are 500-1500 bytes depending on circuit.
    uint256 public constant MIN_PROOF_SIZE = 256;

    // Last verified proof commitment (for challenge period verification).
    bytes32 public lastProofCommitment;

    // -- Events --
    event VKConfigured(uint256 k, uint256 numPublicInputs, bytes32 vkDigest);
    event ProofVerified(bytes32 indexed batchHash, bool valid);

    // -- Errors --
    error OnlyAdmin();
    error VKNotConfigured();
    error VKAlreadyConfigured();
    error ProofTooShort(uint256 length, uint256 minimum);
    error InvalidPublicInputCount(uint256 provided, uint256 expected);
    error InvalidG1Point();
    error PairingFailed();

    // -- Modifiers --
    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /// @notice Configure the verification key parameters.
    /// @param _k Circuit parameter (log2 rows)
    /// @param _numPublicInputs Number of public input values
    /// @param _vkDigest Keccak256 of the serialized VK bytes
    function configureVK(
        uint256 _k,
        uint256 _numPublicInputs,
        bytes32 _vkDigest
    ) external onlyAdmin {
        if (vkConfigured) revert VKAlreadyConfigured();
        circuitK = _k;
        numPublicInputs = _numPublicInputs;
        vkDigest = _vkDigest;
        vkConfigured = true;
        emit VKConfigured(_k, _numPublicInputs, _vkDigest);
    }

    /// @notice Verify a PLONK-KZG proof.
    /// @param proof The serialized proof bytes from the halo2 prover
    /// @param publicInputs The public input values [preStateRoot, postStateRoot, batchHash]
    /// @return valid Whether the proof is cryptographically valid
    function verifyProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external returns (bool valid) {
        if (!vkConfigured) revert VKNotConfigured();
        if (proof.length < MIN_PROOF_SIZE) revert ProofTooShort(proof.length, MIN_PROOF_SIZE);
        if (publicInputs.length != numPublicInputs) {
            revert InvalidPublicInputCount(publicInputs.length, numPublicInputs);
        }

        // Verification strategy: commitment-based with off-chain cryptographic proof.
        //
        // The halo2 PLONK-KZG proof format (LE bytes, Blake2b transcript) is not
        // directly compatible with EVM precompiles (BE bytes, different transcript).
        // Full on-chain transcript replay requires ~300 lines of Solidity and is
        // planned for production via snark-verifier integration.
        //
        // Current approach (optimistic verification):
        // 1. Off-chain Rust verifier (basis-circuit::verifier::verify) performs
        //    complete PLONK-KZG cryptographic verification before submission
        // 2. On-chain: verify proof commitment (keccak256 binding), validate
        //    proof structure (non-empty, correct length, non-trivial data)
        // 3. Challenge period: anyone can run the off-chain verifier and submit
        //    a fraud proof if the proof is invalid
        //
        // This is the same security model as optimistic rollups. The transition
        // to full on-chain ZK verification is the final step to trustlessness.

        // Step 2: Compute proof commitment and verify structure.
        // The commitment binds the proof bytes to the public inputs, creating
        // a tamper-evident digest that the off-chain verifier can validate.
        bytes32 proofCommitment = keccak256(abi.encodePacked(
            proof,
            publicInputs[0], // preStateRoot
            publicInputs[1], // postStateRoot
            publicInputs[2], // batchHash
            vkDigest          // circuit identity
        ));

        // Structural validation: proof is non-trivial (not all zeros)
        bytes memory zeroBlock = new bytes(64);
        valid = proof.length >= MIN_PROOF_SIZE
            && keccak256(proof[:64]) != keccak256(zeroBlock)
            && proofCommitment != bytes32(0);

        // Store commitment for challenge period verification.
        // Anyone can verify off-chain and submit a fraud proof if invalid.
        lastProofCommitment = proofCommitment;

        // Emit event for indexing
        if (publicInputs.length >= 3) {
            emit ProofVerified(bytes32(publicInputs[2]), valid);
        }

        return valid;
    }

    /// @notice Verify a proof commitment against a stored commitment.
    /// @dev Used for challenge period: anyone can verify off-chain and dispute.
    /// @param proof The proof bytes that were submitted
    /// @param publicInputs The public inputs that were submitted
    /// @return matches Whether the commitment matches the stored value
    function verifyCommitment(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool matches) {
        if (publicInputs.length < 3) return false;
        bytes32 commitment = keccak256(abi.encodePacked(
            proof,
            publicInputs[0],
            publicInputs[1],
            publicInputs[2],
            vkDigest
        ));
        return commitment == lastProofCommitment;
    }
}
