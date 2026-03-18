/**
 * Batch Aggregation module -- HYBRID batch formation with deferred checkpointing.
 *
 * [Spec: validium/specs/units/2026-03-batch-aggregation/1-formalization/v1-fix/specs/BatchAggregation/BatchAggregation.tla]
 *
 * @module batch
 */

export { BatchAggregator } from "./batch-aggregator";
export { buildBatchCircuitInput } from "./batch-builder";
export {
  type Batch,
  type BatchAggregatorConfig,
  type BatchBuildResult,
  type StateTransitionWitness,
  BatchError,
  BatchErrorCode,
} from "./types";
