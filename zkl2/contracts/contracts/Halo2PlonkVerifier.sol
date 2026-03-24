// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IHalo2Verifier
/// @notice Interface for the generated Halo2 verifier contract.
interface IHalo2Verifier {
    function verifyProof(
        address vk,
        bytes calldata proof,
        uint256[] calldata instances
    ) external view returns (bool);
}

/// @title Halo2PlonkVerifier
/// @notice Wrapper that adapts the generated Halo2 verifier to the IPlonkVerifier
///         interface expected by BasisRollupV2.
///
/// @dev The generated Halo2Verifier requires (vk_address, proof, instances).
///      BasisRollupV2 calls verifyProof(proof, publicInputs) with 2 params.
///      This wrapper bridges the two by storing the VK contract address.
contract Halo2PlonkVerifier {
    address public admin;
    address public halo2Verifier;
    address public halo2Vk;
    bool public configured;

    event Configured(address indexed verifier, address indexed vk);

    error OnlyAdmin();
    error NotConfigured();
    error AlreadyConfigured();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /// @notice Configure the Halo2 verifier and VK contract addresses.
    function configure(address _verifier, address _vk) external onlyAdmin {
        if (configured) revert AlreadyConfigured();
        halo2Verifier = _verifier;
        halo2Vk = _vk;
        configured = true;
        emit Configured(_verifier, _vk);
    }

    /// @notice Verify a PLONK-KZG proof using the generated Halo2 verifier.
    /// @dev Matches the IPlonkVerifier interface: verifyProof(bytes, uint256[])
    function verifyProof(
        bytes calldata proof,
        uint256[] calldata publicInputs
    ) external view returns (bool valid) {
        if (!configured) revert NotConfigured();
        return IHalo2Verifier(halo2Verifier).verifyProof(halo2Vk, proof, publicInputs);
    }
}
