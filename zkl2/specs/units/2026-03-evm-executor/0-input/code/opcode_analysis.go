// Package main provides an analysis of EVM opcodes classified by ZK proving difficulty.
//
// This file is a reference document embedded as Go code. It maps every Cancun EVM opcode
// to its estimated ZK constraint cost, categorizes opcodes by proving difficulty, and
// identifies which opcodes need special treatment in the Basis Network zkEVM L2.
//
// Sources:
// - Polygon zkevm-rom opcode-cost-zk-counters.md
// - Scroll zkevm-circuits specification
// - "Constraint-Level Design of zkEVMs" (arXiv:2510.05376)
// - PSE (Privacy and Scaling Explorations) zkEVM documentation
package main

import "fmt"

// ZKDifficulty classifies opcodes by proving cost.
type ZKDifficulty string

const (
	ZKTrivial  ZKDifficulty = "TRIVIAL"   // < 10 constraints, pure stack manipulation
	ZKCheap    ZKDifficulty = "CHEAP"     // 10-100 constraints, simple arithmetic
	ZKModerate ZKDifficulty = "MODERATE"  // 100-1000 constraints, memory/control flow
	ZKExpensive ZKDifficulty = "EXPENSIVE" // 1K-10K constraints, storage/hash
	ZKVeryExpensive ZKDifficulty = "VERY_EXPENSIVE" // 10K+ constraints, crypto/complex
	ZKProhibitive ZKDifficulty = "PROHIBITIVE"      // 100K+ constraints, requires special handling
)

// ZKTreatment describes how an opcode should be handled in the ZK circuit.
type ZKTreatment string

const (
	DirectProve   ZKTreatment = "DIRECT"       // Prove directly in arithmetic circuit
	LookupTable   ZKTreatment = "LOOKUP"       // Use lookup table for efficiency
	PreimageOracle ZKTreatment = "ORACLE"      // Use preimage oracle (hash precomputation)
	SpecialCircuit ZKTreatment = "SPECIAL"     // Dedicated sub-circuit required
	Replacement   ZKTreatment = "REPLACE"      // Replace with ZK-friendly alternative
	Unsupported   ZKTreatment = "UNSUPPORTED"  // Not supported in initial version
)

// OpcodeZKMapping maps an EVM opcode to its ZK proving characteristics.
type OpcodeZKMapping struct {
	Opcode         byte
	Name           string
	Category       string
	Difficulty     ZKDifficulty
	EstConstraints int    // Estimated R1CS constraints per invocation
	PLONKCost      int    // Estimated PLONKish constraints (with custom gates)
	Treatment      ZKTreatment
	Notes          string
}

