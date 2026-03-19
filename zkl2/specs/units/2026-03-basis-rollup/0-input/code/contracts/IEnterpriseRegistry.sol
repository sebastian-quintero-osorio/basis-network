// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title IEnterpriseRegistry
/// @notice Interface for enterprise authorization checks.
interface IEnterpriseRegistry {
    function isAuthorized(address enterprise) external view returns (bool);
}
