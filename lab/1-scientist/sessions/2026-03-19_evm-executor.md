# Session Log: EVM Executor (RU-L1)

- **Date:** 2026-03-19
- **Target:** zkl2
- **Experiment:** evm-executor
- **Stage:** 1 (Implementation)
- **Iteration:** 0 -> 1

## What Was Accomplished

1. **Created experiment structure** at `zkl2/research/experiments/2026-03-19_evm-executor/`
   with hypothesis.json, state.json, journal.md, findings.md, code/, results/, memory/

2. **Conducted comprehensive literature review** (15+ sources):
   - Analyzed how Polygon CDK, Scroll, zkSync Era, and Optimism use/fork Geth
   - Collected ZK constraint costs from Polygon zkevm-rom documentation
   - Surveyed EVM performance benchmarks (Reth, Gravity Reth, op-geth)
   - Reviewed arXiv:2510.05376 on zkEVM constraint-level design

3. **Wrote experimental Go code** (3 files):
   - `main.go`: Full benchmark suite with ZK tracer, transfer + storage benchmarks
   - `opcode_analysis.go`: Complete Cancun opcode-to-ZK-constraint mapping (75+ opcodes)
   - `setup.sh`: Build and dependency analysis script

4. **Documented projected benchmark results** based on published data
   (Go runtime not installed on this machine)

5. **Created zkl2 foundation documents**:
   - `zkl2/research/foundations/zk-01-objectives-and-invariants.md` (8 invariants)
   - `zkl2/research/foundations/zk-02-threat-model.md` (10 threats)

## Key Findings

1. **No production zkEVM uses Geth directly for proving.** All separate execution (Geth) from proving (custom engine). This validates our Go node + Rust prover architecture.

2. **Import-as-module (Strategy A) is the recommended approach.** op-geth changed only 34 lines of EVM code. We can implement custom StateDB (with Poseidon SMT) without forking Geth.

3. **core/tracing hooks API is the right tracing interface.** Event-driven callbacks for state changes, 10-30% overhead vs 10-50x for structLogger.

4. **KECCAK256 costs ~150K R1CS constraints.** Confirms Poseidon choice. Preimage oracle with lookup table is the standard mitigation.

5. **Scroll is moving away from custom zktrie toward MPT + zkVM.** Suggests that coupling state trie modifications directly into Geth fork creates maintenance burden. Our Strategy A (custom StateDB via interface) is architecturally cleaner.

6. **1000+ tx/s is achievable.** Geth at 100-200 MGas/s processes 5K-10K simple transfers/s. Even with 30% tracing overhead, this exceeds our 1000 tx/s target.

## Artifacts Produced

| Path | Description |
|------|-------------|
| `zkl2/research/experiments/2026-03-19_evm-executor/hypothesis.json` | Experiment hypothesis |
| `zkl2/research/experiments/2026-03-19_evm-executor/state.json` | Current state |
| `zkl2/research/experiments/2026-03-19_evm-executor/journal.md` | Experiment journal |
| `zkl2/research/experiments/2026-03-19_evm-executor/findings.md` | Literature review + findings |
| `zkl2/research/experiments/2026-03-19_evm-executor/code/main.go` | Benchmark suite |
| `zkl2/research/experiments/2026-03-19_evm-executor/code/opcode_analysis.go` | Opcode ZK mapping |
| `zkl2/research/experiments/2026-03-19_evm-executor/code/setup.sh` | Setup script |
| `zkl2/research/experiments/2026-03-19_evm-executor/code/go.mod` | Go module file |
| `zkl2/research/experiments/2026-03-19_evm-executor/results/benchmark_results_projected.json` | Projected results |
| `zkl2/research/experiments/2026-03-19_evm-executor/memory/session.md` | Session memory |
| `zkl2/research/foundations/zk-01-objectives-and-invariants.md` | System invariants |
| `zkl2/research/foundations/zk-02-threat-model.md` | Threat model |

## Next Steps

1. **Install Go 1.22+** on this machine (winget install GoLang.Go)
2. **Run benchmarks** via `cd code && ./setup.sh` to get actual tx/s, trace sizes, memory usage
3. **Validate predictions** against actual benchmark results
4. **Advance to Stage 2** (Baseline): Run 30+ replications per benchmark configuration
5. **Feed results to Logicist** (RU-L1 TLA+ formalization): EVM as state machine with
   SLOAD/SSTORE/CALL/CREATE operations and trace completeness invariants
