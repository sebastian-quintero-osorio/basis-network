package executor

import (
	"github.com/ethereum/go-ethereum/core/vm"
)

// ZKDifficulty classifies how expensive an EVM opcode is to prove in a ZK circuit.
// The classification is derived from R1CS constraint counts and Poseidon hash operations
// measured across production zkEVM implementations (Polygon zkEVM, Scroll, zkSync Era).
//
// [Spec: OpcodeSet in EvmExecutor.tla -- 5 representative opcodes across difficulty tiers]
// [Source: 0-input/code/opcode_analysis.go -- ZK difficulty classification]
// [Source: 0-input/REPORT.md -- Polygon zkEVM ZK Counter Costs]
type ZKDifficulty int

const (
	// ZKTrivial represents opcodes with ~1 R1CS constraint.
	// Stack manipulation and constants: no arithmetic, no state access.
	// Examples: STOP, POP, PUSH0-32, DUP1-16, SWAP1-16, JUMPDEST.
	ZKTrivial ZKDifficulty = iota

	// ZKCheap represents opcodes with ~30 R1CS constraints.
	// 256-bit arithmetic requiring bit decomposition and range checks.
	// Examples: ADD, SUB, MUL, DIV, MOD, LT, GT, EQ, AND, OR, XOR, NOT.
	// [Spec: OpcodeSet -- ADD modeled as ZKCheap, ~30 R1CS constraints]
	ZKCheap

	// ZKModerate represents opcodes with ~50-100 R1CS constraints.
	// Memory operations, calldata access, and block context reads.
	// Examples: MLOAD, MSTORE, CALLDATALOAD, JUMP, JUMPI, LOG0-4.
	ZKModerate

	// ZKExpensive represents opcodes with ~255 Poseidon operations.
	// State trie access requiring Merkle proof traversal.
	// Examples: SLOAD, SSTORE, BALANCE, EXTCODESIZE, EXTCODEHASH.
	// [Spec: OpcodeSet -- SLOAD/SSTORE modeled as ZKExpensive, ~255 Poseidon ops]
	ZKExpensive

	// ZKVeryExpensive represents opcodes with ~20K+ R1CS constraints.
	// Cross-contract calls requiring context switches and stack frame management.
	// Examples: CALL, CALLCODE, DELEGATECALL, STATICCALL, CREATE, CREATE2.
	// [Spec: OpcodeSet -- CALL modeled as ZKVeryExpensive, ~20K R1CS constraints]
	ZKVeryExpensive

	// ZKCritical represents opcodes with ~150K+ R1CS constraints.
	// Cryptographic operations that dominate proving time.
	// Examples: KECCAK256 (SHA3). 1000x more expensive than Poseidon.
	// [Source: 0-input/REPORT.md -- "KECCAK256 is the dominant ZK cost"]
	ZKCritical
)

// String returns the human-readable name of a ZK difficulty level.
func (d ZKDifficulty) String() string {
	switch d {
	case ZKTrivial:
		return "trivial"
	case ZKCheap:
		return "cheap"
	case ZKModerate:
		return "moderate"
	case ZKExpensive:
		return "expensive"
	case ZKVeryExpensive:
		return "very_expensive"
	case ZKCritical:
		return "critical"
	default:
		return "unknown"
	}
}

// OpcodeInfo describes the ZK proving characteristics of a single EVM opcode.
type OpcodeInfo struct {
	// Difficulty is the ZK proving difficulty classification.
	Difficulty ZKDifficulty

	// EstimatedConstraints is the approximate R1CS constraint count for this opcode.
	// Zero means the constraint count is dynamic or not yet measured.
	EstimatedConstraints int

	// StateModifying indicates whether this opcode modifies blockchain state
	// (storage, balances, nonces) and therefore generates a trace entry.
	StateModifying bool

	// Description explains why this opcode has its difficulty classification.
	Description string
}

