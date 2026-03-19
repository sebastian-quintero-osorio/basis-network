# Experiment Journal: State Database (RU-L4)

## 2026-03-19 -- Iteration 1: Setup and Literature Review

### Context

This experiment investigates a Go implementation of Sparse Merkle Tree with Poseidon hash
for the zkEVM L2 state database. It directly builds on the findings from Validium RU-V1
(TypeScript SMT with Poseidon) which was CONFIRMED with:
- Insert latency: 1.825ms (target < 10ms)
- Proof generation: 0.018ms (target < 5ms)
- Proof verification: 1.744ms (target < 2ms)

The key difference: Go native field arithmetic should be 50-200x faster than JavaScript BigInt.

### Key Questions

1. Which Go library provides the best Poseidon SMT? (gnark-crypto, iden3-go, custom)
2. How does EVM account model (address -> {nonce, balance, codeHash, storageRoot}) map to SMT?
3. What is the performance gap between Go and TypeScript implementations?
4. How do production zkEVM systems (Polygon, Scroll) structure their state DBs?
5. MPT vs SMT: what are the real tradeoffs for EVM state?

### What would change my mind?

- If Go Poseidon implementations are immature/buggy and cannot maintain BN254 field correctness
- If MPT provides significant advantages for EVM state that SMT cannot match
- If state root computation at 10K accounts exceeds 50ms even in Go
