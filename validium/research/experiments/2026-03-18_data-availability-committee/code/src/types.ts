// RU-V6: Data Availability Committee -- Type Definitions

// BN128 scalar field prime (same field used by Poseidon hash and Groth16 in the validium)
export const BN128_PRIME = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

// Field element size in bytes (254-bit prime -> 32 bytes)
export const FIELD_ELEMENT_BYTES = 32;

/** A share produced by Shamir's Secret Sharing */
export interface Share {
  /** Share index (evaluation point x, 1-indexed) */
  index: number;
  /** Share value (evaluation y = f(index) mod p) */
  value: bigint;
}

/** A set of shares for one field element, distributed to n parties */
export interface ShareSet {
  /** The (k,n) threshold parameters */
  threshold: number;
  total: number;
  /** One share per party */
  shares: Share[];
}

/** Data stored by a single DAC node */
export interface DACNodeState {
  nodeId: number;
  /** Shares for each field element of the batch data */
  shares: bigint[];
  /** SHA-256 commitment of the original batch data */
  dataCommitment: string;
  /** Timestamp when shares were received */
  receivedAt: number;
  /** Whether this node has attested availability */
  attested: boolean;
}

/** ECDSA-style attestation signature (simulated) */
export interface Attestation {
  nodeId: number;
  dataCommitment: string;
  batchId: string;
  timestamp: number;
  /** Simulated signature (hash of commitment + nodeId + secret key) */
  signature: string;
}

/** Aggregated attestation certificate posted on-chain */
export interface DACCertificate {
  batchId: string;
  dataCommitment: string;
  attestations: Attestation[];
  /** Number of valid attestations */
  signatureCount: number;
  /** Whether threshold was met */
  valid: boolean;
  /** Timestamp of certificate creation */
  createdAt: number;
}

/** DAC Protocol configuration */
export interface DACConfig {
  /** Number of committee members (n) */
  committeeSize: number;
  /** Reconstruction/attestation threshold (k) */
  threshold: number;
  /** Timeout for attestation collection in ms */
  attestationTimeoutMs: number;
  /** Whether to fall back to on-chain DA if attestation fails */
  enableFallback: boolean;
}

/** Benchmark result for a single operation */
export interface BenchmarkResult {
  operation: string;
  batchSizeBytes: number;
  fieldElements: number;
  durationMs: number;
  /** Additional metrics specific to the operation */
  metadata?: Record<string, number | string>;
}

/** Full benchmark suite results */
export interface BenchmarkSuite {
  config: DACConfig;
  batchSizeBytes: number;
  replications: number;
  results: {
    shareGeneration: number[];
    shareDistribution: number[];
    attestationCollection: number[];
    fullAttestationPipeline: number[];
    dataRecovery: number[];
    storageOverhead: number;
  };
}
