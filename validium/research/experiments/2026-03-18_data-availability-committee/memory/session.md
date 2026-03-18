# Session Memory: Data Availability Committee (RU-V6)

## Key Decisions
- Chose (2,3)-Shamir over (3,3)-Shamir: 8x recovery speed, same privacy
- ECDSA over BLS for attestation: native EVM, simpler, sufficient for 3 nodes
- SHA-256 for data commitment (not Poseidon): faster, standard; Poseidon if in-circuit
- AnyTrust-style fallback: post data on-chain if <k nodes available
- Adaptive replications (50/30/10) due to JS BigInt cost

## Performance Baseline (Measured)
- Share gen: ~9.5 us/element (JS BigInt), linear scaling confirmed
- Attestation pipeline @ 500KB: 163ms mean, 175ms P95
- Attestation pipeline @ 1MB: 320ms mean, 346ms P95
- Recovery 2-of-3 @ 100KB: 251ms; 3-of-3 @ 100KB: 1946ms (8x ratio)
- Storage overhead: 3.87x (3 nodes * 32/31 encoding)
- On-chain verify: 0.02ms (3 ecrecovers)
- Privacy tests: 51/51, Recovery tests: 61/61

## Critical Numbers from Literature
- SSS (2,3) estimate: ~0.6-3 us/element native (measured 9.5 us JS = 3-16x overhead)
- BLS signature: 48 bytes constant; ECDSA: 65 bytes * N
- EigenDA V2: 100 MB/s, 5s avg latency, 8x redundancy
- L2Beat rates 2/3 threshold as "BAD"; 5/6 AnyTrust as "WARNING"
- Semi-AVID-PR: 22 MB / 256 nodes / <3s / privacy guaranteed

## Innovation Finding
No production DAC (StarkEx, Polygon CDK, Arbitrum Nova) provides data privacy.
They all distribute COMPLETE data to every member. SSS approach provides
information-theoretic privacy (strongest possible guarantee).

## Production Systems Surveyed
StarkEx (ECDSA, full replication, no privacy), Polygon CDK (ECDSA, CDKDataCommittee.sol),
Arbitrum Nova (BLS, AnyTrust, rollup fallback), EigenDA (BLS + KZG, RS coding),
Celestia (DAS, 2D RS, public data), Espresso (VID, 1/4 recovery), zkPorter (not deployed)

## Papers Collected (24 references)
15+ with real numbers. Key: [11] Al-Bassam DAS, [13] Nazirkhanova Semi-AVID-PR,
[17] Boneh BLS multi-sig, [16] Shamir SSS, [15] Gentry PVSS.

## Open Items for Stage 3
- Malicious share injection
- Timing side-channel analysis
- Colluding node scenarios
- Network partition simulation
- Proof-of-custody mechanism
