// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "../verification/CrossEnterpriseVerifier.sol";

/// @title CrossEnterpriseVerifierHarness
/// @notice Test helper that overrides Groth16 verification with a configurable mock.
/// @dev Allows testing all business logic (consistency gates, isolation, authorization)
///      independently from BN256 precompile behavior.
contract CrossEnterpriseVerifierHarness is CrossEnterpriseVerifier {
    bool private _mockProofValid = true;

    constructor(
        address _stateCommitment,
        address _enterpriseRegistry
    ) CrossEnterpriseVerifier(_stateCommitment, _enterpriseRegistry) {}

    /// @notice Configure the mock proof verification result.
    /// @param valid If true, all proofs pass. If false, all proofs fail.
    function setMockProofResult(bool valid) external {
        _mockProofValid = valid;
    }

    /// @dev Overrides Groth16 verification with the mock result.
    function _verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[] memory
    ) internal view override returns (bool) {
        return _mockProofValid;
    }
}
