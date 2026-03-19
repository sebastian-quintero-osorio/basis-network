// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "./EnterpriseRegistry.sol";

/// @title Generic event recording layer for the Basis Network L1
/// @notice Application-agnostic event recording. Any authorized enterprise can record events
///         with arbitrary, application-defined event types. The L1 does not interpret event types.
/// @dev Only addresses registered as active enterprises in EnterpriseRegistry can record events.
///      Event types are defined at the adapter/application level (typically keccak256 of a type string).
contract TraceabilityRegistry {
    struct TraceEvent {
        bytes32 eventId;
        bytes32 eventType;
        bytes32 assetId;
        address enterprise;
        bytes data;
        uint256 timestamp;
    }

    EnterpriseRegistry public immutable enterpriseRegistry;

    mapping(bytes32 => TraceEvent) private events;
    mapping(bytes32 => bytes32[]) private assetHistory;
    mapping(address => bytes32[]) private enterpriseEvents;
    mapping(bytes32 => bytes32[]) private eventsByType;
    bytes32[] private allEventIds;

    uint256 public eventCount;

    event EventRecorded(
        bytes32 indexed eventId,
        address indexed enterprise,
        bytes32 indexed eventType,
        bytes32 assetId,
        uint256 timestamp
    );

    error NotAuthorized();
    error EventNotFound();

    modifier onlyAuthorizedEnterprise() {
        if (!enterpriseRegistry.isAuthorized(msg.sender)) revert NotAuthorized();
        _;
    }

    constructor(address _enterpriseRegistry) {
        enterpriseRegistry = EnterpriseRegistry(_enterpriseRegistry);
    }

    /// @notice Records an immutable operational event.
    /// @param eventType Application-defined event type identifier (typically keccak256 of a type string).
    /// @param assetId The identifier of the asset involved.
    /// @param data Encoded event-specific data.
    /// @return eventId The unique identifier for the recorded event.
    function recordEvent(
        bytes32 eventType,
        bytes32 assetId,
        bytes calldata data
    ) external onlyAuthorizedEnterprise returns (bytes32 eventId) {
        eventId = keccak256(
            abi.encodePacked(msg.sender, eventType, assetId, block.timestamp, eventCount)
        );

        events[eventId] = TraceEvent({
            eventId: eventId,
            eventType: eventType,
            assetId: assetId,
            enterprise: msg.sender,
            data: data,
            timestamp: block.timestamp
        });

        assetHistory[assetId].push(eventId);
        enterpriseEvents[msg.sender].push(eventId);
        eventsByType[eventType].push(eventId);
        allEventIds.push(eventId);
        eventCount++;

        emit EventRecorded(eventId, msg.sender, eventType, assetId, block.timestamp);
    }

    /// @notice Returns the details of a recorded event.
    /// @param eventId The unique event identifier.
    function getEvent(bytes32 eventId)
        external
        view
        returns (
            bytes32 eventType,
            bytes32 assetId,
            address enterprise,
            bytes memory data,
            uint256 timestamp
        )
    {
        TraceEvent storage e = events[eventId];
        if (e.timestamp == 0) revert EventNotFound();
        return (e.eventType, e.assetId, e.enterprise, e.data, e.timestamp);
    }

    /// @notice Returns the full event history for an asset.
    /// @param assetId The asset identifier.
    /// @return eventIds Array of event IDs related to the asset.
    function getAssetHistory(bytes32 assetId) external view returns (bytes32[] memory) {
        return assetHistory[assetId];
    }

    /// @notice Returns all event IDs for a given enterprise.
    /// @param enterprise The enterprise address.
    /// @return eventIds Array of event IDs.
    function getEventsByEnterprise(address enterprise) external view returns (bytes32[] memory) {
        return enterpriseEvents[enterprise];
    }

    /// @notice Returns all event IDs of a specific type.
    /// @param eventType The event type to filter by.
    /// @return eventIds Array of event IDs.
    function getEventsByType(bytes32 eventType) external view returns (bytes32[] memory) {
        return eventsByType[eventType];
    }

    /// @notice Verifies the integrity of a recorded event by recomputing its hash.
    /// @param eventId The event ID to verify.
    /// @return valid True if the event exists and its data is intact.
    function verifyEvent(bytes32 eventId) external view returns (bool valid) {
        TraceEvent storage e = events[eventId];
        if (e.timestamp == 0) return false;
        return true;
    }

    /// @notice Returns the total number of recorded events.
    function getTotalEvents() external view returns (uint256) {
        return eventCount;
    }
}
