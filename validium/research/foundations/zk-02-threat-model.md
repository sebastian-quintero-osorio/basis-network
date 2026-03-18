# ZK-02: Threat Model

> Living document. Updated after every experiment that discovers new attack vectors.

## Adversary Model

### Capabilities

1. **External adversary**: Can observe all L1 transactions (public blockchain).
2. **Compromised enterprise**: A registered enterprise may attempt to submit invalid proofs.
3. **Network adversary**: Can delay or reorder L1 transactions (standard blockchain threat model).
4. **Colluding enterprises**: Multiple enterprises may collude to attack the system.

### Out of Scope (MVP)

1. Quantum adversary (post-quantum migration planned for long-term).
2. Side-channel attacks on proof generation hardware.
3. Social engineering of enterprise operators.

## Attack Vectors (Accumulated from Experiments)

### ZK Proof Attacks

- **ATK-ZK1**: Submit invalid proof (random bytes). Mitigation: on-chain verification rejects.
- **ATK-ZK2**: Replay valid proof for different batch. Mitigation: batch root in public signals.
- **ATK-ZK3**: Submit proof for wrong enterprise. Mitigation: enterprise ID in public signals.
- **ATK-ZK4**: Forge proof without valid witness. Mitigation: Groth16 soundness guarantee.

### State Machine Attacks

- **ATK-SM1**: Skip state root in chain. Mitigation: previous root validation in contract.
- **ATK-SM2**: Submit conflicting state roots. Mitigation: sequential batch numbers.
- **ATK-SM3**: Corrupt Merkle tree locally. Mitigation: ZK proof includes tree integrity.

### Data Availability Attacks

- **ATK-DA1**: Enterprise withholds data after proof submission. Mitigation: DAC attestation.
- **ATK-DA2**: DAC members collude to attest unavailable data. Mitigation: multi-party DAC with honest minority assumption.

### Bridge Attacks (Long-term)

- **ATK-BR1**: Double withdrawal. Mitigation: withdrawal nullifiers.
- **ATK-BR2**: Withdrawal with stale state proof. Mitigation: state root freshness check.

### State Management Attacks (from RU-V1: Sparse Merkle Tree, 2026-03-18)

- **ATK-SMT1**: Key collision -- Two different enterprise records map to the same leaf index. Mitigation: Poseidon key derivation distributes uniformly; depth 32 provides 2^32 slots. Collision probability < 2^(-64) for 100K entries (birthday bound). For >1M entries, monitor collision rate.
- **ATK-SMT2**: Merkle proof forgery -- Adversary constructs a valid proof for a non-existent entry. Mitigation: Poseidon collision resistance (128-bit security); finding two inputs that produce same hash requires O(2^128) work.
- **ATK-SMT3**: State root manipulation via default hash exploitation -- Adversary exploits knowledge of precomputed default hashes to craft misleading proofs. Mitigation: Leaf hashes include the key as input (H(key, value)), preventing substitution of default-value leaves for key-specific leaves.
- **ATK-SMT4**: Memory exhaustion attack -- Adversary submits enough transactions to exceed node memory. Mitigation: Production implementation must use database-backed storage (not in-memory Map) for trees beyond 100K entries. In-memory limit observed at ~234 MB for 100K entries.

## Security Assumptions

1. Groth16 is sound under the q-PKE and d-PDH assumptions in the generic group model.
2. The trusted setup ceremony was performed correctly (at least one honest participant).
3. Poseidon hash is collision-resistant under the algebraic group model.
4. The Basis Network L1 provides finality (Snowman consensus assumption).
5. At least one DAC member is honest (data availability assumption).
6. Poseidon with recommended round parameters provides 128-bit security against algebraic attacks, including Grobner basis attacks (confirmed by Ethereum Foundation Poseidon Cryptanalysis Initiative 2024-2026, but subject to ongoing review per IACR ePrint 2025/954). (Added: RU-V1, 2026-03-18)
