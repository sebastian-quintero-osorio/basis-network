// RU-V5: Enterprise Node Orchestrator -- State Machine Tests
// Validates all transitions, guards, and invariants

import { NodeStateMachine } from './state-machine';
import { NodeState, NodeEvent } from './types';

let passed = 0;
let failed = 0;

function assert(condition: boolean, message: string): void {
  if (condition) {
    passed++;
  } else {
    failed++;
    console.error(`  FAIL: ${message}`);
  }
}

function assertThrows(fn: () => void, message: string): void {
  try {
    fn();
    failed++;
    console.error(`  FAIL: ${message} (expected throw)`);
  } catch {
    passed++;
  }
}

// --- Test: Initial State ---
console.log('Test: Initial state');
{
  const sm = new NodeStateMachine();
  assert(sm.state === NodeState.Idle, 'Initial state should be Idle');
  assert(sm.transitionCount === 0, 'No transitions yet');
  assert(sm.history.length === 0, 'Empty history');
}

// --- Test: Happy Path (full cycle) ---
console.log('Test: Happy path cycle');
{
  const sm = new NodeStateMachine();

  // Idle -> Receiving
  sm.transition(NodeEvent.TransactionReceived);
  assert(sm.state === NodeState.Receiving, 'After tx received: Receiving');

  // Receiving -> Batching
  sm.transition(NodeEvent.BatchThresholdReached);
  assert(sm.state === NodeState.Batching, 'After threshold: Batching');

  // Batching -> Proving
  sm.transition(NodeEvent.WitnessGenerated);
  assert(sm.state === NodeState.Proving, 'After witness: Proving');

  // Proving -> Submitting
  sm.transition(NodeEvent.ProofGenerated);
  assert(sm.state === NodeState.Submitting, 'After proof: Submitting');

  // Submitting -> Submitting (batch submitted, awaiting confirmation)
  sm.transition(NodeEvent.BatchSubmitted);
  assert(sm.state === NodeState.Submitting, 'After batch submitted: still Submitting');

  // Submitting -> Idle (confirmed)
  sm.transition(NodeEvent.L1Confirmed);
  assert(sm.state === NodeState.Idle, 'After L1 confirmed: Idle');

  assert(sm.transitionCount === 6, 'Six transitions in happy path');
}

// --- Test: Pipelined receiving (accept txs while proving) ---
console.log('Test: Pipelined receiving during proving');
{
  const sm = new NodeStateMachine();
  sm.transition(NodeEvent.TransactionReceived);
  sm.transition(NodeEvent.BatchThresholdReached);
  sm.transition(NodeEvent.WitnessGenerated);
  assert(sm.state === NodeState.Proving, 'In Proving state');

  // Should accept new transactions while proving
  sm.transition(NodeEvent.TransactionReceived);
  assert(sm.state === NodeState.Proving, 'Still Proving after receiving tx');

  sm.transition(NodeEvent.ProofGenerated);
  assert(sm.state === NodeState.Submitting, 'Submitting after proof');

  // Should accept new transactions while submitting
  sm.transition(NodeEvent.TransactionReceived);
  assert(sm.state === NodeState.Submitting, 'Still Submitting after receiving tx');
}

// --- Test: Multiple receives before threshold ---
console.log('Test: Multiple receives before batch threshold');
{
  const sm = new NodeStateMachine();
  sm.transition(NodeEvent.TransactionReceived);
  sm.transition(NodeEvent.TransactionReceived);
  sm.transition(NodeEvent.TransactionReceived);
  assert(sm.state === NodeState.Receiving, 'Still Receiving after 3 txs');
  assert(sm.transitionCount === 3, 'Three transitions');
}

// --- Test: Error from Receiving ---
console.log('Test: Error from Receiving');
{
  const sm = new NodeStateMachine();
  sm.transition(NodeEvent.TransactionReceived);
  sm.transition(NodeEvent.ErrorOccurred);
  assert(sm.state === NodeState.Error, 'Error from Receiving');

  sm.transition(NodeEvent.RetryRequested);
  assert(sm.state === NodeState.Idle, 'Retry returns to Idle');
}

// --- Test: Error from Batching ---
console.log('Test: Error from Batching');
{
  const sm = new NodeStateMachine();
  sm.transition(NodeEvent.TransactionReceived);
  sm.transition(NodeEvent.BatchThresholdReached);
  sm.transition(NodeEvent.ErrorOccurred);
  assert(sm.state === NodeState.Error, 'Error from Batching');
}

