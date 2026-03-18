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

## Security Assumptions

1. Groth16 is sound under the q-PKE and d-PDH assumptions in the generic group model.
2. The trusted setup ceremony was performed correctly (at least one honest participant).
3. Poseidon hash is collision-resistant under the algebraic group model.
4. The Basis Network L1 provides finality (Snowman consensus assumption).
5. At least one DAC member is honest (data availability assumption).
