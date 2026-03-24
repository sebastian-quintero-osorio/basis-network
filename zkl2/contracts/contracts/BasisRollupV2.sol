// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "./BasisRollup.sol";

/// @title IPlonkVerifier
/// @notice Interface for the PlonkVerifier contract.
interface IPlonkVerifier {
    function verifyProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external returns (bool valid);
}

/// @title BasisRollupV2
/// @notice Extension of BasisRollup that uses PlonkVerifier for PLONK-KZG proof verification
///         instead of the inline Groth16 pairing check.
///
/// @dev This contract:
///      1. Inherits ALL business logic from BasisRollup (commit, execute, revert, etc.)
///      2. Adds a new `proveBatchV2` that accepts raw proof bytes + public inputs
///      3. Calls PlonkVerifier.verifyProof() for real commitment-based verification
///      4. Keeps the Groth16 `proveBatch` for backward compatibility during migration
///
///      The PlonkVerifier performs structural validation and commitment binding:
///      - Proof length >= 256 bytes
///      - Non-zero proof data
///      - keccak256(proof || publicInputs || vkDigest) commitment stored on-chain
///      - Challenge period: anyone can verify off-chain and dispute
contract BasisRollupV2 is BasisRollup {
    /// @notice Address of the PlonkVerifier contract.
    address public plonkVerifier;

    /// @notice Whether the PLONK verifier has been configured.
    bool public plonkVerifierSet;

    error PlonkVerifierNotSet();
    error PlonkVerificationFailed();

    event PlonkVerifierUpdated(address indexed verifier);

    constructor(address _enterpriseRegistry) BasisRollup(_enterpriseRegistry) {}

    /// @notice Set the PlonkVerifier contract address. Only callable by admin.
    /// @param _verifier Address of the deployed PlonkVerifier contract.
    function setPlonkVerifier(address _verifier) external onlyAdmin {
        require(_verifier != address(0), "zero address");
        plonkVerifier = _verifier;
        plonkVerifierSet = true;
        emit PlonkVerifierUpdated(_verifier);
    }

    /// @notice Prove a batch using PLONK-KZG proof via PlonkVerifier.
    /// @dev This is the V2 proof submission path. Accepts raw proof bytes
    ///      instead of Groth16 (a, b, c) points. The PlonkVerifier performs
    ///      commitment-based structural validation.
    /// @param batchId The batch to prove (must be next sequential unproven batch).
    /// @param proof Raw PLONK-KZG proof bytes from the Rust prover.
    /// @param publicInputs Public inputs [preStateRoot, postStateRoot, batchHash].
    function proveBatchV2(
        uint256 batchId,
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external {
        if (!plonkVerifierSet) revert PlonkVerifierNotSet();
        if (!enterpriseRegistry.isAuthorized(msg.sender)) revert NotAuthorized();

        EnterpriseState storage es = enterprises[msg.sender];
        if (!es.initialized) revert EnterpriseNotInitialized();

        // INV-06 CommitBeforeProve + sequential proving
        if (batchId != es.totalBatchesProven) revert BatchNotNextToProve();

        StoredBatchInfo storage batch = storedBatches[msg.sender][batchId];
        if (batch.status != BatchStatus.Committed) revert BatchNotCommitted();

        // INV-S2: verify proof BEFORE state change
        bool valid = IPlonkVerifier(plonkVerifier).verifyProof(proof, publicInputs);
        if (!valid) revert PlonkVerificationFailed();

        // Transition: Committed -> Proven
        batch.status = BatchStatus.Proven;
        es.totalBatchesProven = uint64(batchId + 1);
        totalBatchesProven++;

        emit BatchProven(msg.sender, batchId, block.timestamp);
    }
}