// zkDifficultyMap classifies every Cancun EVM opcode by ZK proving difficulty.
// This map is the authoritative source for opcode cost estimation in the Basis
// Network prover pipeline.
//
// [Source: 0-input/code/opcode_analysis.go -- Opcode ZK difficulty classification]
// [Source: 0-input/REPORT.md -- Polygon zkEVM ZK Counter Costs table]
var zkDifficultyMap = map[vm.OpCode]OpcodeInfo{
	// --- ZKTrivial: ~1 constraint ---
	// Stack manipulation and constants. No computation, no state access.
	vm.STOP:     {ZKTrivial, 1, false, "halts execution"},
	vm.POP:      {ZKTrivial, 1, false, "discards stack top"},
	vm.JUMPDEST: {ZKTrivial, 1, false, "marks valid jump target"},
	vm.PUSH0:    {ZKTrivial, 1, false, "pushes zero constant"},
	vm.PUSH1:    {ZKTrivial, 1, false, "pushes 1-byte constant"},
	vm.PUSH2:    {ZKTrivial, 1, false, "pushes 2-byte constant"},
	vm.PUSH3:    {ZKTrivial, 1, false, "pushes 3-byte constant"},
	vm.PUSH4:    {ZKTrivial, 1, false, "pushes 4-byte constant"},
	vm.PUSH5:    {ZKTrivial, 1, false, "pushes 5-byte constant"},
	vm.PUSH6:    {ZKTrivial, 1, false, "pushes 6-byte constant"},
	vm.PUSH7:    {ZKTrivial, 1, false, "pushes 7-byte constant"},
	vm.PUSH8:    {ZKTrivial, 1, false, "pushes 8-byte constant"},
	vm.PUSH9:    {ZKTrivial, 1, false, "pushes 9-byte constant"},
	vm.PUSH10:   {ZKTrivial, 1, false, "pushes 10-byte constant"},
	vm.PUSH11:   {ZKTrivial, 1, false, "pushes 11-byte constant"},
	vm.PUSH12:   {ZKTrivial, 1, false, "pushes 12-byte constant"},
	vm.PUSH13:   {ZKTrivial, 1, false, "pushes 13-byte constant"},
	vm.PUSH14:   {ZKTrivial, 1, false, "pushes 14-byte constant"},
	vm.PUSH15:   {ZKTrivial, 1, false, "pushes 15-byte constant"},
	vm.PUSH16:   {ZKTrivial, 1, false, "pushes 16-byte constant"},
	vm.PUSH17:   {ZKTrivial, 1, false, "pushes 17-byte constant"},
	vm.PUSH18:   {ZKTrivial, 1, false, "pushes 18-byte constant"},
	vm.PUSH19:   {ZKTrivial, 1, false, "pushes 19-byte constant"},
	vm.PUSH20:   {ZKTrivial, 1, false, "pushes 20-byte constant"},
	vm.PUSH21:   {ZKTrivial, 1, false, "pushes 21-byte constant"},
	vm.PUSH22:   {ZKTrivial, 1, false, "pushes 22-byte constant"},
	vm.PUSH23:   {ZKTrivial, 1, false, "pushes 23-byte constant"},
	vm.PUSH24:   {ZKTrivial, 1, false, "pushes 24-byte constant"},
	vm.PUSH25:   {ZKTrivial, 1, false, "pushes 25-byte constant"},
	vm.PUSH26:   {ZKTrivial, 1, false, "pushes 26-byte constant"},
	vm.PUSH27:   {ZKTrivial, 1, false, "pushes 27-byte constant"},
	vm.PUSH28:   {ZKTrivial, 1, false, "pushes 28-byte constant"},
	vm.PUSH29:   {ZKTrivial, 1, false, "pushes 29-byte constant"},
	vm.PUSH30:   {ZKTrivial, 1, false, "pushes 30-byte constant"},
	vm.PUSH31:   {ZKTrivial, 1, false, "pushes 31-byte constant"},
	vm.PUSH32:   {ZKTrivial, 1, false, "pushes 32-byte constant"},
	vm.DUP1:     {ZKTrivial, 1, false, "duplicates 1st stack element"},
	vm.DUP2:     {ZKTrivial, 1, false, "duplicates 2nd stack element"},
	vm.DUP3:     {ZKTrivial, 1, false, "duplicates 3rd stack element"},
	vm.DUP4:     {ZKTrivial, 1, false, "duplicates 4th stack element"},
	vm.DUP5:     {ZKTrivial, 1, false, "duplicates 5th stack element"},
	vm.DUP6:     {ZKTrivial, 1, false, "duplicates 6th stack element"},
	vm.DUP7:     {ZKTrivial, 1, false, "duplicates 7th stack element"},
	vm.DUP8:     {ZKTrivial, 1, false, "duplicates 8th stack element"},
	vm.DUP9:     {ZKTrivial, 1, false, "duplicates 9th stack element"},
	vm.DUP10:    {ZKTrivial, 1, false, "duplicates 10th stack element"},
	vm.DUP11:    {ZKTrivial, 1, false, "duplicates 11th stack element"},
	vm.DUP12:    {ZKTrivial, 1, false, "duplicates 12th stack element"},
	vm.DUP13:    {ZKTrivial, 1, false, "duplicates 13th stack element"},
	vm.DUP14:    {ZKTrivial, 1, false, "duplicates 14th stack element"},
	vm.DUP15:    {ZKTrivial, 1, false, "duplicates 15th stack element"},
	vm.DUP16:    {ZKTrivial, 1, false, "duplicates 16th stack element"},
	vm.SWAP1:    {ZKTrivial, 1, false, "swaps top with 2nd element"},
	vm.SWAP2:    {ZKTrivial, 1, false, "swaps top with 3rd element"},
	vm.SWAP3:    {ZKTrivial, 1, false, "swaps top with 4th element"},
	vm.SWAP4:    {ZKTrivial, 1, false, "swaps top with 5th element"},
	vm.SWAP5:    {ZKTrivial, 1, false, "swaps top with 6th element"},
	vm.SWAP6:    {ZKTrivial, 1, false, "swaps top with 7th element"},
	vm.SWAP7:    {ZKTrivial, 1, false, "swaps top with 8th element"},
	vm.SWAP8:    {ZKTrivial, 1, false, "swaps top with 9th element"},
	vm.SWAP9:    {ZKTrivial, 1, false, "swaps top with 10th element"},
	vm.SWAP10:   {ZKTrivial, 1, false, "swaps top with 11th element"},
	vm.SWAP11:   {ZKTrivial, 1, false, "swaps top with 12th element"},
	vm.SWAP12:   {ZKTrivial, 1, false, "swaps top with 13th element"},
	vm.SWAP13:   {ZKTrivial, 1, false, "swaps top with 14th element"},
	vm.SWAP14:   {ZKTrivial, 1, false, "swaps top with 15th element"},
	vm.SWAP15:   {ZKTrivial, 1, false, "swaps top with 16th element"},
	vm.SWAP16:   {ZKTrivial, 1, false, "swaps top with 17th element"},
	vm.RETURN:   {ZKTrivial, 1, false, "returns output data"},
	vm.REVERT:   {ZKTrivial, 1, false, "reverts with output data"},
	vm.INVALID:  {ZKTrivial, 1, false, "designated invalid opcode"},

	// --- ZKCheap: ~30 R1CS constraints ---
	// 256-bit arithmetic and comparison. Requires bit decomposition and range checks.
	// [Spec: OpcodeSet -- ADD modeled in this tier]
	vm.ADD:        {ZKCheap, 30, false, "256-bit addition"},
	vm.SUB:        {ZKCheap, 30, false, "256-bit subtraction"},
	vm.MUL:        {ZKCheap, 50, false, "256-bit multiplication"},
	vm.DIV:        {ZKCheap, 50, false, "256-bit unsigned division"},
	vm.SDIV:       {ZKCheap, 60, false, "256-bit signed division"},
	vm.MOD:        {ZKCheap, 50, false, "256-bit modulo"},
	vm.SMOD:       {ZKCheap, 60, false, "256-bit signed modulo"},
	vm.ADDMOD:     {ZKCheap, 60, false, "modular addition"},
	vm.MULMOD:     {ZKCheap, 80, false, "modular multiplication"},
	vm.EXP:        {ZKCheap, 100, false, "exponentiation (variable cost)"},
	vm.SIGNEXTEND: {ZKCheap, 30, false, "sign extension"},
	vm.LT:         {ZKCheap, 30, false, "unsigned less-than"},
	vm.GT:         {ZKCheap, 30, false, "unsigned greater-than"},
	vm.SLT:        {ZKCheap, 30, false, "signed less-than"},
	vm.SGT:        {ZKCheap, 30, false, "signed greater-than"},
	vm.EQ:         {ZKCheap, 30, false, "equality"},
	vm.ISZERO:     {ZKCheap, 10, false, "zero check"},
	vm.AND:        {ZKCheap, 30, false, "bitwise AND"},
	vm.OR:         {ZKCheap, 30, false, "bitwise OR"},
	vm.XOR:        {ZKCheap, 30, false, "bitwise XOR"},
	vm.NOT:        {ZKCheap, 30, false, "bitwise NOT"},
	vm.BYTE:       {ZKCheap, 30, false, "byte extraction"},
	vm.SHL:        {ZKCheap, 30, false, "shift left"},
	vm.SHR:        {ZKCheap, 30, false, "shift right"},
	vm.SAR:        {ZKCheap, 40, false, "arithmetic shift right"},

	// --- ZKModerate: ~50-100 R1CS constraints ---
	// Memory operations, calldata access, block context, control flow, and logs.
	vm.MLOAD:          {ZKModerate, 50, false, "memory load (32 bytes)"},
	vm.MSTORE:         {ZKModerate, 50, false, "memory store (32 bytes)"},
	vm.MSTORE8:        {ZKModerate, 50, false, "memory store (1 byte)"},
	vm.MSIZE:          {ZKModerate, 10, false, "memory size"},
	vm.MCOPY:          {ZKModerate, 50, false, "memory copy (EIP-5656)"},
	vm.CALLDATALOAD:   {ZKModerate, 50, false, "load 32 bytes from calldata"},
	vm.CALLDATASIZE:   {ZKModerate, 10, false, "calldata size"},
	vm.CALLDATACOPY:   {ZKModerate, 50, false, "copy calldata to memory"},
	vm.CODESIZE:       {ZKModerate, 10, false, "code size"},
	vm.CODECOPY:       {ZKModerate, 50, false, "copy code to memory"},
	vm.RETURNDATASIZE: {ZKModerate, 10, false, "return data size"},
	vm.RETURNDATACOPY: {ZKModerate, 50, false, "copy return data to memory"},
	vm.JUMP:           {ZKModerate, 20, false, "unconditional jump"},
	vm.JUMPI:          {ZKModerate, 20, false, "conditional jump"},
	vm.PC:             {ZKModerate, 10, false, "program counter"},
	vm.GAS:            {ZKModerate, 10, false, "remaining gas"},
	vm.ADDRESS:        {ZKModerate, 10, false, "executing account address"},
	vm.ORIGIN:         {ZKModerate, 10, false, "transaction origin"},
	vm.CALLER:         {ZKModerate, 10, false, "direct caller"},
	vm.CALLVALUE:      {ZKModerate, 10, false, "transferred value"},
	vm.GASPRICE:       {ZKModerate, 10, false, "gas price"},
	vm.NUMBER:         {ZKModerate, 10, false, "block number"},
	vm.TIMESTAMP:      {ZKModerate, 10, false, "block timestamp"},
	vm.DIFFICULTY:     {ZKModerate, 10, false, "block difficulty (0 post-merge)"},
	vm.GASLIMIT:       {ZKModerate, 10, false, "block gas limit"},
	vm.CHAINID:        {ZKModerate, 10, false, "chain ID"},
	vm.SELFBALANCE:    {ZKModerate, 50, false, "balance of executing account"},
	vm.BASEFEE:        {ZKModerate, 10, false, "block base fee"},
	vm.BLOBHASH:       {ZKModerate, 10, false, "blob versioned hash (EIP-4844)"},
	vm.BLOBBASEFEE:    {ZKModerate, 10, false, "blob base fee (EIP-4844)"},
	vm.COINBASE:       {ZKModerate, 10, false, "block coinbase address"},
	vm.TLOAD:          {ZKModerate, 50, false, "transient storage load (EIP-1153)"},
	vm.TSTORE:         {ZKModerate, 50, false, "transient storage store (EIP-1153)"},
	vm.LOG0:           {ZKModerate, 50, false, "log with 0 topics"},
	vm.LOG1:           {ZKModerate, 60, false, "log with 1 topic"},
	vm.LOG2:           {ZKModerate, 70, false, "log with 2 topics"},
	vm.LOG3:           {ZKModerate, 80, false, "log with 3 topics"},
	vm.LOG4:           {ZKModerate, 90, false, "log with 4 topics"},

	// --- ZKExpensive: ~255 Poseidon operations ---
	// State trie access. Each operation requires traversing the Poseidon sparse
	// Merkle tree, generating or verifying an inclusion/update proof.
	// [Spec: SLOAD/SSTORE modeled in this tier]
	// [Source: Polygon zkEVM cnt_poseidon_g = 255 for SLOAD/SSTORE]
	vm.SLOAD:       {ZKExpensive, 255, true, "storage load (Poseidon SMT inclusion proof)"},
	vm.SSTORE:      {ZKExpensive, 255, true, "storage store (Poseidon SMT update proof)"},
	vm.BALANCE:     {ZKExpensive, 255, false, "account balance (trie traversal)"},
	vm.EXTCODESIZE: {ZKExpensive, 255, false, "external code size (trie traversal)"},
	vm.EXTCODECOPY: {ZKExpensive, 510, false, "external code copy (double Poseidon cost)"},
	vm.EXTCODEHASH: {ZKExpensive, 255, false, "external code hash (trie traversal)"},
	vm.BLOCKHASH:   {ZKExpensive, 100, false, "block hash (requires hash oracle)"},

	// --- ZKVeryExpensive: ~20K+ R1CS constraints ---
	// Cross-contract calls and contract creation. Each requires a full context
	// switch with stack frame management, address derivation, or code deployment.
	// [Spec: CALL modeled in this tier]
	vm.CALL:         {ZKVeryExpensive, 20000, true, "external call with value transfer"},
	vm.CALLCODE:     {ZKVeryExpensive, 20000, true, "call with caller's storage"},
	vm.DELEGATECALL: {ZKVeryExpensive, 20000, false, "delegate call (no value transfer)"},
	vm.STATICCALL:   {ZKVeryExpensive, 20000, false, "static call (read-only)"},
	vm.CREATE:       {ZKVeryExpensive, 30000, true, "contract creation"},
	vm.CREATE2:      {ZKVeryExpensive, 30000, true, "deterministic contract creation"},
	vm.SELFDESTRUCT: {ZKVeryExpensive, 25000, true, "contract destruction + value transfer"},

	// --- ZKCritical: ~150K+ R1CS constraints ---
	// KECCAK256 dominates ZK proving cost. Boolean logic emulation of the Keccak
	// permutation requires ~150K R1CS constraints per invocation -- 1000x more
	// expensive than Poseidon hashing.
	// [Source: 0-input/REPORT.md -- "KECCAK256 is the dominant ZK cost"]
	vm.KECCAK256: {ZKCritical, 150000, false, "Keccak-256 hash (dominant ZK cost)"},
}

