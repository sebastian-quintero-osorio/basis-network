# Findings: Minimal Geth Fork as EVM Execution Engine

## Published Benchmarks (Literature Gate)

### Production zkEVM Architectures

| System | EVM Approach | Fork Base | Type | Proving Time/Batch | TPS (L2) |
|--------|-------------|-----------|------|-------------------|----------|
| Polygon zkEVM | Custom executor (C++) + zkASM | Not Geth (custom) | Type 3 | ~190-200s/batch | ~30-50 |
| Polygon CDK (cdk-erigon) | Erigon fork (Go) | Erigon | Type 3 | ~190-200s/batch | ~30-50 |
| Scroll | Geth fork (scroll-geth) | go-ethereum | Type 2 | Target <30s (2025) | Target 10K+ (2025) |
| zkSync Era | Custom VM (EraVM) | Not Geth | Type 4 | Variable | ~100-300 |
| Optimism (op-geth) | Geth fork (minimal diff) | go-ethereum | Optimistic | N/A (no ZK) | ~2000 |

### EVM Execution Performance Benchmarks

| Implementation | Metric | Value | Source |
|---------------|--------|-------|--------|
| Reth (Paradigm) | Live sync throughput | 100-200 MGas/s | Paradigm 2024 |
| Reth (single-threaded, prewarming) | Execution throughput | ~700 MGas/s | QuarkChain 2026 |
| Gravity Reth | ERC20 transfers | ~41,000 tx/s (1.5 GGas/s) | Galxe 2025 |
| Gravity Reth | Uniswap workload | 1.9 GGas/s | Galxe 2025 |
| revmc (JIT for EVM) | Improvement vs interpreter | 1.85x-19x | Paradigm 2024 |
| Geth (standard) | Estimated simple transfers | ~3,000-5,000 tx/s | Community benchmarks |
| op-geth fork diff | Lines added vs upstream | ~16,881 added, 664 deleted | op-geth.optimism.io |

### ZK Constraint Costs per Operation Category

| Category | Example Opcode | Estimated Constraints (R1CS) | PLONKish Constraints | Notes |
|----------|---------------|-------------------------------|---------------------|-------|
| Arithmetic | ADD (256-bit) | 200-300 | ~33 | Bit decomposition + range checks |
| Crypto | KECCAK256 (SHA3) | ~150,000 | ~15,000-50,000 | Boolean logic emulation; 1000x Poseidon |
| Storage | SLOAD/SSTORE | Varies (Poseidon-heavy) | ~255 Poseidon ops | State trie access |
| Memory | MLOAD/MSTORE | ~50-100 | Moderate | Memory expansion |
| Control | CALL/DELEGATECALL | Complex (context switch) | Dynamic | Stack frame management |
| Create | CREATE/CREATE2 | Complex (deployment) | Dynamic | Code hash + init execution |

### Polygon zkEVM ZK Counter Costs (from zkevm-rom)

| Opcode | cnt_arith | cnt_binary | cnt_keccak_f | cnt_poseidon_g | Notes |
|--------|-----------|-----------|--------------|----------------|-------|
| SHA3 (KECCAK256) | 192 | 193 | 2 | 10 | Most expensive overall |
| SLOAD | 0 | 0 | 0 | 255 | Poseidon-dominant (state trie) |
| SSTORE | 0 | - | 0 | 255 | Poseidon-dominant (state trie) |
| EXTCODESIZE | 0 | 0 | 0 | 255 | Full trie traversal |
| EXTCODECOPY | 0 | - | 0 | 510 | Double Poseidon cost |
| BLOCKHASH | 0 | 0 | 1 | 9 | Requires hash oracle |
| LOG0-LOG4 | 0 | - | 0 | 0 | Cheap in ZK (event emission) |
| CALL | - | - | 0 | - | Dynamic, context-dependent |
| CREATE/CREATE2 | - | - | - | - | Dynamic, most complex |

### Fork Strategies Comparison

**1. Polygon CDK (cdk-erigon)**
- Moved from custom zkevm-node to Erigon fork
- 10x less disk space, 150x faster sync vs zkevm-node
- Uses zkASM (custom assembly) for proving, not Geth VM
- The executor is actually a separate C++ component, not the EVM
- Go code handles sequencing, RPC, synchronization
- Key insight: the proving executor is separate from the EVM executor

**2. Scroll (scroll-geth)**
- Direct fork of go-ethereum
- Modified state trie: added zktrie (ZK-friendly Poseidon trie) alongside MPT
- Flag-based activation: config.scroll.useZktrie
- 2025 Euclid upgrade: migrating BACK to MPT + OpenVM (general-purpose zkVM)
- Key insight: Scroll is moving away from custom zktrie toward standard MPT + zkVM proving

**3. zkSync Era (EraVM)**
- Did NOT fork Geth -- built custom register-based VM
- EraVM uses registers instead of stack (simpler for ZK circuits)
- Added EVM interpreter ON TOP of EraVM for compatibility
- Moving toward Boojum 2.0 with native EVM execution
- Key insight: custom VM trades compatibility for proving efficiency

**4. Optimism (op-geth)**
- Minimal Geth fork: ~16,881 lines added, 664 deleted
- Main changes: deposit tx type (0x7E), L1 cost computation, gas params
- EVM changes minimal: +34 lines (precompile overrides, caller overrides)
- Key insight: smallest possible diff demonstrates Geth's modularity

### Geth Module Analysis

