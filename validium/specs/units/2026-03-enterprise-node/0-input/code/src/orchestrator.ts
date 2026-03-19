// RU-V5: Enterprise Node Orchestrator -- Core Orchestrator
// Pipelined architecture: Ingestion + Batching + Proving/Submission loops

import { EventEmitter } from 'events';
import { createHash } from 'crypto';
import { NodeStateMachine } from './state-machine';
import {
  NodeState,
  NodeEvent,
  NodeConfig,
  DEFAULT_CONFIG,
  EnterpriseTransaction,
  Batch,
  BatchWitness,
  ProofResult,
  SubmissionResult,
  DACResult,
  NodeCheckpoint,
  NodeStatus,
  BatchStatus,
} from './types';

// --- Component Interfaces (pluggable) ---

export interface IStateMerkleTree {
  insert(key: string, value: string): string; // returns new root
  getRoot(): string;
  serialize(): object;
  deserialize(data: object): void;
}

export interface IBatchBuilder {
  buildBatch(batch: Batch, smt: IStateMerkleTree): Promise<BatchWitness>;
}

export interface IProver {
  prove(witness: BatchWitness): Promise<ProofResult>;
}

export interface IL1Submitter {
  submitBatch(
    enterpriseId: string,
    prevRoot: string,
    newRoot: string,
    proof: ProofResult
  ): Promise<SubmissionResult>;
}

export interface IDACProtocol {
  distributeAndAttest(batchId: string, witnessData: Buffer): Promise<DACResult>;
}

export interface ITransactionQueue {
  enqueue(tx: EnterpriseTransaction): void;
  dequeue(count: number): EnterpriseTransaction[];
  size(): number;
  checkpoint(): void;
}

// --- Mock Implementations (for Stage 1 benchmarking) ---

export class MockSMT implements IStateMerkleTree {
  private root = '0x' + '0'.repeat(64);
  private entryCount = 0;

  insert(key: string, value: string): string {
    // Simulate Poseidon hash time (~1.8ms per insert from RU-V1)
    const start = performance.now();
    // CPU-bound simulation: compute SHA-256 as stand-in for Poseidon
    for (let i = 0; i < 32; i++) {
      createHash('sha256').update(`${key}:${value}:${i}`).digest();
    }
    this.root = createHash('sha256').update(`${this.root}:${key}:${value}`).digest('hex');
    this.entryCount++;
    const elapsed = performance.now() - start;
    // Pad to match ~1.8ms if too fast
    if (elapsed < 1.0) {
      const target = 1.0 + Math.random() * 0.8;
      const spinEnd = performance.now() + (target - elapsed);
      while (performance.now() < spinEnd) { /* spin */ }
    }
    return this.root;
  }

  getRoot(): string {
    return this.root;
  }

  serialize(): object {
    return { root: this.root, entryCount: this.entryCount };
  }

  deserialize(data: object): void {
    const d = data as { root: string; entryCount: number };
    this.root = d.root;
    this.entryCount = d.entryCount;
  }
}

export class MockBatchBuilder implements IBatchBuilder {
  async buildBatch(batch: Batch, smt: IStateMerkleTree): Promise<BatchWitness> {
    // Simulate witness generation (~578ms for d32 b8 from RU-V2)
    const perTxMs = 72; // 578ms / 8 txs
    const totalMs = perTxMs * batch.transactions.length;
    await sleep(totalMs);

    return {
      batchId: batch.batchId,
      prevStateRoot: batch.prevStateRoot,
      newStateRoot: batch.newStateRoot,
      batchNum: 0,
      enterpriseId: batch.enterpriseId,
      transitions: batch.transactions.map((tx) => ({
        key: tx.key,
        oldValue: '0',
        newValue: tx.value,
        siblings: [],
        pathBits: [],
        rootBefore: batch.prevStateRoot,
        rootAfter: batch.newStateRoot,
      })),
    };
  }
}

export class MockProver implements IProver {
  constructor(private provingTimeMs: number = 12757) {} // d32 b8 snarkjs default

  async prove(witness: BatchWitness): Promise<ProofResult> {
    await sleep(this.provingTimeMs);
    return {
      proof: {
        a: ['0x1', '0x2'],
        b: [['0x3', '0x4'], ['0x5', '0x6']],
        c: ['0x7', '0x8'],
        publicSignals: [
          witness.prevStateRoot,
          witness.newStateRoot,
          String(witness.batchNum),
          witness.enterpriseId,
        ],
      },
      provingTimeMs: this.provingTimeMs,
      constraintCount: 274027,
    };
  }
}

