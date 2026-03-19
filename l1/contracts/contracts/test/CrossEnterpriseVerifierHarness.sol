// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "../verification/CrossEnterpriseVerifier.sol";

contract CrossEnterpriseVerifierHarness is CrossEnterpriseVerifier {
    bool private _mockProofValid = true;

    constructor(
        address _stateCommitment,
        address _enterpriseRegistry
    ) CrossEnterpriseVerifier(_stateCommitment, _enterpriseRegistry) {}

    function setMockProofResult(bool valid) external {
        _mockProofValid = valid;
    }

    function _verifyProof(
        uint256[2] calldata,
        uint256[2][2] calldata,
        uint256[2] calldata,
        uint256[] memory
    ) internal view override returns (bool) {
        return _mockProofValid;
    }
}
