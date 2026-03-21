// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title MockBasisRollup
/// @notice Minimal mock of BasisRollup for testing BasisBridge in isolation.
/// @dev Implements the IBasisRollup interface as consumed by BasisBridge.
contract MockBasisRollup {
    struct MockState {
        bytes32 currentRoot;
        uint64 totalBatchesCommitted;
        uint64 totalBatchesProven;
        uint64 totalBatchesExecuted;
        bool initialized;
        uint64 lastL2Block;
    }

    mapping(address => MockState) private _states;

    function setEnterprise(
        address enterprise,
        bytes32 currentRoot,
        uint64 totalBatchesExecuted,
        uint64 lastL2Block
    ) external {
        _states[enterprise] = MockState({
            currentRoot: currentRoot,
            totalBatchesCommitted: totalBatchesExecuted,
            totalBatchesProven: totalBatchesExecuted,
            totalBatchesExecuted: totalBatchesExecuted,
            initialized: true,
            lastL2Block: lastL2Block
        });
    }

    function enterprises(address enterprise) external view returns (
        bytes32 currentRoot,
        uint64 totalBatchesCommitted,
        uint64 totalBatchesProven,
        uint64 totalBatchesExecuted,
        bool initialized,
        uint64 lastL2Block
    ) {
        MockState memory s = _states[enterprise];
        return (
            s.currentRoot,
            s.totalBatchesCommitted,
            s.totalBatchesProven,
            s.totalBatchesExecuted,
            s.initialized,
            s.lastL2Block
        );
    }

    function getCurrentRoot(address enterprise) external view returns (bytes32) {
        return _states[enterprise].currentRoot;
    }

    function getLastL2Block(address enterprise) external view returns (uint64) {
        return _states[enterprise].lastL2Block;
    }

    function isExecutedRoot(
        address enterprise,
        uint256,
        bytes32 root
    ) external view returns (bool) {
        return _states[enterprise].currentRoot == root;
    }
}
