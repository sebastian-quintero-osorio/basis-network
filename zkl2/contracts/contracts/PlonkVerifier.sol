// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/// @title PlonkVerifier
/// @notice Validates PLONK-KZG proofs from the Basis Network zkEVM L2 prover.
/// @dev Implements KZG opening verification using BN254 pairing precompiles (EIP-196/197).
///
///      KZG opening verification:
///        e(-W, [s]_2) * e(C + z*W, -[1]_2) == 1
///      where W = opening proof, [s]_2 = SRS G2, C = commitment, z = challenge.
///
///      Proof format (calldata):
///        [0:32]   W.x      [32:64]  W.y      (G1: opening proof)
///        [64:96]  E.x      [96:128] E.y      (G1: evaluation proof)
///        [128:160] z                          (Fr: Fiat-Shamir challenge)
///        [160:192] C.x     [192:224] C.y     (G1: linearized commitment)
contract PlonkVerifier {
    // BN254 base field prime
    uint256 internal constant BN254_P = 21888242871839275222246405745257275088696311157297823662689037894645226208583;

    address public admin;
    bool public vkConfigured;

    // KZG SRS G2 point [s]_2: stored as [x_c0, x_c1, y_c0, y_c1]
    uint256[4] internal srsG2;
    // Negative G2 generator: stored as [x_c0, x_c1, y_c0, y_c1]
    uint256[4] internal negG2;

    uint256 public circuitK;
    uint256 public numPublicInputs;
    bytes32 public vkDigest;

    uint256 public constant MIN_PROOF_SIZE = 224;
    bytes32 public lastProofCommitment;

    event VKConfigured(uint256 k, uint256 numPublicInputs, bytes32 vkDigest);
    event ProofVerified(bytes32 indexed batchHash, bool valid);

    error OnlyAdmin();
    error VKNotConfigured();
    error VKAlreadyConfigured();
    error ProofTooShort(uint256 length, uint256 minimum);
    error InvalidPublicInputCount(uint256 provided, uint256 expected);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /// @notice Configure the verification key with KZG parameters.
    /// @param _srsG2 SRS G2 point [s]_2 as [x_c0, x_c1, y_c0, y_c1]
    /// @param _negG2 Negative G2 generator as [x_c0, x_c1, y_c0, y_c1]
    /// @param _k Circuit parameter (log2 rows)
    /// @param _numPublicInputs Number of public input values
    /// @param _vkDigest Keccak256 of the serialized VK bytes
    function configureVK(
        uint256[4] calldata _srsG2,
        uint256[4] calldata _negG2,
        uint256 _k,
        uint256 _numPublicInputs,
        bytes32 _vkDigest
    ) external onlyAdmin {
        if (vkConfigured) revert VKAlreadyConfigured();
        srsG2 = _srsG2;
        negG2 = _negG2;
        circuitK = _k;
        numPublicInputs = _numPublicInputs;
        vkDigest = _vkDigest;
        vkConfigured = true;
        emit VKConfigured(_k, _numPublicInputs, _vkDigest);
    }

    /// @notice Verify a PLONK-KZG proof using BN254 pairing check.
    /// @param proof Serialized proof: [W(64), E(64), z(32), C(64)]
    /// @param publicInputs Public inputs [preStateRoot, postStateRoot, batchHash]
    /// @return valid Whether the proof passes KZG pairing verification
    function verifyProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external returns (bool valid) {
        if (!vkConfigured) revert VKNotConfigured();
        if (proof.length < MIN_PROOF_SIZE) revert ProofTooShort(proof.length, MIN_PROOF_SIZE);
        if (publicInputs.length != numPublicInputs) {
            revert InvalidPublicInputCount(publicInputs.length, numPublicInputs);
        }

        valid = _kzgPairingCheck(proof);

        // Store commitment for challenge period verification.
        lastProofCommitment = keccak256(abi.encodePacked(
            proof, publicInputs[0], publicInputs[1], publicInputs[2], vkDigest
        ));

        if (publicInputs.length >= 3) {
            emit ProofVerified(bytes32(publicInputs[2]), valid);
        }
    }

    /// @dev Core KZG pairing check using EIP-196/197 precompiles.
    ///      Verifies: e(-W, [s]_2) * e(C + z*W, -[1]_2) == 1
    function _kzgPairingCheck(bytes calldata proof) internal view returns (bool) {
        // Use a large memory buffer for all operations.
        // Layout:
        //   0x00-0x40: scratch for ecMul input (W.x, W.y, z) -> result (zW.x, zW.y)
        //   0x60-0xC0: scratch for ecAdd input (C.x, C.y, zW.x, zW.y) -> result (lhs.x, lhs.y)
        //   0x00-0x180: pairing input (2 pairs x 6 uint256)
        bool success;
        uint256 result;

        assembly {
            let ptr := mload(0x40)

            // Parse proof elements from calldata
            let off := proof.offset
            let wX := calldataload(off)
            let wY := calldataload(add(off, 0x20))
            // Skip E (eval proof) at offset 0x40-0x80 for KZG check
            let z  := calldataload(add(off, 0x80))
            let cX := calldataload(add(off, 0xA0))
            let cY := calldataload(add(off, 0xC0))

            // ecMul: z * W
            mstore(ptr, wX)
            mstore(add(ptr, 0x20), wY)
            mstore(add(ptr, 0x40), z)
            if iszero(staticcall(gas(), 0x07, ptr, 0x60, ptr, 0x40)) {
                // ecMul failed
                mstore(0x00, 0)
                return(0x00, 0x20)
            }
            let zwX := mload(ptr)
            let zwY := mload(add(ptr, 0x20))

            // ecAdd: C + z*W = lhs
            mstore(ptr, cX)
            mstore(add(ptr, 0x20), cY)
            mstore(add(ptr, 0x40), zwX)
            mstore(add(ptr, 0x60), zwY)
            if iszero(staticcall(gas(), 0x06, ptr, 0x80, ptr, 0x40)) {
                mstore(0x00, 0)
                return(0x00, 0x20)
            }
            let lhsX := mload(ptr)
            let lhsY := mload(add(ptr, 0x20))

            // Negate W: -W.y = BN254_P - W.y (mod BN254_P)
            let negWY := wY
            if wY {
                negWY := sub(BN254_P, mod(wY, BN254_P))
            }

            // Negate lhs: -lhs.y = BN254_P - lhs.y
            let negLhsY := lhsY
            if lhsY {
                negLhsY := sub(BN254_P, mod(lhsY, BN254_P))
            }

            // Build pairing input (2 pairs x 6 uint256 = 12 words = 0x180 bytes)
            // EIP-197 per pair: [G1.x, G1.y, G2.x_im, G2.x_re, G2.y_im, G2.y_re]

            // Pair 1: -W paired with srsG2 ([s]_2)
            mstore(ptr, wX)
            mstore(add(ptr, 0x20), negWY)
            // Load srsG2 from storage (slot for srsG2[0..3])
            mstore(add(ptr, 0x40), sload(srsG2.slot))          // x_c0
            mstore(add(ptr, 0x60), sload(add(srsG2.slot, 1)))  // x_c1
            mstore(add(ptr, 0x80), sload(add(srsG2.slot, 2)))  // y_c0
            mstore(add(ptr, 0xA0), sload(add(srsG2.slot, 3)))  // y_c1

            // Pair 2: -lhs paired with negG2 (-[1]_2)
            mstore(add(ptr, 0xC0), lhsX)
            mstore(add(ptr, 0xE0), negLhsY)
            mstore(add(ptr, 0x100), sload(negG2.slot))          // x_c0
            mstore(add(ptr, 0x120), sload(add(negG2.slot, 1)))  // x_c1
            mstore(add(ptr, 0x140), sload(add(negG2.slot, 2)))  // y_c0
            mstore(add(ptr, 0x160), sload(add(negG2.slot, 3)))  // y_c1

            // Call pairing precompile 0x08
            success := staticcall(gas(), 0x08, ptr, 0x180, ptr, 0x20)
            result := mload(ptr)
        }

        if (!success) return false;
        return result == 1;
    }

    /// @notice Verify a proof commitment against a stored commitment.
    function verifyCommitment(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool matches) {
        if (publicInputs.length < 3) return false;
        bytes32 commitment = keccak256(abi.encodePacked(
            proof, publicInputs[0], publicInputs[1], publicInputs[2], vkDigest
        ));
        return commitment == lastProofCommitment;
    }
}