// GetOpcodeMapping returns the complete mapping of Cancun EVM opcodes to ZK characteristics.
func GetOpcodeMapping() []OpcodeZKMapping {
	return []OpcodeZKMapping{
		// === STOP AND ARITHMETIC ===
		{0x00, "STOP", "control", ZKTrivial, 1, 1, DirectProve, "Halts execution"},
		{0x01, "ADD", "arithmetic", ZKCheap, 30, 3, DirectProve, "256-bit addition, bit decomposition needed in R1CS"},
		{0x02, "MUL", "arithmetic", ZKCheap, 50, 5, DirectProve, "256-bit multiplication"},
		{0x03, "SUB", "arithmetic", ZKCheap, 30, 3, DirectProve, "256-bit subtraction"},
		{0x04, "DIV", "arithmetic", ZKModerate, 200, 20, DirectProve, "Division with zero check"},
		{0x05, "SDIV", "arithmetic", ZKModerate, 250, 25, DirectProve, "Signed division"},
		{0x06, "MOD", "arithmetic", ZKModerate, 200, 20, DirectProve, "Modulo operation"},
		{0x07, "SMOD", "arithmetic", ZKModerate, 250, 25, DirectProve, "Signed modulo"},
		{0x08, "ADDMOD", "arithmetic", ZKModerate, 300, 30, DirectProve, "Addition modulo N"},
		{0x09, "MULMOD", "arithmetic", ZKModerate, 350, 35, DirectProve, "Multiplication modulo N"},
		{0x0a, "EXP", "arithmetic", ZKExpensive, 5000, 500, SpecialCircuit, "Variable-length exponentiation, dynamic cost"},
		{0x0b, "SIGNEXTEND", "arithmetic", ZKCheap, 50, 5, DirectProve, "Sign extension"},

		// === COMPARISON AND BITWISE ===
		{0x10, "LT", "comparison", ZKCheap, 30, 3, DirectProve, "Less than"},
		{0x11, "GT", "comparison", ZKCheap, 30, 3, DirectProve, "Greater than"},
		{0x12, "SLT", "comparison", ZKModerate, 100, 10, DirectProve, "Signed less than"},
		{0x13, "SGT", "comparison", ZKModerate, 100, 10, DirectProve, "Signed greater than"},
		{0x14, "EQ", "comparison", ZKCheap, 20, 2, DirectProve, "Equality"},
		{0x15, "ISZERO", "comparison", ZKCheap, 10, 1, DirectProve, "Is zero"},
		{0x16, "AND", "bitwise", ZKCheap, 30, 3, LookupTable, "Bitwise AND"},
		{0x17, "OR", "bitwise", ZKCheap, 30, 3, LookupTable, "Bitwise OR"},
		{0x18, "XOR", "bitwise", ZKCheap, 30, 3, LookupTable, "Bitwise XOR"},
		{0x19, "NOT", "bitwise", ZKCheap, 20, 2, DirectProve, "Bitwise NOT"},
		{0x1a, "BYTE", "bitwise", ZKCheap, 50, 5, LookupTable, "Extract byte"},
		{0x1b, "SHL", "bitwise", ZKModerate, 100, 10, LookupTable, "Shift left"},
		{0x1c, "SHR", "bitwise", ZKModerate, 100, 10, LookupTable, "Shift right"},
		{0x1d, "SAR", "bitwise", ZKModerate, 150, 15, LookupTable, "Signed shift right"},

		// === KECCAK256 -- THE BIG ONE ===
		{0x20, "KECCAK256", "crypto", ZKProhibitive, 150000, 50000, PreimageOracle,
			"~150K R1CS constraints for Boolean emulation. 1000x more than Poseidon. " +
				"Mitigation: preimage oracle with lookup table for known hashes. " +
				"Polygon uses cnt_arith=192, cnt_binary=193, cnt_keccak_f=2."},

		// === ENVIRONMENTAL INFORMATION ===
		{0x30, "ADDRESS", "environment", ZKTrivial, 1, 1, DirectProve, "Current address"},
		{0x31, "BALANCE", "environment", ZKExpensive, 1000, 255, SpecialCircuit, "Requires state trie access (Poseidon)"},
		{0x32, "ORIGIN", "environment", ZKTrivial, 1, 1, DirectProve, "Transaction origin"},
		{0x33, "CALLER", "environment", ZKTrivial, 1, 1, DirectProve, "Message caller"},
		{0x34, "CALLVALUE", "environment", ZKTrivial, 1, 1, DirectProve, "Call value"},
		{0x35, "CALLDATALOAD", "environment", ZKCheap, 20, 2, DirectProve, "Load calldata word"},
		{0x36, "CALLDATASIZE", "environment", ZKTrivial, 1, 1, DirectProve, "Calldata size"},
		{0x37, "CALLDATACOPY", "environment", ZKModerate, 100, 10, DirectProve, "Copy calldata to memory"},
		{0x38, "CODESIZE", "environment", ZKTrivial, 1, 1, DirectProve, "Code size"},
		{0x39, "CODECOPY", "environment", ZKModerate, 200, 20, DirectProve, "Copy code to memory"},
		{0x3a, "GASPRICE", "environment", ZKTrivial, 1, 1, DirectProve, "Gas price (always 0 on Basis L2)"},
		{0x3b, "EXTCODESIZE", "environment", ZKExpensive, 1000, 255, SpecialCircuit, "External code size, state trie access"},
		{0x3c, "EXTCODECOPY", "environment", ZKExpensive, 2000, 510, SpecialCircuit, "External code copy, double Poseidon cost"},
		{0x3d, "RETURNDATASIZE", "environment", ZKTrivial, 1, 1, DirectProve, "Return data size"},
		{0x3e, "RETURNDATACOPY", "environment", ZKModerate, 100, 10, DirectProve, "Copy return data"},
		{0x3f, "EXTCODEHASH", "environment", ZKExpensive, 1000, 255, SpecialCircuit, "External code hash, state trie access"},

		// === BLOCK INFORMATION ===
		{0x40, "BLOCKHASH", "block", ZKExpensive, 5000, 500, PreimageOracle,
			"Requires block hash oracle. Cannot compute in ZK without full block header. " +
				"Polygon: cnt_keccak_f=1, cnt_poseidon_g=9. Use lookup table."},
		{0x41, "COINBASE", "block", ZKTrivial, 1, 1, DirectProve, "Block coinbase (sequencer on L2)"},
		{0x42, "TIMESTAMP", "block", ZKTrivial, 1, 1, DirectProve, "Block timestamp"},
		{0x43, "NUMBER", "block", ZKTrivial, 1, 1, DirectProve, "Block number"},
		{0x44, "PREVRANDAO", "block", ZKTrivial, 1, 1, DirectProve, "Previous RANDAO (post-merge)"},
		{0x45, "GASLIMIT", "block", ZKTrivial, 1, 1, DirectProve, "Block gas limit"},
		{0x46, "CHAINID", "block", ZKTrivial, 1, 1, DirectProve, "Chain ID (43199 on Basis)"},
		{0x47, "SELFBALANCE", "block", ZKExpensive, 1000, 255, SpecialCircuit, "Self balance, state trie access"},
		{0x48, "BASEFEE", "block", ZKTrivial, 1, 1, DirectProve, "Base fee (0 on Basis L2)"},
		{0x49, "BLOBHASH", "block", ZKCheap, 10, 1, DirectProve, "Blob hash (Cancun, may be unused on L2)"},
		{0x4a, "BLOBBASEFEE", "block", ZKTrivial, 1, 1, DirectProve, "Blob base fee (Cancun)"},

		// === STACK, MEMORY, STORAGE ===
		{0x50, "POP", "stack", ZKTrivial, 1, 1, DirectProve, "Pop from stack"},
		{0x51, "MLOAD", "memory", ZKCheap, 20, 2, DirectProve, "Memory load"},
		{0x52, "MSTORE", "memory", ZKCheap, 20, 2, DirectProve, "Memory store"},
		{0x53, "MSTORE8", "memory", ZKCheap, 20, 2, DirectProve, "Memory store byte"},
		{0x54, "SLOAD", "storage", ZKExpensive, 2000, 255, SpecialCircuit,
			"Storage load. Requires Poseidon SMT proof (depth 32). " +
				"Polygon: cnt_poseidon_g=255. Dominates proving cost for state-heavy contracts."},
		{0x55, "SSTORE", "storage", ZKExpensive, 2000, 255, SpecialCircuit,
			"Storage store. Requires Poseidon SMT update proof. " +
				"Most expensive per-tx operation after KECCAK256. " +
				"Cold (0->nonzero) vs warm cost differs."},
		{0x56, "JUMP", "control", ZKCheap, 10, 1, DirectProve, "Jump to destination"},
		{0x57, "JUMPI", "control", ZKCheap, 20, 2, DirectProve, "Conditional jump"},
		{0x58, "PC", "control", ZKTrivial, 1, 1, DirectProve, "Program counter"},
		{0x59, "MSIZE", "memory", ZKTrivial, 1, 1, DirectProve, "Memory size"},
		{0x5a, "GAS", "control", ZKTrivial, 1, 1, DirectProve, "Remaining gas"},
		{0x5b, "JUMPDEST", "control", ZKTrivial, 1, 1, DirectProve, "Jump destination marker"},
		{0x5c, "TLOAD", "storage", ZKModerate, 100, 10, DirectProve, "Transient load (Cancun EIP-1153)"},
		{0x5d, "TSTORE", "storage", ZKModerate, 100, 10, DirectProve, "Transient store (Cancun EIP-1153)"},
		{0x5e, "MCOPY", "memory", ZKModerate, 100, 10, DirectProve, "Memory copy (Cancun EIP-5656)"},

		// === PUSH, DUP, SWAP (0x5f-0x9f) ===
		{0x5f, "PUSH0", "stack", ZKTrivial, 1, 1, DirectProve, "Push zero (Cancun)"},
		// PUSH1-PUSH32 (0x60-0x7f): all ZKTrivial, 1-2 constraints
		// DUP1-DUP16 (0x80-0x8f): all ZKTrivial, 1 constraint
		// SWAP1-SWAP16 (0x90-0x9f): all ZKTrivial, 1 constraint

		// === LOG OPERATIONS ===
		{0xa0, "LOG0", "log", ZKModerate, 200, 20, DirectProve, "Event with 0 topics"},
		{0xa1, "LOG1", "log", ZKModerate, 250, 25, DirectProve, "Event with 1 topic"},
		{0xa2, "LOG2", "log", ZKModerate, 300, 30, DirectProve, "Event with 2 topics"},
		{0xa3, "LOG3", "log", ZKModerate, 350, 35, DirectProve, "Event with 3 topics"},
		{0xa4, "LOG4", "log", ZKModerate, 400, 40, DirectProve, "Event with 4 topics"},

		// === SYSTEM OPERATIONS (MOST COMPLEX FOR ZK) ===
		{0xf0, "CREATE", "system", ZKVeryExpensive, 50000, 5000, SpecialCircuit,
			"Contract deployment. Requires address derivation, code hash, init execution. " +
				"Recursive EVM call within proof. One of the hardest opcodes for ZK."},
		{0xf1, "CALL", "system", ZKVeryExpensive, 20000, 2000, SpecialCircuit,
			"Cross-contract call. Context switch, value transfer, gas forwarding. " +
				"Requires recursive proof or stack-based proving."},
		{0xf2, "CALLCODE", "system", ZKVeryExpensive, 20000, 2000, SpecialCircuit,
			"Deprecated but must be supported for compatibility."},
		{0xf3, "RETURN", "control", ZKCheap, 20, 2, DirectProve, "Return from call"},
		{0xf4, "DELEGATECALL", "system", ZKVeryExpensive, 20000, 2000, SpecialCircuit,
			"Delegate call. Preserves caller context."},
		{0xf5, "CREATE2", "system", ZKVeryExpensive, 60000, 6000, SpecialCircuit,
			"Deterministic deployment. CREATE cost + KECCAK256 for address derivation."},
		{0xfa, "STATICCALL", "system", ZKVeryExpensive, 15000, 1500, SpecialCircuit,
			"Read-only call. Slightly cheaper than CALL (no state writes)."},
		{0xfd, "REVERT", "control", ZKCheap, 20, 2, DirectProve, "Revert with data"},
		{0xff, "SELFDESTRUCT", "system", ZKExpensive, 5000, 500, SpecialCircuit,
			"Deprecated in Cancun (EIP-6780). Only works in same-tx CREATE. " +
				"Still must be handled in circuit for compatibility."},

		// === PRECOMPILES (called via CALL to specific addresses) ===
		// These are not opcodes but are critical for ZK proving
		// 0x01: ecRecover -- ~30K constraints (secp256k1 recovery)
		// 0x02: SHA256 -- ~30K constraints
		// 0x03: RIPEMD160 -- ~30K constraints
		// 0x04: identity -- trivial (data copy)
		// 0x05: modexp -- variable, can be very expensive
		// 0x06: ecAdd (BN254) -- ~1K constraints (native to our ZK field)
		// 0x07: ecMul (BN254) -- ~5K constraints
		// 0x08: ecPairing (BN254) -- ~100K constraints per pair
		// 0x09: blake2f -- ~10K constraints
		// 0x0a: KZG point evaluation (Cancun) -- ~50K constraints
	}
}