export class MockL1Submitter implements IL1Submitter {
  async submitBatch(
    _enterpriseId: string,
    _prevRoot: string,
    _newRoot: string,
    _proof: ProofResult
  ): Promise<SubmissionResult> {
    // Simulate L1 tx submission + confirmation (~2s on Avalanche)
    await sleep(2000);
    return {
      l1TxHash: '0x' + createHash('sha256').update(String(Date.now())).digest('hex'),
      blockNumber: Math.floor(Math.random() * 1000000),
      gasUsed: 268656,
      submissionTimeMs: 2000,
    };
  }
}

export class MockDAC implements IDACProtocol {
  async distributeAndAttest(batchId: string, _witnessData: Buffer): Promise<DACResult> {
    // Simulate DAC attestation (~163ms in JS from RU-V6)
    await sleep(163);
    return {
      certificateHash: createHash('sha256').update(batchId).digest('hex'),
      attestations: 3,
      threshold: 2,
      attestationTimeMs: 163,
    };
  }
}

export class MockQueue implements ITransactionQueue {
  private queue: EnterpriseTransaction[] = [];

  enqueue(tx: EnterpriseTransaction): void {
    this.queue.push(tx);
  }

  dequeue(count: number): EnterpriseTransaction[] {
    return this.queue.splice(0, count);
  }

  size(): number {
    return this.queue.length;
  }

  checkpoint(): void {
    // Mock: no-op
  }
}

// --- Orchestrator ---

export interface OrchestratorMetrics {
  totalTransactionsReceived: number;
  totalBatchesProcessed: number;
  totalBatchesSubmitted: number;
  totalProvingTimeMs: number;
  totalOrchestrationOverheadMs: number;
  phaseTimings: Map<string, number[]>;
}

export class EnterpriseNodeOrchestrator extends EventEmitter {
  private sm: NodeStateMachine;
  private config: NodeConfig;
  private smt: IStateMerkleTree;
  private batchBuilder: IBatchBuilder;
  private prover: IProver;
  private submitter: IL1Submitter;
  private dac: IDACProtocol;
  private queue: ITransactionQueue;

