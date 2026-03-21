# AI-Driven R&D Pipeline

Automated research and development laboratory for Basis Network. Four specialized autonomous agents conduct research, formalization, implementation, and verification in a pipelined workflow.

## Pipeline Architecture

```
Scientist --> Logicist --> Architect --> Prover
(Research)    (TLA+)      (Code)       (Coq)
```

Each research unit flows through all four agents sequentially:

| Agent | Role | Tool | Output |
|-------|------|------|--------|
| **Scientist** | Literature review, experiments, benchmarks | TypeScript, Python | `research/experiments/` |
| **Logicist** | Formal specification, model checking | TLA+ (TLC) | `specs/units/` |
| **Architect** | Production implementation, adversarial testing | TypeScript, Go, Rust, Solidity, Circom | `node/`, `circuits/`, `contracts/`, `tests/` |
| **Prover** | Mathematical verification proofs | Coq/Rocq | `proofs/units/` |

## Completed Work

### Validium MVP (28/28 agent executions)

7 research units fully processed through the pipeline on March 18, 2026:

| Research Unit | Scientist | Logicist | Architect | Prover |
|--------------|-----------|----------|-----------|--------|
| RU-V1: Sparse Merkle Tree | Benchmarks | 1.5M states | 52 tests | 10 theorems |
| RU-V2: State Transition Circuit | 7 benchmarks | 3.3M states | 6 adversarial | 7 theorems |
| RU-V3: L1 State Commitment | Gas analysis | 3.8M states | 138 tests | 11 theorems |
| RU-V4: Batch Aggregation | 274K tx/min | NoLoss bug found | 45 tests + fix | 55 theorems |
| RU-V5: Enterprise Node | 593ms overhead | 3,958 states | 249 tests | 13 theorems |
| RU-V6: Data Availability | 175ms P95 | 6 safety invariants | 167 tests | 16 theorems |
| RU-V7: Cross-Enterprise | 1.41x overhead | 461K states | 44 tests | 13 theorems |

**Aggregate metrics:** 10.7M TLC states explored, 125+ Coq theorems (0 Admitted), ~100 adversarial attack vectors tested, 1 critical bug found by formal verification.

### zkEVM L2 (in progress)

11 research units planned across 5 phases. EVM Executor (RU-L1) complete with 1,748 lines Go and TLA+ specification verified.

## Quality Gates

Each agent enforces strict quality gates:

- **Scientist:** 15+ papers reviewed, falsifiable hypotheses, stochastic baselines
- **Logicist:** All TLC invariants pass (Safety + Liveness), exhaustive state exploration
- **Architect:** All tests pass, adversarial scenarios, no code without verified spec ("Safety Latch")
- **Prover:** Zero `Admitted` theorems, all proofs from first principles

## Directory Structure

```
lab/
|-- orchestrator/       # Execution protocol and agent prompts
|-- 1-scientist/        # Research agent (sessions, memory)
|-- 2-logicist/         # TLA+ specification agent (sessions, tools)
|-- 3-architect/        # Implementation agent (sessions)
+-- 4-prover/           # Coq verification agent (sessions)
```

## Documentation

- [R&D Pipeline Report](../validium/docs/R&D_PIPELINE_REPORT.md) -- Full 17-hour execution summary
- [Orchestrator Protocol](./orchestrator/ORCHESTRATOR.md) -- How the pipeline executes autonomously
