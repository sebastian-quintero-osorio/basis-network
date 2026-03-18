// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

/// @title EnterpriseRegistry
/// @notice Manages enterprise onboarding, metadata, and permissions on Basis Network.
/// @dev Only the network admin (Base Computing) can register or deactivate enterprises.
///      Enterprises can update their own metadata.
contract EnterpriseRegistry {
    struct Enterprise {
        string name;
        bytes metadata;
        bool active;
        uint256 registeredAt;
        uint256 updatedAt;
    }

    address public admin;
    mapping(address => Enterprise) private enterprises;
    address[] private enterpriseList;
    uint256 public enterpriseCount;

    event EnterpriseRegistered(
        address indexed enterprise,
        string name,
        uint256 timestamp
    );
    event EnterpriseUpdated(
        address indexed enterprise,
        uint256 timestamp
    );
    event EnterpriseDeactivated(
        address indexed enterprise,
        uint256 timestamp
    );
    event AdminTransferred(
        address indexed previousAdmin,
        address indexed newAdmin
    );

    error OnlyAdmin();
    error OnlyAuthorized();
    error AlreadyRegistered();
    error NotRegistered();
    error ZeroAddress();
    error EmptyName();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyAuthorizedEnterprise(address enterprise) {
        if (msg.sender != enterprise && msg.sender != admin) revert OnlyAuthorized();
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /// @notice Registers a new enterprise on the network.
    /// @param enterprise The wallet address of the enterprise.
    /// @param name The registered business name.
    /// @param metadata Encoded enterprise metadata (industry, jurisdiction, etc.).
    function registerEnterprise(
        address enterprise,
        string calldata name,
        bytes calldata metadata
    ) external onlyAdmin {
        if (enterprise == address(0)) revert ZeroAddress();
        if (bytes(name).length == 0) revert EmptyName();
        if (enterprises[enterprise].registeredAt != 0) revert AlreadyRegistered();

        enterprises[enterprise] = Enterprise({
            name: name,
            metadata: metadata,
            active: true,
            registeredAt: block.timestamp,
            updatedAt: block.timestamp
        });

        enterpriseList.push(enterprise);
        enterpriseCount++;

        emit EnterpriseRegistered(enterprise, name, block.timestamp);
    }

    /// @notice Updates the metadata of an enterprise.
    /// @param enterprise The address of the enterprise to update.
    /// @param metadata The new encoded metadata.
    function updateEnterprise(
        address enterprise,
        bytes calldata metadata
    ) external onlyAuthorizedEnterprise(enterprise) {
        if (enterprises[enterprise].registeredAt == 0) revert NotRegistered();

        enterprises[enterprise].metadata = metadata;
        enterprises[enterprise].updatedAt = block.timestamp;

        emit EnterpriseUpdated(enterprise, block.timestamp);
    }

    /// @notice Deactivates an enterprise, removing its ability to operate on the network.
    /// @param enterprise The address of the enterprise to deactivate.
    function deactivateEnterprise(address enterprise) external onlyAdmin {
        if (enterprises[enterprise].registeredAt == 0) revert NotRegistered();

        enterprises[enterprise].active = false;
        enterprises[enterprise].updatedAt = block.timestamp;

        emit EnterpriseDeactivated(enterprise, block.timestamp);
    }

    /// @notice Returns the details of a registered enterprise.
    /// @param enterprise The address to query.
    /// @return name The business name.
    /// @return metadata The encoded metadata.
    /// @return active Whether the enterprise is currently active.
    /// @return registeredAt The registration timestamp.
    /// @return updatedAt The last update timestamp.
    function getEnterprise(address enterprise)
        external
        view
        returns (
            string memory name,
            bytes memory metadata,
            bool active,
            uint256 registeredAt,
            uint256 updatedAt
        )
    {
        Enterprise storage e = enterprises[enterprise];
        return (e.name, e.metadata, e.active, e.registeredAt, e.updatedAt);
    }

    /// @notice Checks if an address belongs to a registered and active enterprise.
    /// @param enterprise The address to check.
    /// @return True if the address is an active enterprise.
    function isAuthorized(address enterprise) external view returns (bool) {
        return enterprises[enterprise].active;
    }

    /// @notice Returns all registered enterprise addresses.
    /// @return The array of enterprise addresses.
    function listEnterprises() external view returns (address[] memory) {
        return enterpriseList;
    }

    /// @notice Transfers admin rights to a new address.
    /// @param newAdmin The address of the new admin.
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }
}
