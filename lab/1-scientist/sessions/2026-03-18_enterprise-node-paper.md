# Session: Enterprise Node Orchestrator Paper (RU-V5)

- **Date**: 2026-03-18
- **Target**: validium
- **Experiment**: enterprise-node (RU-V5)
- **Task**: Write academic paper (LaTeX, IEEE conference format)

## What was accomplished

Wrote complete LaTeX paper for the enterprise node orchestrator experiment:
- Title: "Enterprise Node Orchestration for ZK Validium: Pipelined State Machine Design and Performance Analysis"
- 10 files: main.tex, abstract.tex, introduction.tex, related-work.tex, system-model.tex, methodology.tex, experimental-setup.tex, results.tex, discussion.tex, conclusion.tex, references.bib
- Compiled PDF: 8 pages, 303 KB

## Paper structure

1. **Abstract** (220 words): Pipelined state machine, 593ms overhead (0.66% budget), 1.29x speedup, snarkjs constraint at b64
2. **Introduction**: Motivation (enterprise privacy), gap (public L2 orchestration vs enterprise validium), three contributions
3. **Related Work**: Production ZK nodes (Polygon, zkSync, Scroll, push0), state machine patterns, crash recovery, prover performance. Architecture comparison table (full-width)
4. **System Model**: Three-tier architecture, trust assumptions, privacy model, performance requirements
5. **Methodology**: State machine design (6 states, 17 transitions), pipelined architecture (3 concurrent loops), component integration, API design, technology selection (Fastify)
6. **Experimental Setup**: 5 benchmark scenarios (30-50 iterations each), mock calibration, statistical protocol
7. **Results**: 46/46 state machine tests, orchestration overhead table (5 scenarios), per-phase breakdown, overhead scaling equation, pipeline speedup table (6 configs), E2E vs 90s target, memory footprint, benchmark reconciliation
8. **Discussion**: Hypothesis evaluation (partial confirmation), proving bottleneck analysis, prover backend constraint, pipeline speedup characteristics, comparison with production systems, 5 limitations
9. **Conclusion**: 4 key findings, future work (Stages 2-4)
10. **References**: 24 BibTeX entries (20 from findings.md + 4 additional)

## Key findings presented

- Orchestration overhead: 593ms (b8), 4,704ms (b64) -- 0.66% and 5.2% of 90s budget
- Pipeline speedup: 1.29x at b64 with rapidsnark (4.37 tx/s)
- snarkjs FAILS at b64 (156.9s > 90s target)
- rapidsnark PASSES at b64 (18.9s, 4.8x margin)
- Memory: stable 84.8-87.1 MB across all scenarios
- Overhead scales linearly: T(n) = 11.4 + 72.7n ms

## Artifacts produced

- `validium/research/experiments/2026-03-18_enterprise-node/paper/main.tex`
- `validium/research/experiments/2026-03-18_enterprise-node/paper/abstract.tex`
- `validium/research/experiments/2026-03-18_enterprise-node/paper/introduction.tex`
- `validium/research/experiments/2026-03-18_enterprise-node/paper/related-work.tex`
- `validium/research/experiments/2026-03-18_enterprise-node/paper/system-model.tex`
- `validium/research/experiments/2026-03-18_enterprise-node/paper/methodology.tex`
- `validium/research/experiments/2026-03-18_enterprise-node/paper/experimental-setup.tex`
- `validium/research/experiments/2026-03-18_enterprise-node/paper/results.tex`
- `validium/research/experiments/2026-03-18_enterprise-node/paper/discussion.tex`
- `validium/research/experiments/2026-03-18_enterprise-node/paper/conclusion.tex`
- `validium/research/experiments/2026-03-18_enterprise-node/paper/references.bib`
- `validium/research/experiments/2026-03-18_enterprise-node/paper/main.pdf` (compiled, 8 pages)

## Next steps

- /review for adversarial self-review of the paper
- Stage 2: Replace mocks with real components, measure real E2E latency