  private batchCounter = 0;
  private metrics: OrchestratorMetrics;
  private running = false;
  private batchTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    config: Partial<NodeConfig> = {},
    components?: {
      smt?: IStateMerkleTree;
      batchBuilder?: IBatchBuilder;
      prover?: IProver;
      submitter?: IL1Submitter;
      dac?: IDACProtocol;
      queue?: ITransactionQueue;
    }
  ) {
    super();
    this.config = { ...DEFAULT_CONFIG, ...config };
    this.sm = new NodeStateMachine();
    this.smt = components?.smt ?? new MockSMT();
    this.batchBuilder = components?.batchBuilder ?? new MockBatchBuilder();
    this.prover = components?.prover ?? new MockProver();
    this.submitter = components?.submitter ?? new MockL1Submitter();
    this.dac = components?.dac ?? new MockDAC();
    this.queue = components?.queue ?? new MockQueue();
    this.metrics = {
      totalTransactionsReceived: 0,
      totalBatchesProcessed: 0,
      totalBatchesSubmitted: 0,
      totalProvingTimeMs: 0,
      totalOrchestrationOverheadMs: 0,
      phaseTimings: new Map(),
    };
  }

  get state(): NodeState {
    return this.sm.state;
  }

  get status(): NodeStatus {
    return {
      state: this.sm.state,
      uptime: 0,
      pendingTransactions: this.queue.size(),
      lastBatchId: this.batchCounter,
      lastStateRoot: this.smt.getRoot(),
      provingInProgress: this.sm.state === NodeState.Proving,
      connectedEnterprises: 0,
    };
  }

  getMetrics(): OrchestratorMetrics {
    return { ...this.metrics };
  }

  // --- Transaction Ingestion ---

  async submitTransaction(tx: EnterpriseTransaction): Promise<{ txHash: string; queued: boolean }> {
    const t0 = performance.now();

    this.queue.enqueue(tx);
    this.metrics.totalTransactionsReceived++;

    // Transition to Receiving if idle
    if (this.sm.state === NodeState.Idle) {
      this.sm.transition(NodeEvent.TransactionReceived);
    } else if (this.sm.canTransition(NodeEvent.TransactionReceived)) {
      this.sm.transition(NodeEvent.TransactionReceived);
    }

    this.recordPhase('ingestion', performance.now() - t0);

    // Check if batch threshold reached
    if (this.queue.size() >= this.config.batchSize) {
      // Do not await -- let the batch loop handle it
      this.processBatchCycle().catch((err) => {
        this.emit('error', err);
      });
    }

    return { txHash: tx.txHash, queued: true };
  }

  // --- Full Batch Processing Cycle ---

  async processBatchCycle(): Promise<{
    batchId: string;
    totalMs: number;
    phases: Record<string, number>;
  }> {
    const cycleStart = performance.now();
    const phases: Record<string, number> = {};

    // Phase 1: Form batch
    let t0 = performance.now();
    if (this.sm.state === NodeState.Receiving || this.sm.state === NodeState.Idle) {
      if (this.sm.state === NodeState.Idle) {
        this.sm.transition(NodeEvent.TransactionReceived);
      }
      this.sm.transition(NodeEvent.BatchThresholdReached);
    }

    const transactions = this.queue.dequeue(this.config.batchSize);
    if (transactions.length === 0) {
      throw new Error('No transactions to batch');
    }

    const prevRoot = this.smt.getRoot();
    // Apply transactions to SMT
    let newRoot = prevRoot;
    for (const tx of transactions) {
      newRoot = this.smt.insert(tx.key, tx.value);
    }

    const batchId = createHash('sha256')
      .update(transactions.map((t) => t.txHash).join(':'))
      .digest('hex')
      .substring(0, 16);

    const batch: Batch = {
      batchId,
      enterpriseId: transactions[0].enterpriseId,
      transactions,
      prevStateRoot: prevRoot,
      newStateRoot: newRoot,
      createdAt: Date.now(),
    };

    phases['batch_formation'] = performance.now() - t0;
    this.recordPhase('batch_formation', phases['batch_formation']);

    // Phase 2: Generate witness
    t0 = performance.now();
    const witness = await this.batchBuilder.buildBatch(batch, this.smt);
    phases['witness_generation'] = performance.now() - t0;
    this.recordPhase('witness_generation', phases['witness_generation']);

    // Transition to Proving
    this.sm.transition(NodeEvent.WitnessGenerated);

    // Phase 3: Generate ZK proof
    t0 = performance.now();
    const proofResult = await this.prover.prove(witness);
    phases['proving'] = performance.now() - t0;
    this.recordPhase('proving', phases['proving']);
    this.metrics.totalProvingTimeMs += proofResult.provingTimeMs;

    // Transition to Submitting
    this.sm.transition(NodeEvent.ProofGenerated);

    // Phase 4: DAC attestation
    t0 = performance.now();
    const dacResult = await this.dac.distributeAndAttest(
      batchId,
      Buffer.from(JSON.stringify(witness))
    );
    phases['dac_attestation'] = performance.now() - t0;
    this.recordPhase('dac_attestation', phases['dac_attestation']);

    // Phase 5: L1 submission
    t0 = performance.now();
    const submissionResult = await this.submitter.submitBatch(
      batch.enterpriseId,
      batch.prevStateRoot,
      batch.newStateRoot,
      proofResult
    );
    phases['l1_submission'] = performance.now() - t0;
    this.recordPhase('l1_submission', phases['l1_submission']);

    // Transition: Submitted -> Confirmed -> Idle
    this.sm.transition(NodeEvent.BatchSubmitted);
    this.sm.transition(NodeEvent.L1Confirmed);

    // Phase 6: Checkpoint
    t0 = performance.now();
    this.queue.checkpoint();
    phases['checkpoint'] = performance.now() - t0;
    this.recordPhase('checkpoint', phases['checkpoint']);

    this.batchCounter++;
    this.metrics.totalBatchesProcessed++;
    this.metrics.totalBatchesSubmitted++;

    const totalMs = performance.now() - cycleStart;
    const orchestrationOverhead =
      phases['batch_formation'] +
      phases['checkpoint'] +
      (phases['witness_generation'] ?? 0);
    this.metrics.totalOrchestrationOverheadMs += orchestrationOverhead;

    this.emit('batch:completed', {
      batchId,
      totalMs,
      phases,
      orchestrationOverhead,
      l1TxHash: submissionResult.l1TxHash,
    });

    return { batchId, totalMs, phases };
  }

  // --- Checkpoint / Recovery ---

  createCheckpoint(): NodeCheckpoint {
    return {
      smtRoot: this.smt.getRoot(),
      walSequence: 0,
      lastBatchId: this.batchCounter,
      timestamp: Date.now(),
    };
  }

  restoreFromCheckpoint(checkpoint: NodeCheckpoint): void {
    this.batchCounter = checkpoint.lastBatchId;
    // In production: deserialize SMT from checkpoint.smtSnapshot
    // For prototype: just reset state machine
    this.sm.reset();
  }

  // --- Graceful Shutdown ---

  async shutdown(): Promise<void> {
    this.running = false;
    if (this.batchTimer) {
      clearTimeout(this.batchTimer);
      this.batchTimer = null;
    }
    // Flush pending work
    this.queue.checkpoint();
    this.emit('shutdown');
  }

  // --- Helpers ---

  private recordPhase(name: string, ms: number): void {
    if (!this.metrics.phaseTimings.has(name)) {
      this.metrics.phaseTimings.set(name, []);
    }
    this.metrics.phaseTimings.get(name)!.push(ms);
  }
}

// --- Utility ---

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
