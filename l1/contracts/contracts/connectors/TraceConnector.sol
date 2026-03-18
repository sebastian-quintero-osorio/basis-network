// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "../core/EnterpriseRegistry.sol";
import "../core/TraceabilityRegistry.sol";

/// @title TraceConnector
/// @notice Bridge between the Trace ERP platform and Basis Network.
/// @dev Records sales, inventory movements, and supplier transactions on-chain.
contract TraceConnector {
    struct Sale {
        bytes32 saleId;
        bytes32 productId;
        uint256 quantity;
        uint256 amount;
        address enterprise;
        uint256 timestamp;
    }

    struct InventoryMovement {
        bytes32 productId;
        int256 quantityChange;
        bytes32 reason;
        address enterprise;
        uint256 timestamp;
    }

    EnterpriseRegistry public immutable enterpriseRegistry;
    TraceabilityRegistry public immutable traceabilityRegistry;

    mapping(bytes32 => Sale) private sales;
    mapping(bytes32 => bytes32[]) private productSales;
    mapping(bytes32 => InventoryMovement[]) private inventoryLedger;
    mapping(bytes32 => bytes32[]) private supplierHistory;

    uint256 public totalSales;
    uint256 public totalInventoryMovements;
    uint256 public totalSupplierTransactions;

    event SaleRecorded(
        bytes32 indexed saleId,
        bytes32 indexed productId,
        address indexed enterprise,
        uint256 amount,
        uint256 timestamp
    );
    event InventoryMoved(
        bytes32 indexed productId,
        address indexed enterprise,
        int256 change,
        uint256 timestamp
    );
    event SupplierTransactionRecorded(
        bytes32 indexed supplierId,
        bytes32 indexed productId,
        address indexed enterprise,
        uint256 quantity,
        uint256 timestamp
    );

    error NotAuthorized();
    error SaleAlreadyExists();
    error SaleNotFound();

    modifier onlyAuthorizedEnterprise() {
        if (!enterpriseRegistry.isAuthorized(msg.sender)) revert NotAuthorized();
        _;
    }

    constructor(address _enterpriseRegistry, address _traceabilityRegistry) {
        enterpriseRegistry = EnterpriseRegistry(_enterpriseRegistry);
        traceabilityRegistry = TraceabilityRegistry(_traceabilityRegistry);
    }

    /// @notice Records a sale transaction on-chain.
    /// @param saleId Unique sale identifier from Trace.
    /// @param productId The product sold.
    /// @param quantity Number of units sold.
    /// @param amount Total sale amount (in smallest currency unit).
    function recordSale(
        bytes32 saleId,
        bytes32 productId,
        uint256 quantity,
        uint256 amount
    ) external onlyAuthorizedEnterprise {
        if (sales[saleId].timestamp != 0) revert SaleAlreadyExists();

        sales[saleId] = Sale({
            saleId: saleId,
            productId: productId,
            quantity: quantity,
            amount: amount,
            enterprise: msg.sender,
            timestamp: block.timestamp
        });

        productSales[productId].push(saleId);
        totalSales++;

        traceabilityRegistry.recordEvent(
            traceabilityRegistry.SALE(),
            productId,
            abi.encode(saleId, quantity, amount)
        );

        emit SaleRecorded(saleId, productId, msg.sender, amount, block.timestamp);
    }

    /// @notice Records an inventory movement (stock in or out).
    /// @param productId The product affected.
    /// @param quantityChange Positive for stock in, negative for stock out.
    /// @param reason Encoded reason for the movement.
    function recordInventoryMovement(
        bytes32 productId,
        int256 quantityChange,
        bytes32 reason
    ) external onlyAuthorizedEnterprise {
        inventoryLedger[productId].push(InventoryMovement({
            productId: productId,
            quantityChange: quantityChange,
            reason: reason,
            enterprise: msg.sender,
            timestamp: block.timestamp
        }));

        totalInventoryMovements++;

        traceabilityRegistry.recordEvent(
            traceabilityRegistry.INVENTORY_MOVEMENT(),
            productId,
            abi.encode(quantityChange, reason)
        );

        emit InventoryMoved(productId, msg.sender, quantityChange, block.timestamp);
    }

    /// @notice Records a supplier transaction.
    /// @param supplierId The supplier identifier.
    /// @param productId The product received.
    /// @param quantity Number of units received.
    function recordSupplierTransaction(
        bytes32 supplierId,
        bytes32 productId,
        uint256 quantity
    ) external onlyAuthorizedEnterprise {
        supplierHistory[supplierId].push(
            keccak256(abi.encodePacked(supplierId, productId, quantity, block.timestamp))
        );
        totalSupplierTransactions++;

        traceabilityRegistry.recordEvent(
            traceabilityRegistry.SUPPLY_CHAIN_CHECKPOINT(),
            productId,
            abi.encode(supplierId, quantity)
        );

        emit SupplierTransactionRecorded(supplierId, productId, msg.sender, quantity, block.timestamp);
    }

    /// @notice Returns the sale history for a product.
    /// @param productId The product to query.
    /// @return saleIds Array of sale IDs for the product.
    function getSaleHistory(bytes32 productId) external view returns (bytes32[] memory) {
        return productSales[productId];
    }

    /// @notice Returns the details of a specific sale.
    /// @param saleId The sale to query.
    function getSale(bytes32 saleId)
        external
        view
        returns (
            bytes32 productId,
            uint256 quantity,
            uint256 amount,
            address enterprise,
            uint256 timestamp
        )
    {
        Sale storage s = sales[saleId];
        if (s.timestamp == 0) revert SaleNotFound();
        return (s.productId, s.quantity, s.amount, s.enterprise, s.timestamp);
    }

    /// @notice Returns the complete inventory movement history for a product.
    /// @param productId The product to query.
    /// @return movements Array of inventory movements.
    function getInventoryLedger(bytes32 productId)
        external
        view
        returns (InventoryMovement[] memory)
    {
        return inventoryLedger[productId];
    }

    /// @notice Returns all transaction hashes with a supplier.
    /// @param supplierId The supplier to query.
    /// @return txHashes Array of transaction hashes.
    function getSupplierHistory(bytes32 supplierId) external view returns (bytes32[] memory) {
        return supplierHistory[supplierId];
    }
}
