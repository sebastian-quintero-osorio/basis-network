/**
 * Transaction Queue module -- persistent FIFO queue with WAL-based crash recovery.
 *
 * [Spec: validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla]
 *
 * @module queue
 */

export { TransactionQueue } from "./transaction-queue";
export { WriteAheadLog } from "./wal";
export {
  type Transaction,
  type WALEntry,
  type WALCheckpoint,
  type WALConfig,
  type DequeueResult,
  QueueError,
  QueueErrorCode,
} from "./types";
