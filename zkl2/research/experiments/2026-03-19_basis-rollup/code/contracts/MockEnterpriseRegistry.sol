// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "./IEnterpriseRegistry.sol";

/// @title MockEnterpriseRegistry
/// @notice Minimal mock for testing BasisRollup without full EnterpriseRegistry.
contract MockEnterpriseRegistry is IEnterpriseRegistry {
    mapping(address => bool) private _authorized;

    function setAuthorized(address enterprise, bool authorized) external {
        _authorized[enterprise] = authorized;
    }

    function isAuthorized(address enterprise) external view override returns (bool) {
        return _authorized[enterprise];
    }
}
