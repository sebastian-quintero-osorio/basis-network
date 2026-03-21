# Session Log: PLONK Migration (RU-L9)

- **Date:** 2026-03-19
- **Target:** zkl2
- **Experiment:** plonk-migration
- **Checklist Item:** [33] Scientist | RU-L9: PLONK
- **Stage:** 1 (Implementation) -- Complete

## What Was Accomplished

1. **Created experiment structure** at `zkl2/research/experiments/2026-03-19_plonk-migration/`
   with hypothesis.json, state.json, journal.md, findings.md, session memory.

2. **Literature review** (31 sources): 12 primary papers (PLONK, Groth16, plookup, Nova,
   SuperNova, Poseidon, FFLONK, Halo, plonky2), 6 production systems (Scroll, Axiom,
   zkSync Era, Polygon zkEVM, Taiko, Linea), 9 benchmark studies, 4 implementation references.

3. **Proof system evaluation**: Compared 4 candidates:
   - Groth16 (current): 128B proof, ~220K gas, per-circuit setup
   - halo2-KZG (selected): 672-800B proof, 290-420K gas, universal SRS
   - halo2-IPA (eliminated): no EVM precompile for Pallas/Vesta
   - plonky2 (eliminated): 43-130KB proof, deprecated, field incompatible

4. **Rust benchmarks** (30 iterations, release mode): Implemented and ran comparative
   benchmarks for Groth16 (arkworks) vs halo2-KZG (PSE fork) on arithmetic chain and
   hash chain (x^5 S-box) circuits.

5. **Updated foundational documents**:
   - zk-01: Added I-37 (Proof System Agnosticism), I-38 (Universal SRS Reuse), I-39 (Proof Size Bound)
   - zk-02: Added T-32 through T-35 (migration gap, SRS compromise, custom gate soundness, library risk)

## Key Findings

- halo2-KZG proving overhead converges from 4.7x (small circuits) to 1.2x (500+ steps)
- Custom gates reduce rows 2.4x for x^5 gate, projected 17x for full Poseidon
- Proof size: 672-800 bytes (well under 1KB target)
- Verification gas: 290-420K published (under 500K target)
- Verification time: 3.3-3.9ms (near-identical to Groth16's 3.1ms)

## Verdict

**HYPOTHESIS CONFIRMED.** halo2-KZG (Axiom fork) is recommended for Basis Network zkEVM L2.

## Artifacts Produced

| File | Path |
|------|------|
| Hypothesis | `zkl2/research/experiments/2026-03-19_plonk-migration/hypothesis.json` |
| State | `zkl2/research/experiments/2026-03-19_plonk-migration/state.json` |
| Findings | `zkl2/research/experiments/2026-03-19_plonk-migration/findings.md` |
| Journal | `zkl2/research/experiments/2026-03-19_plonk-migration/journal.md` |
| Benchmark code | `zkl2/research/experiments/2026-03-19_plonk-migration/code/` |
| Results JSON | `zkl2/research/experiments/2026-03-19_plonk-migration/results/benchmark_results.json` |
| Analysis | `zkl2/research/experiments/2026-03-19_plonk-migration/results/analysis.md` |
| Session memory | `zkl2/research/experiments/2026-03-19_plonk-migration/memory/session.md` |
| Updated invariants | `zkl2/research/foundations/zk-01-objectives-and-invariants.md` |
| Updated threats | `zkl2/research/foundations/zk-02-threat-model.md` |
| Updated global memory | `lab/1-scientist/memory/global.md` |

## Next Steps

1. **Handoff to Logicist** (item [34]): Copy findings to `lab/2-logicist/research-history/2026-03-plonk-migration/0-input/`
2. Logicist formalizes proof system properties as TLA+ axioms
3. Logicist verifies migration safety and backward compatibility invariants
4. Architect (item [35]) implements halo2 circuit and PLONKVerifier.sol
5. Prover (item [36]) verifies soundness preservation via Coq
