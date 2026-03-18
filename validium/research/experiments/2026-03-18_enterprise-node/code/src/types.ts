// RU-V5: Enterprise Node Orchestrator -- Type Definitions
// Experimental prototype for state machine and API contract

// --- Node State Machine ---

export enum NodeState {
  Idle = 'Idle',
  Receiving = 'Receiving',
  Batching = 'Batching',
  Proving = 'Proving',
  Submitting = 'Submitting',
  Error = 'Error',
}

export enum NodeEvent {
  TransactionReceived = 'TransactionReceived',
  BatchThresholdReached = 'BatchThresholdReached',
  WitnessGenerated = 'WitnessGenerated',
  ProofGenerated = 'ProofGenerated',
  BatchSubmitted = 'BatchSubmitted',
  L1Confirmed = 'L1Confirmed',
  ErrorOccurred = 'ErrorOccurred',
  RetryRequested = 'RetryRequested',
  ShutdownRequested = 'ShutdownRequested',
}

export interface StateTransitionResult {
  previousState: NodeState;
  newState: NodeState;
  event: NodeEvent;
  timestamp: number;
  metadata?: Record<string, unknown>;
}

// --- Enterprise Transaction ---

export type TransactionType =
  | 'plasma:work_order'
  | 'plasma:completion'
  | 'plasma:inspection'
  | 'trace:sale'
  | 'trace:inventory'
  | 'trace:supplier';

export interface EnterpriseTransaction {
  txHash: string;
  enterpriseId: string;
  type: TransactionType;
  key: string;
  value: string;
  timestamp: number;
  signature: string;
}

// --- Batch ---

export interface Batch {
  batchId: string;
  enterpriseId: string;
  transactions: EnterpriseTransaction[];
  prevStateRoot: string;
  newStateRoot: string;
  createdAt: number;
}

export interface BatchWitness {
  batchId: string;
  prevStateRoot: string;
  newStateRoot: string;
  batchNum: number;
  enterpriseId: string;
  transitions: Array<{
    key: string;
    oldValue: string;
    newValue: string;
    siblings: string[];
    pathBits: number[];
    rootBefore: string;
    rootAfter: string;
  }>;
}

// --- Proof ---

export interface ZKProof {
  a: [string, string];
  b: [[string, string], [string, string]];
  c: [string, string];
  publicSignals: string[];
}

export interface ProofResult {
  proof: ZKProof;
  provingTimeMs: number;
  constraintCount: number;
}

// --- L1 Submission ---

export interface SubmissionResult {
  l1TxHash: string;
  blockNumber: number;
  gasUsed: number;
  submissionTimeMs: number;
}

// --- DAC ---

export interface DACResult {
  certificateHash: string;
  attestations: number;
  threshold: number;
  attestationTimeMs: number;
}

// --- Node Checkpoint (for crash recovery) ---

export interface NodeCheckpoint {
  smtRoot: string;
  walSequence: number;
  lastBatchId: number;
  pendingBatchId?: string;
  pendingBatchState?: 'witnessing' | 'proving' | 'submitting';
  timestamp: number;
}

// --- API Types ---

export interface SubmitTransactionRequest {
  enterpriseId: string;
  type: TransactionType;
  key: string;
  value: string;
  signature: string;
}

export interface SubmitTransactionResponse {
  txHash: string;
  accepted: boolean;
  queuePosition: number;
  timestamp: number;
}

export interface NodeStatus {
  state: NodeState;
  uptime: number;
  pendingTransactions: number;
  lastBatchId: number;
  lastStateRoot: string;
  provingInProgress: boolean;
  connectedEnterprises: number;
}

export interface BatchStatus {
  batchId: string;
  state: 'pending' | 'witnessing' | 'proving' | 'submitting' | 'confirmed' | 'failed';
  transactionCount: number;
  prevStateRoot: string;
  newStateRoot?: string;
  proofHash?: string;
  l1TxHash?: string;
  createdAt: number;
  completedAt?: number;
}

// --- WebSocket Events ---

export type WSEventType =
  | 'tx:accepted'
  | 'tx:batched'
  | 'batch:proving'
  | 'batch:proved'
  | 'batch:submitted'
  | 'batch:confirmed'
  | 'error';

export interface WSEvent {
  type: WSEventType;
  timestamp: number;
  data: Record<string, unknown>;
}

// --- Pipeline Configuration ---

export interface NodeConfig {
  batchSize: number;
  maxWaitTimeMs: number;
  provingBackend: 'snarkjs' | 'rapidsnark' | 'mock';
  circuitDepth: number;
  walPath: string;
  checkpointPath: string;
  checkpointIntervalMs: number;
  l1RpcUrl: string;
  l1ContractAddress: string;
  dacNodes: number;
  dacThreshold: number;
  apiPort: number;
  apiHost: string;
}

export const DEFAULT_CONFIG: NodeConfig = {
  batchSize: 8,
  maxWaitTimeMs: 5000,
  provingBackend: 'mock',
  circuitDepth: 32,
  walPath: './data/wal',
  checkpointPath: './data/checkpoint.json',
  checkpointIntervalMs: 60000,
  l1RpcUrl: 'https://rpc.basisnetwork.com.co',
  l1ContractAddress: '0x0000000000000000000000000000000000000000',
  dacNodes: 3,
  dacThreshold: 2,
  apiPort: 3100,
  apiHost: '0.0.0.0',
};

// --- Benchmark Results ---

export interface BenchmarkResult {
  scenario: string;
  batchSize: number;
  iterations: number;
  phases: {
    name: string;
    meanMs: number;
    stddevMs: number;
    minMs: number;
    maxMs: number;
    p95Ms: number;
  }[];
  totalMeanMs: number;
  totalStddevMs: number;
  orchestrationOverheadMs: number;
  memoryMb: number;
}