// PrintOpcodeAnalysis outputs a formatted analysis of opcodes by ZK difficulty.
func PrintOpcodeAnalysis() {
	mapping := GetOpcodeMapping()

	categories := map[ZKDifficulty][]OpcodeZKMapping{}
	for _, m := range mapping {
		categories[m.Difficulty] = append(categories[m.Difficulty], m)
	}

	fmt.Println("=== EVM Opcode ZK Difficulty Analysis ===")
	fmt.Println()

	order := []ZKDifficulty{ZKProhibitive, ZKVeryExpensive, ZKExpensive, ZKModerate, ZKCheap, ZKTrivial}
	for _, diff := range order {
		ops := categories[diff]
		if len(ops) == 0 {
			continue
		}
		fmt.Printf("--- %s ---\n", diff)
		for _, op := range ops {
			fmt.Printf("  0x%02x %-14s %8s  R1CS: %6d  PLONK: %5d  Treatment: %-10s  %s\n",
				op.Opcode, op.Name, op.Category, op.EstConstraints, op.PLONKCost, op.Treatment, op.Notes)
		}
		fmt.Println()
	}

	// Summary statistics
	totalOps := len(mapping)
	treatmentCounts := map[ZKTreatment]int{}
	difficultyCounts := map[ZKDifficulty]int{}
	for _, m := range mapping {
		treatmentCounts[m.Treatment]++
		difficultyCounts[m.Difficulty]++
	}

	fmt.Println("=== Summary ===")
	fmt.Printf("Total opcodes analyzed: %d (+ PUSH1-32, DUP1-16, SWAP1-16 = ~140 total)\n", totalOps)
	fmt.Println()
	fmt.Println("By difficulty:")
	for _, diff := range order {
		fmt.Printf("  %-15s: %d opcodes\n", diff, difficultyCounts[diff])
	}
	fmt.Println()
	fmt.Println("By treatment:")
	fmt.Printf("  DIRECT:       %d (prove directly in circuit)\n", treatmentCounts[DirectProve])
	fmt.Printf("  LOOKUP:       %d (use lookup tables)\n", treatmentCounts[LookupTable])
	fmt.Printf("  ORACLE:       %d (preimage oracle)\n", treatmentCounts[PreimageOracle])
	fmt.Printf("  SPECIAL:      %d (dedicated sub-circuit)\n", treatmentCounts[SpecialCircuit])
	fmt.Printf("  REPLACE:      %d (replace with ZK-friendly alt)\n", treatmentCounts[Replacement])
	fmt.Printf("  UNSUPPORTED:  %d (not in initial version)\n", treatmentCounts[Unsupported])
}
