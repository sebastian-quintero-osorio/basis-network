// RU-V5: Enterprise Node Orchestrator -- State Machine
// Typed state machine with explicit transitions and guards

import { EventEmitter } from 'events';
import {
  NodeState,
  NodeEvent,
  StateTransitionResult,
} from './types';

// Valid transitions: (currentState, event) -> newState
const TRANSITION_TABLE: Map<string, NodeState> = new Map([
  // Idle transitions
  [`${NodeState.Idle}:${NodeEvent.TransactionReceived}`, NodeState.Receiving],
  [`${NodeState.Idle}:${NodeEvent.ShutdownRequested}`, NodeState.Idle],

  // Receiving transitions
  [`${NodeState.Receiving}:${NodeEvent.TransactionReceived}`, NodeState.Receiving],
  [`${NodeState.Receiving}:${NodeEvent.BatchThresholdReached}`, NodeState.Batching],
  [`${NodeState.Receiving}:${NodeEvent.ErrorOccurred}`, NodeState.Error],

  // Batching transitions
  [`${NodeState.Batching}:${NodeEvent.WitnessGenerated}`, NodeState.Proving],
  [`${NodeState.Batching}:${NodeEvent.ErrorOccurred}`, NodeState.Error],

  // Proving transitions
  [`${NodeState.Proving}:${NodeEvent.ProofGenerated}`, NodeState.Submitting],
  [`${NodeState.Proving}:${NodeEvent.ErrorOccurred}`, NodeState.Error],
  // Accept new txs while proving (pipelined model)
  [`${NodeState.Proving}:${NodeEvent.TransactionReceived}`, NodeState.Proving],

  // Submitting transitions
  [`${NodeState.Submitting}:${NodeEvent.BatchSubmitted}`, NodeState.Submitting],
  [`${NodeState.Submitting}:${NodeEvent.L1Confirmed}`, NodeState.Idle],
  [`${NodeState.Submitting}:${NodeEvent.ErrorOccurred}`, NodeState.Error],
  // Accept new txs while submitting (pipelined model)
  [`${NodeState.Submitting}:${NodeEvent.TransactionReceived}`, NodeState.Submitting],

  // Error transitions
  [`${NodeState.Error}:${NodeEvent.RetryRequested}`, NodeState.Idle],
  [`${NodeState.Error}:${NodeEvent.ShutdownRequested}`, NodeState.Idle],
]);

export class NodeStateMachine extends EventEmitter {
  private _state: NodeState = NodeState.Idle;
  private _history: StateTransitionResult[] = [];
  private _transitionCount = 0;

  get state(): NodeState {
    return this._state;
  }

  get history(): ReadonlyArray<StateTransitionResult> {
    return this._history;
  }

  get transitionCount(): number {
    return this._transitionCount;
  }

  canTransition(event: NodeEvent): boolean {
    const key = `${this._state}:${event}`;
    return TRANSITION_TABLE.has(key);
  }

  transition(event: NodeEvent, metadata?: Record<string, unknown>): StateTransitionResult {
    const key = `${this._state}:${event}`;
    const newState = TRANSITION_TABLE.get(key);

    if (newState === undefined) {
      throw new Error(
        `Invalid transition: state=${this._state}, event=${event}. ` +
        `Valid events from ${this._state}: ${this.validEvents().join(', ')}`
      );
    }

    const result: StateTransitionResult = {
      previousState: this._state,
      newState,
      event,
      timestamp: Date.now(),
      metadata,
    };

    this._state = newState;
    this._history.push(result);
    this._transitionCount++;

    this.emit('transition', result);
    this.emit(`state:${newState}`, result);

    return result;
  }

  validEvents(): NodeEvent[] {
    const events: NodeEvent[] = [];
    for (const [key] of TRANSITION_TABLE) {
      const [state, event] = key.split(':');
      if (state === this._state) {
        events.push(event as NodeEvent);
      }
    }
    return events;
  }

  reset(): void {
    this._state = NodeState.Idle;
    this._history = [];
    this._transitionCount = 0;
  }

  // Get all defined transitions for documentation/verification
  static getTransitionTable(): Array<{from: NodeState; event: NodeEvent; to: NodeState}> {
    const table: Array<{from: NodeState; event: NodeEvent; to: NodeState}> = [];
    for (const [key, to] of TRANSITION_TABLE) {
      const [from, event] = key.split(':');
      table.push({ from: from as NodeState, event: event as NodeEvent, to });
    }
    return table;
  }
}
