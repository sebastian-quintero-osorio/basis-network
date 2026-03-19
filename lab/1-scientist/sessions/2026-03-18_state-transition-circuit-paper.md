# Session Log -- State Transition Circuit Paper (RU-V2)

- **Date**: 2026-03-18
- **Target**: validium
- **Experiment**: state-transition-circuit (RU-V2)
- **Task**: Write academic paper from experiment findings

## What Was Accomplished

Wrote a complete 6-page IEEE conference-format paper covering the
ChainedBatchStateTransition circuit design, benchmarking, and analysis.

### Paper Structure

1. **Abstract** (200 words): Problem, approach, key results, significance
2. **Introduction**: Motivation (enterprise privacy), gap (no isolated SMT
   state transition benchmarks), contributions (3), key finding (2.19M
   constraints at depth-32 batch-64, feasible with Rapidsnark)
3. **Related Work**: ZK proof systems, SMT in ZK, production system
   comparison table (Tornado Cash, Semaphore, Hermez, Polygon zkEVM),
   Groth16 prover benchmarks table
4. **System Model and Methodology**: Trust model, circuit design
   (MerklePathVerifier + ChainedBatchStateTransition), per-tx constraint
   decomposition, benchmark methodology, extrapolation method
5. **Results**: Full 7-configuration benchmark table, exact constraint
   formula C_tx = 1,038 * (d+1), batch/depth scaling analysis, proving
   time analysis, proof size invariance, extrapolated production targets
6. **Discussion**: Hypothesis evaluation (100K rejected, 60s partially
   confirmed), formula significance for capacity planning, comparison
   with Hermez/Tornado Cash, optimization paths, honest limitations
7. **Conclusion**: 3 contributions, future work (adversarial testing,
   Rapidsnark benchmarking, SMTProcessor comparison)

### Key Paper Findings

- Exact formula: C_tx = 1,038 * (d+1) with zero residual error
- Depth-32 batch-64: ~2.19M constraints, 14-35s with Rapidsnark
- Per-tx at d=32: 34,254 constraints (0.59x Hermez, consistent)
- Proof size constant: 803-807 bytes across all configurations
- 15+ references including Groth16, Poseidon, Hermez, Tornado Cash,
  Polygon zkEVM, Rapidsnark, Tachyon, ICICLE-Snark

## Artifacts Produced

All in `validium/research/experiments/2026-03-18_state-transition-circuit/paper/`:

- `main.tex` -- Master document (IEEEtran conference format)
- `abstract.tex` -- Abstract section
- `introduction.tex` -- Introduction section
- `related-work.tex` -- Related work with 2 comparison tables
- `methodology.tex` -- System model and methodology
- `results.tex` -- Results with 6 tables
- `discussion.tex` -- Discussion section
- `conclusion.tex` -- Conclusion section
- `references.bib` -- 24 BibTeX entries
- `main.pdf` -- Compiled 6-page PDF (312 KB)

## Next Steps

- Adversarial self-review (/review) for quality improvement
- Stage 3 experiments if deeper analysis is needed
- Downstream: Logicist formalization of the circuit properties
