// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IEnterpriseRegistry
/// @notice Interface for enterprise authorization checks.
/// @dev Used by BasisRollup to gate sequencer/prover/executor access.
///      The full EnterpriseRegistry lives on the L1 (l1/contracts/contracts/core/).
///      This interface decouples the rollup contract from the registry implementation.
interface IEnterpriseRegistry {
    /// @notice Checks whether an address is authorized to interact with the rollup.
    /// @param enterprise The address to check.
    /// @return True if the address is an authorized enterprise.
    function isAuthorized(address enterprise) external view returns (bool);
}
