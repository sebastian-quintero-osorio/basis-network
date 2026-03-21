// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "../BasisAggregator.sol";

/// @title BasisAggregatorHarness
/// @notice Test harness that overrides Groth16 verification to allow deterministic testing.
/// @dev The actual BN254 pairing precompile calls are expensive and require valid proofs.
///      This harness replaces _verifyGroth16 with a mock that accepts or rejects based on
///      a configurable flag, enabling focused testing of aggregation logic, gas accounting,
///      and lifecycle management without requiring real ZK proofs.
///
///      Pattern matches BasisVerifierHarness and BasisRollupHarness in the test suite.
contract BasisAggregatorHarness is BasisAggregator {
    /// @dev When true, all Groth16 verifications succeed.
    bool public mockVerificationResult;

    constructor(address _admin) BasisAggregator(_admin) {
        mockVerificationResult = true;
    }

    /// @notice Set the mock verification result for testing.
    /// @param result If true, all verifications pass. If false, all fail.
    function setMockVerificationResult(bool result) external {
        mockVerificationResult = result;
    }

    /// @dev Override Groth16 verification with mock.
    function _verifyGroth16(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[] calldata
    ) internal view override returns (bool) {
        return mockVerificationResult;
    }

    /// @notice Bypass the verifying key requirement for testing.
    function setVerifyingKeyForTest() external {
        verifyingKeySet = true;
    }
}
