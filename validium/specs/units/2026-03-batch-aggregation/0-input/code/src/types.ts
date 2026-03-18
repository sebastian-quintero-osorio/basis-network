/// Transaction representation for the enterprise validium node queue.
/// Each transaction represents a state transition in the Sparse Merkle Tree.
export interface Transaction {
  txHash: string;
  key: string;
  oldValue: string;
  newValue: string;
  enterpriseId: string;
  timestamp: number;
}

/// WAL entry: a transaction plus sequencing metadata and integrity checksum.
export interface WALEntry {
  seq: number;
  timestamp: number;
  tx: Transaction;
  checksum: string;
}

/// Checkpoint marker in the WAL indicating a batch was committed.
export interface WALCheckpoint {
  type: "checkpoint";
  seq: number;
  batchId: string;
  timestamp: number;
}

/// A formed batch ready for circuit proving.
export interface Batch {
  batchId: string;
  batchNum: number;
  enterpriseId: string;
  transactions: Transaction[];
  formedAt: number;
  formationLatencyMs: number;
  strategy: AggregationStrategy;
}

/// Circuit input derived from a batch (matches state_transition.circom).
export interface CircuitInput {
  prevStateRoot: string;
  newStateRoot: string;
  batchNum: number;
  enterpriseId: string;
  txKeys: string[];
  txOldValues: string[];
  txNewValues: string[];
}

export type AggregationStrategy = "SIZE" | "TIME" | "HYBRID";

export interface BatchAggregatorConfig {
  strategy: AggregationStrategy;
  sizeThreshold: number;
  timeThresholdMs: number;
  maxBatchSize: number;
}

export interface QueueConfig {
  walPath: string;
  fsyncPerEntry: boolean;
  groupCommitSize: number;
}

export interface BenchmarkConfig {
  arrivalRate: number;
  durationMs: number;
  warmupBatches: number;
  replications: number;
  queueConfig: QueueConfig;
  batchConfig: BatchAggregatorConfig;
}

export interface BenchmarkResult {
  config: BenchmarkConfig;
  throughputTxPerMin: number;
  avgBatchFormationLatencyMs: number;
  p95BatchFormationLatencyMs: number;
  p99BatchFormationLatencyMs: number;
  avgWalWriteLatencyUs: number;
  p95WalWriteLatencyUs: number;
  batchesFormed: number;
  totalTxProcessed: number;
  memoryUsageBytes: number;
  txLossCount: number;
  deterministic: boolean;
}
