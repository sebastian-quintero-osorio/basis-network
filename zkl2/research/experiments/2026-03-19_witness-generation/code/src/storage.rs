/// Storage witness table generator.
///
/// Processes SLOAD and SSTORE trace entries, converting them to field element rows
/// for the storage constraint table. This is the most witness-intensive table because
/// each storage operation requires a full Merkle proof path.
///
/// In production, each row includes the Poseidon SMT siblings for proof verification.
/// This prototype simulates the Merkle path with placeholder siblings to accurately
/// measure witness size and generation time.
use ark_bn254::Fr;
use crate::types::{hex_to_fr, hex_to_limbs, u64_to_fr, TraceEntry, TraceOp, WitnessRow, WitnessTable};

/// SMT depth for witness size estimation.
/// Production: 160 (account trie) or 256 (storage trie).
/// Experiment default: 32 (matching RU-L4 benchmarks).
pub const DEFAULT_SMT_DEPTH: usize = 32;

/// Column layout for the storage table:
/// [global_counter, op_type, account_hash, slot_hash, value_hi, value_lo,
///  old_value_hi, old_value_lo, new_value_hi, new_value_lo,
///  sibling_0, sibling_1, ..., sibling_{depth-1}]
///
/// Total columns: 10 + depth
fn column_names(depth: usize) -> Vec<String> {
    let mut cols = vec![
        "global_counter".to_string(),
        "op_type".to_string(),
        "account_hash".to_string(),
        "slot_hash".to_string(),
        "value_hi".to_string(),
        "value_lo".to_string(),
        "old_value_hi".to_string(),
        "old_value_lo".to_string(),
        "new_value_hi".to_string(),
        "new_value_lo".to_string(),
    ];
    for i in 0..depth {
        cols.push(format!("sibling_{}", i));
    }
    cols
}

/// Operation type encoding for storage table.
const OP_SLOAD: u64 = 1;
const OP_SSTORE: u64 = 2;

/// Generate storage witness rows from a trace entry.
/// Returns rows only for SLOAD and SSTORE operations.
///
/// In production, the Merkle siblings would come from the state DB's GetProof().
/// Here we use deterministic pseudo-random siblings seeded from the slot hash
/// to ensure determinism while accurately measuring witness size.
pub fn process_entry(entry: &TraceEntry, global_counter: u64, depth: usize) -> Vec<WitnessRow> {
    match entry.op {
        TraceOp::SLOAD => {
            let account_hash = hex_to_fr(&entry.account);
            let slot_hash = hex_to_fr(&entry.slot);
            let (value_hi, value_lo) = hex_to_limbs(&entry.value);

            let mut row = vec![
                u64_to_fr(global_counter),
                u64_to_fr(OP_SLOAD),
                account_hash,
                slot_hash,
                value_hi,
                value_lo,
                Fr::from(0u64), // old_value_hi (unused for SLOAD)
                Fr::from(0u64), // old_value_lo
                Fr::from(0u64), // new_value_hi
                Fr::from(0u64), // new_value_lo
            ];

            // Simulate Merkle proof siblings (deterministic from slot)
            let siblings = generate_deterministic_siblings(slot_hash, depth);
            row.extend(siblings);

            vec![row]
        }
        TraceOp::SSTORE => {
            let account_hash = hex_to_fr(&entry.account);
            let slot_hash = hex_to_fr(&entry.slot);
            let (old_hi, old_lo) = hex_to_limbs(&entry.old_value);
            let (new_hi, new_lo) = hex_to_limbs(&entry.new_value);

            let mut row = vec![
                u64_to_fr(global_counter),
                u64_to_fr(OP_SSTORE),
                account_hash,
                slot_hash,
                Fr::from(0u64), // value (unused for SSTORE)
                Fr::from(0u64),
                old_hi,
                old_lo,
                new_hi,
                new_lo,
            ];

            // SSTORE needs TWO Merkle paths (old state and new state)
            // For witness size measurement, we generate siblings for both
            let old_siblings = generate_deterministic_siblings(slot_hash, depth);
            row.extend(old_siblings);

            // Second path encoded as additional row
            let mut row2 = vec![
                u64_to_fr(global_counter),
                u64_to_fr(OP_SSTORE + 100), // marker for second path
                account_hash,
                slot_hash,
                Fr::from(0u64),
                Fr::from(0u64),
                old_hi,
                old_lo,
                new_hi,
                new_lo,
            ];
            let new_siblings = generate_deterministic_siblings(slot_hash + Fr::from(1u64), depth);
            row2.extend(new_siblings);

            vec![row, row2]
        }
        _ => vec![],
    }
}

/// Generate deterministic pseudo-random Merkle siblings from a seed.
/// Uses repeated squaring of the seed field element to produce siblings.
/// This ensures: same seed -> same siblings (determinism requirement).
fn generate_deterministic_siblings(seed: Fr, depth: usize) -> Vec<Fr> {
    let mut siblings = Vec::with_capacity(depth);
    let mut current = seed + Fr::from(42u64); // offset to avoid trivial values
    for _ in 0..depth {
        current = current * current + Fr::from(7u64); // deterministic PRNG
        siblings.push(current);
    }
    siblings
}

/// Create a new storage witness table with the correct column layout.
pub fn new_table(depth: usize) -> WitnessTable {
    let col_names = column_names(depth);
    WitnessTable {
        name: "storage".to_string(),
        columns: col_names,
        rows: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sload_witness_depth_32() {
        let entry = TraceEntry {
            op: TraceOp::SLOAD,
            account: "0xabcdef".to_string(),
            slot: "0x01".to_string(),
            value: "0xff".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 1, 32);
        assert_eq!(rows.len(), 1);
        // 10 fixed columns + 32 siblings
        assert_eq!(rows[0].len(), 10 + 32);
    }

    #[test]
    fn test_sstore_witness_two_rows() {
        let entry = TraceEntry {
            op: TraceOp::SSTORE,
            account: "0xabcdef".to_string(),
            slot: "0x01".to_string(),
            old_value: "0x0a".to_string(),
            new_value: "0x0b".to_string(),
            ..default_entry()
        };
        let rows = process_entry(&entry, 2, 32);
        // SSTORE generates 2 rows (old path + new path)
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].len(), 10 + 32);
        assert_eq!(rows[1].len(), 10 + 32);
    }

    #[test]
    fn test_determinism() {
        let entry = TraceEntry {
            op: TraceOp::SLOAD,
            account: "0xabcdef".to_string(),
            slot: "0x42".to_string(),
            value: "0x100".to_string(),
            ..default_entry()
        };
        let rows1 = process_entry(&entry, 1, 32);
        let rows2 = process_entry(&entry, 1, 32);
        assert_eq!(rows1, rows2, "Determinism violated: same input produced different output");
    }

    fn default_entry() -> TraceEntry {
        TraceEntry {
            op: TraceOp::LOG,
            account: String::new(),
            slot: String::new(),
            value: String::new(),
            old_value: String::new(),
            new_value: String::new(),
            from: String::new(),
            to: String::new(),
            call_value: String::new(),
            prev_balance: String::new(),
            curr_balance: String::new(),
            reason: String::new(),
            prev_nonce: 0,
            curr_nonce: 0,
        }
    }
}
