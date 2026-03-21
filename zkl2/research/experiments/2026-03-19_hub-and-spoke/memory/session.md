# Session Memory: Hub-and-Spoke Cross-Enterprise Communication (RU-L11)

## Key Decisions

1. **Architecture**: Hub-and-spoke with L1 as hub is the natural topology for enterprise multi-chain.
   O(N) connections vs O(N^2) for mesh. Fault isolation per enterprise. L1 decentralization
   eliminates single-point-of-failure concern.

2. **Aggregation is mandatory**: Sequential gas (813K per cross-ref at 8 enterprises) exceeds
   500K target. Batched pairing also exceeds at scale (860K for 8e/4cr). Only ProtoGalaxy
   aggregation (243K constant) meets the target. This is the critical finding.

3. **Privacy model**: 1-bit leakage per interaction (existence only). Same as RU-V7 baseline.
   Poseidon commitment hides all claim content. Hub sees metadata only.

4. **Atomic settlement**: Two-phase with L1 smart contract enforcement. 100% atomicity by
   construction. Stale root detection prevents settlement after state changes.

5. **Latency budget**: Direct 10.5s, aggregated 16s, atomic 15.5s. All under 30s target.
   Dominated by proof generation (3-4.5s per proof) and Avalanche finality (2s).

## Literature Anchors

- Rayls/Enygma (IACR ePrint 2025/1638, IEEE S&P 2024): Closest production analogue.
  Commit chain + privacy ledgers = hub-and-spoke. Pedersen commitments + ZK + HE.
  Deployed by Nuclea, Cielo for Brazilian Drex CBDC.

- Polygon AggLayer: Pessimistic proofs ensure no chain over-withdraws. Safety invariant
  analogous to our cross-enterprise isolation. SP1/Plonky3 implementation.

- zkSync Elastic Chain: ZK Router + Gateway + shared bridge. ~1s soft confirmations.
  Proof aggregation across ZK Chains. Our atomic settlement is similar.

- Avalanche ICM/AWM: Native cross-L1 messaging with BLS multi-signatures. <1s finality.
  Our hub leverages this for inter-enterprise coordination.

## Anti-Confirmation Bias Notes

- Mesh topology was evaluated fairly. It has no SPoF advantage when the hub is decentralized.
  O(N^2) scaling and cascading failure risk make it strictly inferior for enterprise.

- Sequential verification was tested under favorable conditions (2 enterprises, 1 interaction).
  Even there, it uses 813K gas. The conclusion that aggregation is required is robust.

- The 1-bit leakage claim was validated through 8 distinct privacy tests. No additional
  leakage vectors discovered.

## What Would Change My Mind

- If ProtoGalaxy folding introduces >5s overhead per fold step in practice (current model: 250ms)
- If atomic settlement timeout creates economic attack vectors (e.g., griefing by
  submitting one side and never completing)
- If enterprise regulatory requirements mandate >1 bit of cross-enterprise visibility
  (audit requirements may need selective disclosure, not zero leakage)
