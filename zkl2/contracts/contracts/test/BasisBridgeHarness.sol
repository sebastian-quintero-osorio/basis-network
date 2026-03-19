// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "../BasisBridge.sol";

/// @title BasisBridgeHarness
/// @notice Test helper that overrides Merkle proof verification with a configurable mock.
/// @dev Allows testing all bridge business logic independently from Merkle tree correctness.
///      Same pattern as BasisRollupHarness for Groth16 verification.
contract BasisBridgeHarness is BasisBridge {
    bool private _mockProofValid = true;

    constructor(
        address _rollup,
        uint256 _escapeTimeout
    ) BasisBridge(_rollup, _escapeTimeout) {}

    /// @notice Configure the mock proof verification result.
    function setMockProofResult(bool valid) external {
        _mockProofValid = valid;
    }

    /// @dev Overrides Merkle proof verification with the mock result.
    function _verifyMerkleProof(
        bytes32[] calldata,
        bytes32,
        bytes32,
        uint256
    ) internal view override returns (bool) {
        return _mockProofValid;
    }
}
