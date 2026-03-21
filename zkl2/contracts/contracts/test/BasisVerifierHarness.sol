// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "../BasisVerifier.sol";

/// @title BasisVerifierHarness
/// @notice Test helper that overrides cryptographic verification with configurable mocks.
/// @dev Allows testing all migration logic independently from BN256 precompile behavior.
///      The harness bypasses Groth16 and PLONK proof verification, returning configurable
///      results. This isolates the migration state machine tests from cryptographic concerns.
contract BasisVerifierHarness is BasisVerifier {
    bool private _mockGroth16Result = true;
    bool private _mockPlonkResult = true;

    constructor(uint256 _maxSteps) BasisVerifier(_maxSteps) {}

    /// @notice Configure mock Groth16 verification result.
    function setMockGroth16Result(bool valid) external {
        _mockGroth16Result = valid;
    }

    /// @notice Configure mock PLONK verification result.
    function setMockPlonkResult(bool valid) external {
        _mockPlonkResult = valid;
    }

    /// @dev Override Groth16 verification with mock.
    function _verifyGroth16(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[] calldata
    ) internal view override returns (bool) {
        return _mockGroth16Result;
    }

    /// @dev Override PLONK verification with mock.
    function _verifyPlonk(
        bytes calldata,
        uint256[] calldata
    ) internal view override returns (bool) {
        return _mockPlonkResult;
    }
}
