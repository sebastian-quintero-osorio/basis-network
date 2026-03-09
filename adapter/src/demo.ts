import { PLASMAAdapter } from "./plasma-adapter";
import { TraceAdapter } from "./trace-adapter";
import * as dotenv from "dotenv";

dotenv.config();

/// Demonstration script that simulates real PLASMA and Trace events
/// being written to the Basis Network L1.
async function main() {
  console.log("=== Basis Network Adapter Demo ===\n");

  const plasma = new PLASMAAdapter();
  const trace = new TraceAdapter();

  // --- PLASMA: Simulate industrial maintenance workflow ---
  console.log("--- PLASMA: Industrial Maintenance ---\n");

  // 1. Create maintenance work orders
  console.log("Creating maintenance work orders...");
  await plasma.recordWorkOrder("WO-2026-001", "BOILER-A1", 1, "Critical pressure valve replacement");
  await plasma.recordWorkOrder("WO-2026-002", "TURBINE-B3", 2, "Scheduled bearing inspection");
  await plasma.recordWorkOrder("WO-2026-003", "CONVEYOR-C1", 3, "Belt tension adjustment");

  // 2. Record equipment inspection
  console.log("Recording equipment inspection...");
  await plasma.recordInspection("BOILER-A1", "Temperature: 185C, Pressure: 12bar, Status: nominal");

  // 3. Complete a work order
  console.log("Completing work order...");
  await plasma.completeWorkOrder("WO-2026-001", "Valve replaced. Pressure test passed at 15bar.");

  // 4. Show stats
  const plasmaStats = await plasma.getStats();
  console.log(`\nPLASMA Stats: ${plasmaStats.totalOrders} orders, ${plasmaStats.completedOrders} completed\n`);

  // --- Trace: Simulate commercial transactions ---
  console.log("--- Trace: Commercial ERP ---\n");

  // 1. Record sales
  console.log("Recording sales...");
  await trace.recordSale("SALE-001", "SUGAR-50KG", 100, 5000000);
  await trace.recordSale("SALE-002", "MOLASSES-20L", 50, 1500000);

  // 2. Record inventory movements
  console.log("Recording inventory movements...");
  await trace.recordInventoryMovement("SUGAR-50KG", -100, "SALE");
  await trace.recordInventoryMovement("SUGAR-50KG", 500, "PRODUCTION");

  // 3. Record supplier transaction
  console.log("Recording supplier transaction...");
  await trace.recordSupplierTransaction("SUPP-CANE-01", "RAW-CANE", 10000);

  // 4. Show stats
  const traceStats = await trace.getStats();
  console.log(`\nTrace Stats: ${traceStats.totalSales} sales, ${traceStats.totalInventoryMovements} inventory moves, ${traceStats.totalSupplierTransactions} supplier txns\n`);

  console.log("=== Demo Complete ===");
  console.log("All events have been written to Basis Network L1.");
  console.log("Check the dashboard to see on-chain activity.");
}

main().catch(console.error);