**Core modules needed for standalone EVM execution:**

| Module | Purpose | Estimated Size | Needed? |
|--------|---------|---------------|---------|
| core/vm/ | EVM interpreter, opcodes, stack, memory | ~8,000 LOC | YES - core execution engine |
| core/vm/runtime/ | Standalone EVM execution helpers | ~500 LOC | YES - Execute(), Call(), Create() |
| core/state/ | StateDB, stateObject, journal | ~5,000 LOC | YES - account/storage management |
| core/types/ | Transaction, Block, Receipt, Log | ~4,000 LOC | YES - data structures |
| ethdb/ | Database interface (LevelDB, memorydb) | ~1,000 LOC | YES - state persistence |
| params/ | Chain config, protocol params | ~2,000 LOC | YES - EVM configuration |
| crypto/ | Hashing (Keccak), signing (secp256k1) | ~1,500 LOC | YES - tx validation |
| common/ | Types (Address, Hash, Big) | ~2,000 LOC | YES - shared types |
| core/tracing/ | Tracing hooks interface | ~500 LOC | YES - trace generation |
| **Subtotal (needed)** | | **~24,500 LOC** | |

**Modules NOT needed:**

| Module | Purpose | Estimated Size | Why Not |
|--------|---------|---------------|---------|
| p2p/ | Peer-to-peer networking | ~15,000 LOC | L2 has custom networking |
| eth/ | Ethereum protocol handler | ~20,000 LOC | Full node protocol |
| les/ | Light client | ~10,000 LOC | Not applicable |
| consensus/ | PoW/PoS consensus | ~8,000 LOC | L2 uses sequencer |
| miner/ | Block mining | ~3,000 LOC | Not applicable |
| cmd/ | CLI tools | ~10,000 LOC | Custom node binary |
| internal/ | Internal APIs | ~5,000 LOC | Custom APIs |
| **Subtotal (not needed)** | | **~71,000 LOC** | |

**Estimated fork ratio: ~24,500 / ~95,500 = ~25% of core Go code**

Note: This is a rough estimate. The actual dependency graph may pull in additional modules.
In practice, the approach is to import go-ethereum as a Go module dependency and use only
the needed packages, rather than literally forking and deleting code.

### Geth Tracing System

Geth provides three tracing approaches:

1. **structLogger**: Full opcode-level trace with stack, memory, storage per step.
   Very verbose, high overhead (10-50x slowdown).

2. **callTracer**: Call-frame level tracing (CALL, CREATE, etc.).
   Lower overhead, tracks value transfers and contract interactions.

3. **Custom Go tracer**: Compiled with Geth, full access to EVM internals.
   Can selectively capture only what ZK witness generation needs.
   This is the approach production zkEVMs use.

4. **core/tracing hooks** (since Geth 1.14+): New tracing API with hooks interface.
   OnOpcode, OnStorageChange, OnBalanceChange, OnNonceChange, etc.
   Most efficient approach for building ZK-specific traces.

### Key Architectural Decision: Import vs Fork

Two strategies for using Geth's EVM:

**Strategy A: Import as Go module**
```go
import (
    "github.com/ethereum/go-ethereum/core/vm"
    "github.com/ethereum/go-ethereum/core/state"
)
```
- Pros: Easy upstream updates, no maintenance burden, clean dependency
- Cons: Cannot modify internal behavior, limited to public API
- Used by: simple L2s, application chains

**Strategy B: Fork the repository**
```
git clone github.com/ethereum/go-ethereum -> basis-geth
```
- Pros: Full control, can modify StateDB, add custom opcodes
- Cons: Merge conflicts on upstream updates, maintenance overhead
- Used by: Scroll, Polygon CDK, Optimism

**Recommendation for Basis Network**: Start with Strategy A (import as module).
The custom state management (Poseidon SMT) can be implemented as a custom StateDB
that satisfies the vm.StateDB interface. Only fork if the interface proves insufficient.

## Observations

1. **No production zkEVM uses Geth's EVM directly for proving.** All use a separate
   proving engine (C++ executor, zkASM, custom circuits). Geth's EVM role is execution
   and trace generation, not proof generation.

2. **Scroll is the closest model** to what Basis Network needs: a Geth fork that produces
   traces consumed by a separate prover. However, Scroll is moving toward OpenVM (zkVM),
   suggesting that the zktrie approach had limitations.

3. **op-geth demonstrates minimal diff is possible**: Only ~17K lines changed for a full
   L2 execution layer. Our changes may be even smaller since we only need execution + tracing,
   not full L2 protocol (deposits, L1 cost, etc.).

4. **The trace format is critical**: It must capture every state-modifying operation
   (SLOAD, SSTORE, CALL, CREATE, LOG) plus all intermediate values needed by the prover.
   Geth's new core/tracing hooks API is the cleanest approach.

5. **KECCAK256 is the dominant ZK cost**: ~150K R1CS constraints per invocation.
   Two mitigation strategies: (a) replace with Poseidon where possible, (b) use lookup
   tables with precomputed Keccak values.

## What Would Change My Mind

- If Geth's StateDB interface cannot accommodate a Poseidon SMT without forking, Strategy B
  (full fork) becomes necessary.
- If trace generation overhead exceeds 50% of execution time, a custom lightweight tracer
  or compilation approach (revmc-style) may be needed.
- If the dependency graph of core/vm pulls in too many unneeded modules, a minimal EVM
  reimplementation (like evmone) might be more practical.
