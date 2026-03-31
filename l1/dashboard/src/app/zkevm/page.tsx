"use client";

import StatCard from "@/components/StatCard";

const CONTRACTS = {
  rollupV2: "0xE5D257e10616B30282b67e0D2367216aC89623B4",
  plonkVerifier: "0x361CBD8714180acF6d2230837893CED779045Db6",
  halo2Verifier: "0x53C42dC2E9459CE21A1A321cC51ba92D28E4FAE7",
  verifier: "0x9393099EbCA963388B73b34f71DAB31fec7E8e49",
  bridge: "0xd0B4BeB95De33d6F49Bcc08fE5ce3b923e263a5b",
  dac: "0x1E0c7C220c75E530E22BC066F8B5a98DeB6dfe9B",
  aggregator: "0xddfe844E347470F45D53bA6FFBA95034F45670a2",
  hub: "0x6Faf689a6Dcb67a633b437774388F0358D882f0B",
};

function truncateAddress(addr: string): string {
  return addr.slice(0, 6) + "..." + addr.slice(-4);
}

const PIPELINE_STEPS = [
  { label: "Commit", desc: "Batch submitted with state root, L2 block range, and priority ops hash", color: "from-amber-400 to-orange-500", gas: "149K" },
  { label: "Prove", desc: "Halo2 PLONK-KZG validity proof verified on-chain via EIP-197", color: "from-cyan-400 to-blue-500", gas: "515K" },
  { label: "Execute", desc: "State root finalized, batch permanently anchored on L1", color: "from-emerald-400 to-green-500", gas: "70K" },
];

const E2E_METRICS = {
  totalGas: "735K",
  totalTime: "5.99s",
  proofSize: "1,376 bytes",
  witnessTime: "9ms",
  proveTime: "86ms",
  batchesVerified: 1,
};

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

      {/* E2E Verification Badge */}
      <div className="animate-in delay-1">
        <div className="bg-gradient-to-r from-emerald-50 to-cyan-50 border border-emerald-200 rounded-lg p-4">
          <div className="flex items-center gap-3">
            <div className="w-3 h-3 rounded-full bg-emerald-500 animate-pulse" />
            <div>
              <p className="text-sm font-semibold text-emerald-800">
                E2E Pipeline Verified on Basis Network L1 (Fuji)
              </p>
              <p className="text-xs text-emerald-600 mt-0.5">
                tx &#8594; EVM execute &#8594; witness ({E2E_METRICS.witnessTime}) &#8594; PLONK-KZG prove ({E2E_METRICS.proveTime}) &#8594; L1 commit &#8594; L1 prove &#8594; L1 execute &#8594; finalized ({E2E_METRICS.totalGas} gas, {E2E_METRICS.totalTime})
              </p>
            </div>
          </div>
        </div>
      </div>

      {/* Stats Row */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <StatCard
          title="Proof System"
          value="PLONK-KZG"
          subtitle="Real proofs verified on-chain"
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
          title="L1 Gas Cost"
          value={E2E_METRICS.totalGas}
          subtitle="Per batch (zero-fee)"
          className="animate-in delay-3"
        />
        <StatCard
          title="Proof Time"
          value={E2E_METRICS.proveTime}
          subtitle={`${E2E_METRICS.proofSize} proof`}
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
                  <span className="ml-auto text-xs bg-white/20 rounded px-1.5 py-0.5">
                    {step.gas} gas
                  </span>
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
                  <td className="py-2.5 font-medium text-zinc-800">BasisRollupV2</td>
                  <td className="py-2.5 font-mono text-xs text-cyan-600">{truncateAddress(CONTRACTS.rollupV2)}</td>
                  <td className="py-2.5 text-zinc-500">State root management + 3-phase settlement</td>
                </tr>
                <tr>
                  <td className="py-2.5 font-medium text-zinc-800">Halo2PlonkVerifier</td>
                  <td className="py-2.5 font-mono text-xs text-cyan-600">{truncateAddress(CONTRACTS.plonkVerifier)}</td>
                  <td className="py-2.5 text-zinc-500">PLONK-KZG proof verification wrapper</td>
                </tr>
                <tr>
                  <td className="py-2.5 font-medium text-zinc-800">Halo2Verifier</td>
                  <td className="py-2.5 font-mono text-xs text-cyan-600">{truncateAddress(CONTRACTS.halo2Verifier)}</td>
                  <td className="py-2.5 text-zinc-500">Generated Halo2 verifier (Keccak256 transcript)</td>
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
                  <td className="py-2.5 text-zinc-500">ProtoGalaxy multi-enterprise proof aggregation</td>
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
                <dd className="font-medium text-zinc-800">PLONK-KZG</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Curve</dt>
                <dd className="font-medium text-zinc-800">BN254</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Prover</dt>
                <dd className="font-medium text-zinc-800">Rust (halo2-KZG)</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">State Tree</dt>
                <dd className="font-medium text-zinc-800">Poseidon SMT (depth 32)</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Verification Gas</dt>
                <dd className="font-medium text-zinc-800">~291K total</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Aggregation</dt>
                <dd className="font-medium text-zinc-800">ProtoGalaxy folding</dd>
              </div>
            </dl>
          </div>

          {/* Architecture Card */}
          <div className="card-static p-5 animate-in delay-5">
            <h3 className="text-sm font-semibold text-zinc-700 mb-3">Architecture</h3>
            <dl className="space-y-2 text-sm">
              <div className="flex justify-between">
                <dt className="text-zinc-500">Node</dt>
                <dd className="font-medium text-zinc-800">Go (Geth EVM)</dd>
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
                <dt className="text-zinc-500">Persistence</dt>
                <dd className="font-medium text-zinc-800">LevelDB</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">RPC</dt>
                <dd className="font-medium text-zinc-800">21 eth_* methods</dd>
              </div>
            </dl>
          </div>

          {/* Test Coverage Card */}
          <div className="card-static p-5 animate-in delay-6">
            <h3 className="text-sm font-semibold text-zinc-700 mb-3">Test Coverage</h3>
            <dl className="space-y-2 text-sm">
              <div className="flex justify-between">
                <dt className="text-zinc-500">Go (11 packages)</dt>
                <dd className="font-medium text-emerald-600">258 passing</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Rust (3 crates)</dt>
                <dd className="font-medium text-emerald-600">142 passing</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Solidity (6 contracts)</dt>
                <dd className="font-medium text-emerald-600">370 passing</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">TLA+ specs</dt>
                <dd className="font-medium text-emerald-600">11 verified</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">Coq proofs</dt>
                <dd className="font-medium text-emerald-600">107 files (0 Admitted)</dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-zinc-500">E2E Pipeline</dt>
                <dd className="font-medium text-emerald-600">Verified on L1</dd>
              </div>
            </dl>
          </div>
        </div>
      </div>
    </div>
  );
}
