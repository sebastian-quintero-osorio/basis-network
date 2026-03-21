"use client";

import StatCard from "@/components/StatCard";

const CONTRACTS = {
  rollup: "0x3984a7ab6d7f05A49d11C347b63E7bc7e5c95f49",
  verifier: "0xFE9DF13c038414773Ac96189742b6c1f93999f29",
  bridge: "0x9Df0814CFBfE352C942bac682A378ff887486Dd8",
  dac: "0xa7D5771fA69404438d79a1F8C192F7257A514691",
  aggregator: "0x98272431b8B270CABeE37A158e01bdC3412744E2",
  hub: "0xBf997eFD945Fe99ECDD129C86De7f75355b1AC42",
};

function truncateAddress(addr: string): string {
  return addr.slice(0, 6) + "..." + addr.slice(-4);
}

const PIPELINE_STEPS = [
  { label: "Commit", desc: "Batch submitted with state root, L2 block range, and priority ops hash", color: "from-amber-400 to-orange-500" },
  { label: "Prove", desc: "ZK validity proof generated and verified on-chain (Groth16/PLONK)", color: "from-cyan-400 to-blue-500" },
  { label: "Execute", desc: "State root finalized, batch permanently anchored on L1", color: "from-emerald-400 to-green-500" },
];

export default function ZkevmPage() {
  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="animate-in">
        <h1 className="text-2xl font-extrabold tracking-tight text-zinc-800">
          zkEVM L2
        </h1>
        <p className="text-sm text-zinc-500 mt-1">
          Enterprise zero-knowledge EVM Layer 2 with per-chain isolation
        </p>
      </div>

      {/* Stats Row */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          title="Proof System"
          value="Groth16"
          subtitle="PLONK migration ready"
          accent
          className="animate-in delay-1"
        />
        <StatCard
          title="Settlement"
          value="3-Phase"
          subtitle="Commit-Prove-Execute"
          className="animate-in delay-2"
        />
        <StatCard
          title="L2 Contracts"
          value="6"
          subtitle="Deployed on L1"
          className="animate-in delay-3"
        />
        <StatCard
          title="Test Coverage"
          value="322"
          subtitle="Solidity tests passing"
          className="animate-in delay-4"
        />
      </div>

      {/* Pipeline Architecture */}
      <div className="card-static p-5 animate-in delay-2">
        <h2 className="text-sm font-semibold text-zinc-700 mb-4">
          Batch Lifecycle Pipeline
        </h2>
        <div className="flex flex-col md:flex-row gap-3">
          {PIPELINE_STEPS.map((step, i) => (
            <div key={i} className="flex-1 relative">
              <div className={`bg-gradient-to-r ${step.color} rounded-lg p-4 text-white`}>
                <div className="flex items-center gap-2 mb-1">
                  <span className="text-xs font-bold bg-white/20 rounded-full w-5 h-5 flex items-center justify-center">
                    {i + 1}
                  </span>
                  <span className="font-bold text-sm">{step.label}</span>
                </div>
                <p className="text-xs text-white/80 leading-relaxed">{step.desc}</p>
              </div>
              {i < PIPELINE_STEPS.length - 1 && (
                <div className="hidden md:block absolute top-1/2 -right-2 transform -translate-y-1/2 text-zinc-300 z-10">
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
                    <path d="M9 18l6-6-6-6" />
                  </svg>
                </div>
              )}
            </div>
          ))}
        </div>
      </div>

      {/* Two-column layout */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-5">
        {/* Left: Contract Deployment Table */}
        <div className="lg:col-span-2 card-static p-5 animate-in delay-3">
          <h2 className="text-sm font-semibold text-zinc-700 mb-3">
            Deployed Settlement Contracts
          </h2>
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead>
                <tr className="border-b border-zinc-200 text-left text-zinc-500">
                  <th className="pb-2 font-medium">Contract</th>
                  <th className="pb-2 font-medium">Address</th>
                  <th className="pb-2 font-medium">Purpose</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-zinc-100">
                <tr>
                  <td className="py-2.5 font-medium text-zinc-800">BasisRollup</td>
                  <td className="py-2.5 font-mono text-xs text-cyan-600">{truncateAddress(CONTRACTS.rollup)}</td>
                  <td className="py-2.5 text-zinc-500">State root management + ZK proof verification</td>
                </tr>
                <tr>
                  <td className="py-2.5 font-medium text-zinc-800">BasisVerifier</td>
                  <td className="py-2.5 font-mono text-xs text-cyan-600">{truncateAddress(CONTRACTS.verifier)}</td>
                  <td className="py-2.5 text-zinc-500">PLONK/Groth16 verification + migration</td>
                </tr>
                <tr>
                  <td className="py-2.5 font-medium text-zinc-800">BasisBridge</td>
                  <td className="py-2.5 font-mono text-xs text-cyan-600">{truncateAddress(CONTRACTS.bridge)}</td>
                  <td className="py-2.5 text-zinc-500">L1-L2 asset transfers + escape hatch</td>
                </tr>
                <tr>
                  <td className="py-2.5 font-medium text-zinc-800">BasisDAC</td>
                  <td className="py-2.5 font-mono text-xs text-cyan-600">{truncateAddress(CONTRACTS.dac)}</td>
                  <td className="py-2.5 text-zinc-500">Data availability committee attestations</td>
                </tr>
                <tr>
                  <td className="py-2.5 font-medium text-zinc-800">BasisAggregator</td>
                  <td className="py-2.5 font-mono text-xs text-cyan-600">{truncateAddress(CONTRACTS.aggregator)}</td>
                  <td className="py-2.5 text-zinc-500">Multi-enterprise proof aggregation</td>
                </tr>
                <tr>
                  <td className="py-2.5 font-medium text-zinc-800">BasisHub</td>
                  <td className="py-2.5 font-mono text-xs text-cyan-600">{truncateAddress(CONTRACTS.hub)}</td>
                  <td className="py-2.5 text-zinc-500">Cross-enterprise hub-and-spoke settlement</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        {/* Right: Info Cards */}
        <div className="space-y-4">
          {/* ZK Circuit Card */}
          <div className="card-static p-5 animate-in delay-4">
            <h3 className="text-sm font-semibold text-zinc-700 mb-3">ZK Proof System</h3>
            <dl className="space-y-2 text-sm">
              <div className="flex justify-between">
                <dt className="text-zinc-500">Scheme</dt>
                <dd className="font-medium text-zinc-800">Groth16 (PLONK target)</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Curve</dt>
                <dd className="font-medium text-zinc-800">BN254</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Prover</dt>
                <dd className="font-medium text-zinc-800">Rust (halo2)</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">State Tree</dt>
                <dd className="font-medium text-zinc-800">Poseidon2 SMT</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Verification Gas</dt>
                <dd className="font-medium text-zinc-800">~300K</dd>
              </div>
            </dl>
          </div>

          {/* Architecture Card */}
          <div className="card-static p-5 animate-in delay-5">
            <h3 className="text-sm font-semibold text-zinc-700 mb-3">Architecture</h3>
            <dl className="space-y-2 text-sm">
              <div className="flex justify-between">
                <dt className="text-zinc-500">Node</dt>
                <dd className="font-medium text-zinc-800">Go (Geth fork)</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">DA Mode</dt>
                <dd className="font-medium text-zinc-800">Validium (DAC)</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Chains</dt>
                <dd className="font-medium text-zinc-800">Per-enterprise</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Cross-Enterprise</dt>
                <dd className="font-medium text-zinc-800">Hub-and-spoke</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Formal Specs</dt>
                <dd className="font-medium text-zinc-800">11 TLA+ verified</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Formal Proofs</dt>
                <dd className="font-medium text-zinc-800">107 Coq files</dd>
              </div>
            </dl>
          </div>

          {/* Test Coverage Card */}
          <div className="card-static p-5 animate-in delay-6">
            <h3 className="text-sm font-semibold text-zinc-700 mb-3">Test Coverage</h3>
            <dl className="space-y-2 text-sm">
              <div className="flex justify-between">
                <dt className="text-zinc-500">Go (11 packages)</dt>
                <dd className="font-medium text-emerald-600">~210 passing</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Rust (3 crates)</dt>
                <dd className="font-medium text-emerald-600">142 passing</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Solidity (6 contracts)</dt>
                <dd className="font-medium text-emerald-600">322 passing</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">E2E (live chain)</dt>
                <dd className="font-medium text-emerald-600">Verified</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Adversarial</dt>
                <dd className="font-medium text-emerald-600">0 violations</dd>
              </div>
            </dl>
          </div>
        </div>
      </div>
    </div>
  );
}
