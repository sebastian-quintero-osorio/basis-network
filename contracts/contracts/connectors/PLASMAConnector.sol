// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "../core/EnterpriseRegistry.sol";
import "../core/TraceabilityRegistry.sol";

/// @title PLASMAConnector
/// @notice Bridge between the PLASMA industrial maintenance platform and Basis Network.
/// @dev Records maintenance work orders, completions, and equipment inspections on-chain.
contract PLASMAConnector {
    struct MaintenanceOrder {
        bytes32 orderId;
        bytes32 equipmentId;
        uint8 priority;
        address enterprise;
        bytes details;
        uint256 createdAt;
        uint256 completedAt;
        bool completed;
    }

    EnterpriseRegistry public immutable enterpriseRegistry;
    TraceabilityRegistry public immutable traceabilityRegistry;

    mapping(bytes32 => MaintenanceOrder) private orders;
    mapping(bytes32 => bytes32[]) private equipmentOrders;
    bytes32[] private openOrderIds;
    bytes32[] private allOrderIds;

    uint256 public totalOrders;
    uint256 public completedOrders;

    event MaintenanceOrderCreated(
        bytes32 indexed orderId,
        bytes32 indexed equipmentId,
        address indexed enterprise,
        uint8 priority,
        uint256 timestamp
    );
    event MaintenanceOrderCompleted(
        bytes32 indexed orderId,
        uint256 timestamp,
        uint256 duration
    );
    event EquipmentInspected(
        bytes32 indexed equipmentId,
        address indexed enterprise,
        uint256 timestamp
    );

    error NotAuthorized();
    error OrderAlreadyExists();
    error OrderNotFound();
    error OrderAlreadyCompleted();

    modifier onlyAuthorizedEnterprise() {
        if (!enterpriseRegistry.isAuthorized(msg.sender)) revert NotAuthorized();
        _;
    }

    constructor(address _enterpriseRegistry, address _traceabilityRegistry) {
        enterpriseRegistry = EnterpriseRegistry(_enterpriseRegistry);
        traceabilityRegistry = TraceabilityRegistry(_traceabilityRegistry);
    }

    /// @notice Records a new maintenance work order on-chain.
    /// @param orderId Unique identifier for the work order (from PLASMA).
    /// @param equipmentId Identifier of the equipment requiring maintenance.
    /// @param priority Priority level (1 = critical, 2 = high, 3 = medium, 4 = low).
    /// @param details Encoded work order details.
    function recordMaintenanceOrder(
        bytes32 orderId,
        bytes32 equipmentId,
        uint8 priority,
        bytes calldata details
    ) external onlyAuthorizedEnterprise {
        if (orders[orderId].createdAt != 0) revert OrderAlreadyExists();

        orders[orderId] = MaintenanceOrder({
            orderId: orderId,
            equipmentId: equipmentId,
            priority: priority,
            enterprise: msg.sender,
            details: details,
            createdAt: block.timestamp,
            completedAt: 0,
            completed: false
        });

        equipmentOrders[equipmentId].push(orderId);
        openOrderIds.push(orderId);
        allOrderIds.push(orderId);
        totalOrders++;

        traceabilityRegistry.recordEvent(
            traceabilityRegistry.MAINTENANCE_ORDER(),
            equipmentId,
            abi.encode(orderId, priority)
        );

        emit MaintenanceOrderCreated(orderId, equipmentId, msg.sender, priority, block.timestamp);
    }

    /// @notice Marks a maintenance work order as completed.
    /// @param orderId The work order to complete.
    /// @param completionData Encoded completion details (actions taken, parts used, etc.).
    function completeMaintenanceOrder(
        bytes32 orderId,
        bytes calldata completionData
    ) external onlyAuthorizedEnterprise {
        MaintenanceOrder storage order = orders[orderId];
        if (order.createdAt == 0) revert OrderNotFound();
        if (order.completed) revert OrderAlreadyCompleted();

        order.completed = true;
        order.completedAt = block.timestamp;
        order.details = completionData;
        completedOrders++;

        _removeFromOpenOrders(orderId);

        uint256 duration = block.timestamp - order.createdAt;
        emit MaintenanceOrderCompleted(orderId, block.timestamp, duration);
    }

    /// @notice Records an equipment inspection event.
    /// @param equipmentId The equipment that was inspected.
    /// @param inspectionData Encoded inspection results.
    function recordEquipmentInspection(
        bytes32 equipmentId,
        bytes calldata inspectionData
    ) external onlyAuthorizedEnterprise {
        traceabilityRegistry.recordEvent(
            traceabilityRegistry.EQUIPMENT_INSPECTION(),
            equipmentId,
            inspectionData
        );

        emit EquipmentInspected(equipmentId, msg.sender, block.timestamp);
    }

    /// @notice Returns the full maintenance history for a piece of equipment.
    /// @param equipmentId The equipment identifier.
    /// @return orderIds Array of maintenance order IDs.
    function getMaintenanceHistory(bytes32 equipmentId) external view returns (bytes32[] memory) {
        return equipmentOrders[equipmentId];
    }

    /// @notice Returns all currently open (uncompleted) work orders.
    /// @return orderIds Array of open order IDs.
    function getOpenOrders() external view returns (bytes32[] memory) {
        return openOrderIds;
    }

    /// @notice Returns the details of a specific maintenance order.
    /// @param orderId The order to query.
    function getOrder(bytes32 orderId)
        external
        view
        returns (
            bytes32 equipmentId,
            uint8 priority,
            address enterprise,
            bytes memory details,
            uint256 createdAt,
            uint256 completedAt,
            bool completed
        )
    {
        MaintenanceOrder storage o = orders[orderId];
        if (o.createdAt == 0) revert OrderNotFound();
        return (o.equipmentId, o.priority, o.enterprise, o.details, o.createdAt, o.completedAt, o.completed);
    }

    /// @notice Calculates the completion rate for maintenance orders in a time period.
    /// @param fromTimestamp Start of the period.
    /// @param toTimestamp End of the period.
    /// @return completed Number of completed orders in the period.
    /// @return total Total orders created in the period.
    function getCompletionRate(uint256 fromTimestamp, uint256 toTimestamp)
        external
        view
        returns (uint256 completed, uint256 total)
    {
        for (uint256 i = 0; i < allOrderIds.length; i++) {
            MaintenanceOrder storage o = orders[allOrderIds[i]];
            if (o.createdAt >= fromTimestamp && o.createdAt <= toTimestamp) {
                total++;
                if (o.completed) {
                    completed++;
                }
            }
        }
    }

    function _removeFromOpenOrders(bytes32 orderId) private {
        for (uint256 i = 0; i < openOrderIds.length; i++) {
            if (openOrderIds[i] == orderId) {
                openOrderIds[i] = openOrderIds[openOrderIds.length - 1];
                openOrderIds.pop();
                break;
            }
        }
    }
}
