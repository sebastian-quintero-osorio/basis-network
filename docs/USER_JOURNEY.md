# User Journey

This document describes the end-to-end user journeys for Basis Network, from enterprise onboarding to ZK-verified operations.

---

## Journey 1: Enterprise Onboarding

### Actors
- **Network Admin** (Base Computing)
- **Enterprise** (new client)

### Steps

1. Enterprise contacts Base Computing and completes KYC/KYB verification.
2. Network Admin generates an Ethereum-compatible wallet for the enterprise.
3. Network Admin calls `EnterpriseRegistry.registerEnterprise()` with the enterprise address, name, and metadata.
4. Network Admin adds the enterprise address to the L1 transaction allowlist via the Subnet-EVM precompile.
5. Enterprise receives their wallet credentials and RPC endpoint.
6. Enterprise can now send zero-fee transactions to the network.
7. The registration event is visible on the network dashboard.

---

## Journey 2: PLASMA -- Maintenance Traceability

### Actors
- **Maintenance Technician** (at Ingenio Sancarlos)
- **PLASMA Platform** (web application)
- **Blockchain Adapter** (background service)
- **Basis Network L1** (blockchain)

### Steps

1. Maintenance Technician opens PLASMA and creates a new work order for equipment maintenance.
2. PLASMA backend processes the work order and saves it to the operational database.
3. The Blockchain Adapter detects the new work order event.
4. The Adapter calls `TraceabilityRegistry.recordEvent(ORDER_CREATED, equipmentId, encodedDetails)` with application-defined event data.
5. The transaction is submitted to Basis Network L1 at zero cost.
6. The transaction confirms with sub-second finality.
7. The maintenance event appears on the network dashboard.
8. When the technician completes the work order, the Adapter calls `TraceabilityRegistry.recordEvent(ORDER_COMPLETED, orderId, completionData)`.
9. The full maintenance timeline for any equipment is queryable on-chain via `getAssetHistory()`.

### Verification

At any time, an auditor can:
- Query the on-chain record and verify it matches the PLASMA database.
- Check timestamps to confirm when events were recorded.
- Verify that the recording enterprise is authorized via `EnterpriseRegistry.isAuthorized()`.

---

## Journey 3: Trace -- Commercial Traceability

### Actors
- **Business Owner** (SME using Trace)
- **Trace Platform** (ERP application)
- **Blockchain Adapter** (background service)
- **Basis Network L1** (blockchain)

### Steps

1. Business Owner records a sale in Trace (product, quantity, amount).
2. Trace backend processes the sale and updates inventory.
3. The Blockchain Adapter detects the sale event and the inventory movement.
4. The Adapter calls `TraceabilityRegistry.recordEvent(SALE_CREATED, productId, encodedSaleData)` and `TraceabilityRegistry.recordEvent(INVENTORY_MOVEMENT, productId, encodedMovementData)`.
5. Both transactions confirm on-chain at zero cost.
6. The sale and inventory movement appear on the network dashboard.
7. The complete history for any product is queryable via `getAssetHistory()`.
8. Events by type are queryable via `getEventsByType()`.

---

## Journey 4: ZK Validium Pipeline (End-to-End)

### Actors
- **Enterprise Application** (PLASMA, Trace, or any integrated system)
- **Validium Node** (enterprise-operated service)
- **Basis Network L1** (blockchain)
- **DAC Members** (Data Availability Committee)

### Steps

1. Enterprise application generates a business event (work order, sale, inspection, etc.).
2. Application submits the event to the Validium Node REST API (authenticated via Bearer token + API key).
3. The API validates the request and persists it to the **Write-Ahead Log** (WAL) with SHA-256 checksum.
4. The **Transaction Queue** orders events chronologically and deduplicates.
5. When the batch threshold is reached (by count or time), the **Batch Aggregator** forms a batch.
6. The **Sparse Merkle Tree** (Poseidon hash, BN128) is updated with each transaction in the batch.
7. The **Batch Builder** generates a Circom witness from the batch (previous state root, new state root, transaction data).
8. The **ZK Prover** generates a Groth16 proof attesting to batch validity (~12.9 seconds for batch of 8).
   - Public inputs: previous state root, new state root, batch number, enterprise ID.
   - Private inputs: individual transaction keys, values, and Merkle siblings (never revealed).
9. The **L1 Submitter** calls `StateCommitment.submitBatch()` on the Basis Network L1.
10. `StateCommitment.sol` delegates proof verification to `Groth16Verifier.sol` (~306K gas).
11. If the proof is valid, the enterprise's state root is updated on-chain.
12. The **DAC Protocol** distributes the batch data via Shamir (2,3) Secret Sharing to DAC members.
13. DAC members sign attestations confirming data availability.
14. Attestations are recorded on-chain via `DACAttestation.sol`.
15. The batch appears on the dashboard's Validium page with proof status and gas cost.

### Privacy Guarantee

At no point during this process does the L1 learn:
- What the transactions contained
- Who the counterparties were
- What amounts were involved
- What business operations occurred

The L1 only knows: "Enterprise X processed 8 valid transactions. Previous state root A, new state root B. Proof verified."

### Crash Recovery

If the node crashes at any point:
- Transactions in the WAL are recovered on restart (checksum-verified).
- The WAL checkpoint is deferred until after batch processing (not at formation), preventing silent data loss during the 12.9-second proving window.
- This crash-recovery guarantee was discovered by TLA+ model checking and proven in Coq.

---

## Journey 5: Cross-Enterprise Verification

### Actors
- **Enterprise A** (e.g., supplier)
- **Enterprise B** (e.g., buyer)
- **CrossEnterpriseVerifier Contract** (on-chain)

### Steps

1. Enterprise A processes a batch of transactions (e.g., shipment of goods).
2. Enterprise A's validium node includes a cross-reference commitment in the batch.
3. Enterprise B independently processes their corresponding transactions (e.g., receipt of goods).
4. Enterprise B's validium node includes a matching cross-reference commitment.
5. Either enterprise calls `CrossEnterpriseVerifier.verifyCrossReference()` with both commitments.
6. The contract verifies that both enterprises have valid, matching cross-references without accessing private data.
7. The verification result is recorded on-chain.
8. Both enterprises now have cryptographic proof of their interaction without revealing details to each other or the network.

### Privacy

- Enterprise A does not learn Enterprise B's internal transaction details.
- Enterprise B does not learn Enterprise A's internal transaction details.
- The L1 does not learn either enterprise's details.
- Only the existence and validity of the interaction is proven (1 bit of leakage: "an interaction occurred").

---

## Journey 6: Network Dashboard

### Actors
- **Judge / Auditor / Stakeholder** (external viewer)

### Steps

1. User opens the Basis Network dashboard ([dashboard.basisnetwork.com.co](https://dashboard.basisnetwork.com.co)).
2. Dashboard connects to the L1 RPC endpoint and polls every 10 seconds.
3. User navigates between pages:
   - **Overview** -- block height, gas price, enterprise count, ZK batch stats, recent blocks.
   - **Enterprises** -- registered enterprises, authorization status, registration dates.
   - **Activity** -- real-time event feed with type badges.
   - **Modules** -- 7 deployed protocol contracts with addresses and status.
   - **Validium** -- batch history, ZK circuit specifications, DAC status, state machine visualization.
4. User can verify on-chain data through the [block explorer](https://explorer.basisnetwork.com.co).
5. All data is queried directly from the blockchain -- no backend server, no intermediary.
