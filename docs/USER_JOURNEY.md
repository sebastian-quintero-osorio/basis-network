# User Journey

This document describes the end-to-end user journey for Basis Network, from enterprise onboarding to on-chain verification.

---

## Journey 1: Enterprise Onboarding

### Actors
- **Network Admin** (Base Computing)
- **Enterprise** (new client)

### Steps

1. Enterprise contacts Base Computing and completes KYC/KYB verification.
2. Network Admin generates an Ethereum-compatible wallet for the enterprise.
3. Network Admin calls `EnterpriseRegistry.registerEnterprise()` with the enterprise address, name, and metadata.
4. Network Admin adds the enterprise address to the L1 transaction allowlist via the precompile.
5. Enterprise receives their wallet credentials and RPC endpoint.
6. Enterprise can now send zero-fee transactions to the network.
7. The registration event is visible on the network dashboard.

---

## Journey 2: PLASMA — Maintenance Traceability

### Actors
- **Maintenance Technician** (at Ingenio Sancarlos)
- **PLASMA Platform** (web application)
- **Blockchain Adapter** (background service)
- **Basis Network L1** (blockchain)

### Steps

1. Maintenance Technician opens PLASMA and creates a new work order for equipment maintenance.
2. PLASMA backend processes the work order and saves it to the operational database.
3. The Blockchain Adapter detects the new work order event.
4. The Adapter calls `PLASMAConnector.recordMaintenanceOrder()` with the order ID, equipment ID, priority, and encoded details.
5. The transaction is submitted to Basis Network L1 at zero cost.
6. The transaction confirms with sub-second finality.
7. The maintenance event appears on the network dashboard.
8. When the technician completes the work order, the Adapter calls `PLASMAConnector.completeMaintenanceOrder()`.
9. The full maintenance timeline for any equipment is queryable on-chain via `getMaintenanceHistory()`.

### Verification

At any time, an auditor can:
- Query the on-chain record and verify it matches the PLASMA database.
- Check timestamps to confirm when events were recorded.
- Verify that the recording enterprise is authorized via `EnterpriseRegistry.isAuthorized()`.

---

## Journey 3: Trace — Commercial Traceability

### Actors
- **Business Owner** (SME using Trace)
- **Trace Platform** (ERP application)
- **Blockchain Adapter** (background service)
- **Basis Network L1** (blockchain)

### Steps

1. Business Owner records a sale in Trace (product, quantity, amount).
2. Trace backend processes the sale and updates inventory.
3. The Blockchain Adapter detects the sale event and the inventory movement.
4. The Adapter calls `TraceConnector.recordSale()` and `TraceConnector.recordInventoryMovement()`.
5. Both transactions confirm on-chain at zero cost.
6. The sale and inventory movement appear on the network dashboard.
7. The complete sales history for any product is queryable via `getSaleHistory()`.
8. The complete inventory ledger is queryable via `getInventoryLedger()`.

---

## Journey 4: ZK Proof Verification

### Actors
- **Enterprise Prover** (off-chain service)
- **ZKVerifier Contract** (on-chain)
- **Network Dashboard** (visualization)

### Steps

1. An enterprise accumulates a batch of transactions off-chain.
2. The enterprise prover compiles the transaction data into a Circom circuit.
3. SnarkJS generates a Groth16 proof attesting to batch validity.
4. The proof and public signals are submitted to `ZKVerifier.verifyBatchProof()`.
5. The contract verifies the Groth16 proof on-chain (~200K gas).
6. If valid, the batch is recorded with its state root and transaction count.
7. The verification result appears on the network dashboard.
8. Anyone on the network can confirm that the enterprise processed valid transactions without seeing the transaction data.

---

## Journey 5: Network Dashboard

### Actors
- **Judge / Auditor / Stakeholder** (external viewer)

### Steps

1. User opens the Basis Network dashboard (hosted on Vercel).
2. Dashboard connects to the L1 RPC endpoint.
3. User sees:
   - Total registered enterprises and their status.
   - Real-time transaction feed with event types.
   - Metrics: total transactions, events by type, completion rates.
   - Network health: current block, gas price (confirming zero-fee).
   - ZK verification history and batch summaries.
4. User can click on any transaction to see its on-chain details.
5. User can filter events by enterprise, type, or time range.
