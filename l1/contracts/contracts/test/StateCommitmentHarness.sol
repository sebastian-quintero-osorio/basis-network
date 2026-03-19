// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "../core/StateCommitment.sol";

/// @title MockGroth16Verifier
/// @notice Mock verifier for testing. Returns a configurable result.
contract MockGroth16Verifier is IGroth16Verifier {
    bool public mockResult = true;

    function setResult(bool _result) external {
        mockResult = _result;
    }

    function verifyProof(
        uint[2] calldata,
        uint[2][2] calldata,
        uint[2] calldata,
        uint[4] calldata
    ) external view override returns (bool) {
        return mockResult;
    }
}
