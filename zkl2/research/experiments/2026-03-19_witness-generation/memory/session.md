# Session Memory: Witness Generation Experiment

## Key Decisions
- Multi-table witness architecture (one table per EVM operation category)
- BN254 scalar field for all field elements (matching state DB)
- Trace input via JSON serialization (gRPC deferred to Architect)
- Modular design: arithmetic, storage, memory, call context tables

## Trace Format (from Go executor)
- ExecutionTrace: {tx_hash, from, to, value, gas_used, success, opcode_count, entries[], opcode_log[]}
- TraceEntry: discriminated union on Op (SLOAD, SSTORE, CALL, BALANCE_CHANGE, NONCE_CHANGE, LOG)
- SLOAD: account, slot, value
- SSTORE: account, slot, old_value, new_value
- CALL: from, to, call_value
- BALANCE_CHANGE: account, prev_balance, curr_balance, reason
- NONCE_CHANGE: account, prev_nonce, curr_nonce

## ZK Constraint Costs (from opcodes.go)
- SLOAD/SSTORE: ~255 Poseidon ops (ZKExpensive)
- CALL: ~20K R1CS constraints (ZKVeryExpensive)
- KECCAK256: ~150K R1CS constraints (ZKCritical)
- Arithmetic: ~30-100 R1CS constraints (ZKCheap)

## Performance Targets
- 1000 tx witness generation: < 30 seconds
- Memory: < 4 GB peak
- Determinism: 100% (same trace -> same witness, bit-for-bit)
