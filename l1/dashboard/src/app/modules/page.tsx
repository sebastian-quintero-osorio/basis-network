"use client";

import { useNetwork } from "@/lib/NetworkContext";
import ModuleCard from "@/components/ModuleCard";

export default function ModulesPage() {
  const {
    loading,
    enterpriseCount,
    totalEvents,
    totalZKBatches,
    totalZKVerified,
    totalTxVerified,
    totalBatchesCommitted,
    totalDACCertified,
    totalCrossRefsVerified,
    dacCommitteeSize,
  } = useNetwork();

  const modules = [
    {
      name: "Enterprise Registry",
      category: "Identity & Access Control",
      address: process.env.NEXT_PUBLIC_ENTERPRISE_REGISTRY_ADDRESS,
      description:
        "Manages enterprise registration, permissioning, and role-based access control on the L1. Only authorized enterprises can submit transactions to the network.",
      metrics: [
        { label: "Enterprises", value: enterpriseCount },
      ],
    },
    {
      name: "Traceability Registry",
      category: "Event Recording",
      address: process.env.NEXT_PUBLIC_TRACEABILITY_REGISTRY_ADDRESS,
      description:
        "Core event recording layer. Provides immutable, timestamped traceability records for all enterprise operations on-chain. Any authorized application can submit events.",
      metrics: [
        { label: "Total Events", value: totalEvents },
      ],
    },
    {
      name: "ZK Verifier",
      category: "Zero-Knowledge Verification",
      address: process.env.NEXT_PUBLIC_ZK_VERIFIER_ADDRESS,
      description:
        "On-chain Groth16 proof verification. Enables validium-style batch processing where transaction data stays off-chain while proofs are verified on the L1.",
      metrics: [
        { label: "Batches", value: totalZKBatches },
        { label: "Verified", value: totalZKVerified },
        { label: "Tx Validated", value: totalTxVerified },
      ],
    },
    {
      name: "State Commitment",
      category: "ZK Validium",
      address: process.env.NEXT_PUBLIC_STATE_COMMITMENT_ADDRESS,
      description:
        "Per-enterprise state root chains with integrated Groth16 ZK proof verification. Enforces ChainContinuity, ProofBeforeState, and NoGap safety invariants atomically.",
      metrics: [
        { label: "Batches Committed", value: totalBatchesCommitted },
      ],
    },
    {
      name: "DAC Attestation",
      category: "Data Availability",
      address: process.env.NEXT_PUBLIC_DAC_ATTESTATION_ADDRESS,
      description:
        "On-chain Data Availability Committee registry with Shamir (k,n) secret sharing. Provides information-theoretic privacy for off-chain batch data with on-chain certificate verification.",
      metrics: [
        { label: "Committee", value: dacCommitteeSize },
        { label: "Certified", value: totalDACCertified },
      ],
    },
    {
      name: "Cross-Enterprise Verifier",
      category: "Multi-Enterprise",
      address: process.env.NEXT_PUBLIC_CROSS_ENTERPRISE_VERIFIER_ADDRESS,
      description:
        "Hub-and-spoke proof aggregation for cross-enterprise interactions. Verifies interaction commitments between enterprises without revealing private data from either party.",
      metrics: [
        { label: "Verified", value: totalCrossRefsVerified },
      ],
    },
  ];

  if (loading) {
    return (
      <div className="space-y-6">
        <div>
          <div className="skeleton h-7 w-28 mb-2" />
          <div className="skeleton h-4 w-64" />
        </div>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {[...Array(3)].map((_, i) => (
            <div key={i} className="card-static p-6 space-y-3">
              <div className="skeleton h-5 w-40" />
              <div className="skeleton h-3 w-24" />
              <div className="skeleton h-12 w-full" />
              <div className="skeleton h-4 w-32" />
            </div>
          ))}
        </div>
      </div>
    );
  }

  const deployedCount = modules.filter((m) => m.address).length;

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="animate-in">
        <h1 className="text-2xl font-extrabold tracking-tight text-zinc-800">
          Protocol Modules
        </h1>
        <p className="text-sm text-zinc-500 mt-1">
          {deployedCount} of {modules.length} core protocol contracts deployed
          on Basis Network
        </p>
      </div>

      {/* Module Cards */}
      <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
        {modules.map((m, i) => (
          <ModuleCard
            key={m.name}
            module={m}
            className={`animate-in delay-${Math.min(i + 1, 7)}`}
          />
        ))}
      </div>
    </div>
  );
}