// --- Test: Error from Proving ---
console.log('Test: Error from Proving');
{
  const sm = new NodeStateMachine();
  sm.transition(NodeEvent.TransactionReceived);
  sm.transition(NodeEvent.BatchThresholdReached);
  sm.transition(NodeEvent.WitnessGenerated);
  sm.transition(NodeEvent.ErrorOccurred);
  assert(sm.state === NodeState.Error, 'Error from Proving');
}

// --- Test: Error from Submitting ---
console.log('Test: Error from Submitting');
{
  const sm = new NodeStateMachine();
  sm.transition(NodeEvent.TransactionReceived);
  sm.transition(NodeEvent.BatchThresholdReached);
  sm.transition(NodeEvent.WitnessGenerated);
  sm.transition(NodeEvent.ProofGenerated);
  sm.transition(NodeEvent.ErrorOccurred);
  assert(sm.state === NodeState.Error, 'Error from Submitting');
}

// --- Test: Invalid transitions ---
console.log('Test: Invalid transitions');
{
  const sm = new NodeStateMachine();

  // Cannot go from Idle to Proving
  assertThrows(
    () => sm.transition(NodeEvent.ProofGenerated),
    'Idle -> ProofGenerated should throw'
  );

  // Cannot go from Idle to Batching
  assertThrows(
    () => sm.transition(NodeEvent.BatchThresholdReached),
    'Idle -> BatchThresholdReached should throw'
  );

  // Cannot go from Idle to Submitting
  assertThrows(
    () => sm.transition(NodeEvent.BatchSubmitted),
    'Idle -> BatchSubmitted should throw'
  );
}

// --- Test: canTransition guard ---
console.log('Test: canTransition guard');
{
  const sm = new NodeStateMachine();
  assert(sm.canTransition(NodeEvent.TransactionReceived), 'Idle can receive tx');
  assert(!sm.canTransition(NodeEvent.ProofGenerated), 'Idle cannot generate proof');
  assert(!sm.canTransition(NodeEvent.BatchThresholdReached), 'Idle cannot batch');
  assert(sm.canTransition(NodeEvent.ShutdownRequested), 'Idle can shutdown');
}

// --- Test: Event emitter ---
console.log('Test: Event emitter');
{
  const sm = new NodeStateMachine();
  let transitionEmitted = false;
  let stateEmitted = false;

  sm.on('transition', () => { transitionEmitted = true; });
  sm.on('state:Receiving', () => { stateEmitted = true; });

  sm.transition(NodeEvent.TransactionReceived);
  assert(transitionEmitted, 'Transition event emitted');
  assert(stateEmitted, 'State-specific event emitted');
}

// --- Test: History tracking ---
console.log('Test: History tracking');
{
  const sm = new NodeStateMachine();
  sm.transition(NodeEvent.TransactionReceived);
  sm.transition(NodeEvent.BatchThresholdReached);
  sm.transition(NodeEvent.WitnessGenerated);

  assert(sm.history.length === 3, 'History has 3 entries');
  assert(sm.history[0].previousState === NodeState.Idle, 'First entry from Idle');
  assert(sm.history[0].newState === NodeState.Receiving, 'First entry to Receiving');
  assert(sm.history[2].newState === NodeState.Proving, 'Third entry to Proving');
}

// --- Test: Reset ---
console.log('Test: Reset');
{
  const sm = new NodeStateMachine();
  sm.transition(NodeEvent.TransactionReceived);
  sm.transition(NodeEvent.BatchThresholdReached);
  sm.reset();
  assert(sm.state === NodeState.Idle, 'Reset returns to Idle');
  assert(sm.transitionCount === 0, 'Reset clears count');
  assert(sm.history.length === 0, 'Reset clears history');
}

// --- Test: Transition table completeness ---
console.log('Test: Transition table completeness');
{
  const table = NodeStateMachine.getTransitionTable();
  assert(table.length > 0, 'Transition table is not empty');

  // Every state should have at least one outgoing transition
  const statesWithOutgoing = new Set(table.map((t) => t.from));
  for (const state of Object.values(NodeState)) {
    assert(statesWithOutgoing.has(state), `State ${state} has outgoing transitions`);
  }
}

// --- Test: Metadata in transitions ---
console.log('Test: Metadata in transitions');
{
  const sm = new NodeStateMachine();
  sm.transition(NodeEvent.TransactionReceived, { txCount: 5, source: 'PLASMA' });
  assert(sm.history[0].metadata?.txCount === 5, 'Metadata preserved');
  assert(sm.history[0].metadata?.source === 'PLASMA', 'Metadata source preserved');
}

// --- Summary ---
console.log(`\n=== STATE MACHINE TESTS: ${passed} passed, ${failed} failed ===`);
if (failed > 0) {
  process.exit(1);
}
