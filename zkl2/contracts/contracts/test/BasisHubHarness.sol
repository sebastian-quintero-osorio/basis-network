// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "../BasisHub.sol";

/// @title BasisHubHarness
/// @notice Test helper that overrides Groth16 verification with a configurable mock.
/// @dev Allows testing all hub protocol logic independently from BN256 precompile behavior.
contract BasisHubHarness is BasisHub {
    bool private _mockProofValid = true;

    constructor(address _registry, uint256 _timeoutBlocks)
        BasisHub(_registry, _timeoutBlocks)
    {}

    /// @notice Configure the mock proof verification result.
    function setMockProofResult(bool valid) external {
        _mockProofValid = valid;
    }

    /// @dev Overrides Groth16 verification with the mock result.
    function _verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[] calldata
    ) internal view override returns (bool) {
        return _mockProofValid;
    }
}
