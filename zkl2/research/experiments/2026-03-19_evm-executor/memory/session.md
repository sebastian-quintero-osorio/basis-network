# Session Memory: EVM Executor Experiment

## Key Decisions

1. **Strategy A (import as module) over Strategy B (fork).**
   Rationale: op-geth shows minimal diff is possible. Custom StateDB implementing
   vm.StateDB interface allows Poseidon SMT without forking core Geth code.
   Only fork if interface proves insufficient.

2. **core/tracing hooks API over structLogger.**
   Rationale: Event-driven callbacks capture exactly what ZK witness needs.
   structLogger captures everything (10-50x overhead); hooks are selective.

3. **Selective tracing over full opcode capture.**
   Capture state changes (storage, balance, nonce, logs) but NOT every opcode.
   Full opcode trace only for debugging. This keeps overhead at 10-30%.

4. **Execution and proving are separate concerns.**
   No production zkEVM proves execution inline. Geth EVM executes and produces traces.
   Rust prover consumes traces asynchronously. This matches TD-001/TD-002.

## Metrics Collected

| Metric | Projected Value | Source |
|--------|----------------|--------|
| Simple transfer tx/s (no trace) | 5,000-15,000 | Geth 100-200 MGas/s at 21K gas/tx |
| Simple transfer tx/s (ZK trace) | 4,000-12,000 | 10-25% overhead estimate |
| Storage write tx/s (no trace) | 2,000-8,000 | Higher gas per tx |
| Storage write tx/s (ZK trace) | 1,500-6,000 | 15-30% overhead estimate |
| KECCAK256 constraints (R1CS) | ~150,000 | Polygon zkevm-rom, arXiv:2510.05376 |
| SLOAD/SSTORE Poseidon cost | 255 cnt_poseidon_g | Polygon zkevm-rom |
| op-geth EVM diff | 34 lines | op-geth.optimism.io |

## Open Questions

1. Does Geth's vm.StateDB interface support all operations needed for Poseidon SMT?
   Specifically: can we intercept state root computation and replace MPT with SMT?
   -> LIKELY YES: StateDB interface is abstract enough. Scroll did this with zktrie.

2. What is the actual trace format that the Rust prover needs?
   -> Depends on RU-L3 (Witness Generation). Current ZKTrace struct is a starting point.

3. How do we handle KECCAK256 in the ZK circuit?
   -> Preimage oracle with lookup table. Batch all Keccak invocations, compute off-circuit,
      verify via lookup. This is what Polygon and Scroll do.

4. Should we track Geth upstream via automated merge or manual cherry-pick?
   -> Strategy A (import as module) handles this automatically via `go get -u`.
      Only need to watch for breaking API changes in core/vm or core/tracing.

5. What Go version should we target?
   -> Go 1.22+ (matches Geth's minimum requirement).

## Architecture Insights from Literature

- Polygon CDK: Moved from custom zkevm-node to Erigon fork. Executor is separate C++ component.
- Scroll: Fork of go-ethereum with zktrie. Moving to MPT + OpenVM (zkVM) in 2025 Euclid upgrade.
- zkSync Era: Custom register-based VM (EraVM). Added EVM interpreter on top. Moving to Boojum 2.0.
- Optimism: Minimal Geth fork. 16,881 lines added, only 34 touch EVM. Good reference for minimal diff.
- Reth: Rust reimplementation achieving 1.5 GGas/s. Not a Geth fork but shows EVM performance ceiling.
