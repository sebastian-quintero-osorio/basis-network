# Session Log: Production DAC Verification

- **Date**: 2026-03-19
- **Target**: zkl2
- **Unit**: 2026-03-production-dac
- **Status**: COMPLETE -- All proofs compile, 0 Admitted

## What Was Accomplished

Constructed and verified a complete Coq proof development certifying that the
Production DAC protocol's Go + Solidity implementation satisfies its TLA+
specification. The proof covers 8 safety invariants as inductive invariants
over the 9-action transition system.

## Artifacts Produced

| File | Path | Purpose |
|------|------|---------|
| Common.v | zkl2/proofs/units/2026-03-production-dac/1-proofs/ | Types, axiomatized finite sets, lemmas |
| Spec.v | zkl2/proofs/units/2026-03-production-dac/1-proofs/ | TLA+ faithful translation |
| Impl.v | zkl2/proofs/units/2026-03-production-dac/1-proofs/ | Go/Solidity abstract model + crypto axioms |
| Refinement.v | zkl2/proofs/units/2026-03-production-dac/1-proofs/ | 19 theorems, 0 Admitted |
| verification.log | zkl2/proofs/units/2026-03-production-dac/2-reports/ | Compilation output |
| SUMMARY.md | zkl2/proofs/units/2026-03-production-dac/2-reports/ | Full verification summary |

Frozen inputs copied to 0-input-spec/ (ProductionDAC.tla) and
0-input-impl/ (10 Go files + BasisDAC.sol).

## Theorems Proved

1. CertificateSoundness: valid cert requires >= threshold attestations
2. DataRecoverability: recovery from k uncorrupted nodes succeeds
3. ErasureSoundness: corrupted recovery nodes are always detected
4. Privacy: successful recovery requires >= threshold participants
5. RecoveryIntegrity: success implies no corruption in recovery set
6. AttestationIntegrity: only verified nodes can attest
7. VerificationIntegrity: only distributed nodes can verify
8. NoRecoveryBeforeDistribution: structural ordering invariant
9-11. Crypto property theorems (RS+AES, Shamir threshold, AES integrity)

## Decisions Made

1. **Axiomatized finite sets**: Used 16 axioms for NSet operations instead of
   Coq's Ensemble library. Justified by TLC model checking (141M states) and
   standard mathematical properties. Provides cleaner intro/elim proof patterns.

2. **Added 8th invariant (NoRecoveryBeforeDistribution)**: Required for the
   DataRecoverability preservation proof under DistributeChunks. Without it,
   the proof cannot derive contradiction when distributedTo changes from empty
   to non-empty (the recovery state could be non-None in the pre-state with
   no way to map back to the IH). This invariant captures the action guard
   chain: RecoverData -> ProduceCertificate -> NodeAttest -> VerifyChunk ->
   DistributeChunks, meaning an empty distributedTo blocks the entire chain.

3. **Disjunctive RecoverData**: Modeled the RecoverData action's three-way
   outcome (failed/corrupted/success) as an explicit disjunction rather than
   an if-then-else. This enables clean case analysis in preservation proofs.

4. **Targeted subst in batch_cases**: Used `subst b` instead of `subst` or
   `rewrite ... in *` to avoid accidentally clearing equation hypotheses
   during batch equality case splits.

## Compiler

Rocq Prover 9.0.1 (compiled with OCaml 4.14.2)
Import syntax: `From Stdlib Require Import ...` (Rocq 9.0 renamed `Coq` to `Stdlib`)

## Next Steps

- Consider adding liveness proofs (AttestationLiveness, EventualFallback) --
  would require temporal logic encoding or fairness modeling in Coq.
- The proof development could be extended to cover committee rotation
  (ReplaceNode) if added to the TLA+ spec.