// GetOpcodeInfo returns the ZK proving characteristics of an EVM opcode.
// Returns a zero-value OpcodeInfo if the opcode is not classified.
func GetOpcodeInfo(op vm.OpCode) (OpcodeInfo, bool) {
	info, ok := zkDifficultyMap[op]
	return info, ok
}

// GetZKDifficulty returns the ZK difficulty classification of an EVM opcode.
// Returns ZKModerate as default for unclassified opcodes (conservative estimate).
func GetZKDifficulty(op vm.OpCode) ZKDifficulty {
	if info, ok := zkDifficultyMap[op]; ok {
		return info.Difficulty
	}
	return ZKModerate
}

// IsStateModifying returns whether an opcode modifies blockchain state and
// therefore generates a trace entry for the ZK prover.
func IsStateModifying(op vm.OpCode) bool {
	if info, ok := zkDifficultyMap[op]; ok {
		return info.StateModifying
	}
	return false
}

// IsZKProblematic returns true if the opcode is expensive or critical for ZK proving.
// Use this to identify opcodes that may bottleneck batch proving time.
func IsZKProblematic(op vm.OpCode) bool {
	d := GetZKDifficulty(op)
	return d >= ZKExpensive
}

// EstimateConstraints returns the estimated R1CS constraint count for an opcode.
// Returns 0 if the opcode is not classified.
func EstimateConstraints(op vm.OpCode) int {
	if info, ok := zkDifficultyMap[op]; ok {
		return info.EstimatedConstraints
	}
	return 0
}
