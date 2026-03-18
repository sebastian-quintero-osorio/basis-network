"use client";

import { useState } from "react";
import { useNetwork } from "@/lib/NetworkContext";
import EnterpriseList from "@/components/EnterpriseList";

export default function EnterprisesPage() {
  const { enterprises, enterpriseCount, loading } = useNetwork();
  const [search, setSearch] = useState("");

  const filtered = enterprises.filter(
    (e) =>
      e.name.toLowerCase().includes(search.toLowerCase()) ||
      e.address.toLowerCase().includes(search.toLowerCase())
  );

  if (loading) {
    return (
      <div className="space-y-6">
        <div>
          <div className="skeleton h-7 w-40 mb-2" />
          <div className="skeleton h-4 w-56" />
        </div>
        <div className="skeleton h-10 w-80" />
        <div className="card-static p-5 space-y-3">
          {[...Array(4)].map((_, i) => (
            <div key={i} className="skeleton h-12 w-full" />
          ))}
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Page Header */}
      <div className="animate-in">
        <h1 className="text-2xl font-extrabold tracking-tight text-zinc-800">
          Enterprises
        </h1>
        <p className="text-sm text-zinc-500 mt-1">
          {enterpriseCount} registered on Basis Network
        </p>
      </div>

      {/* Search */}
      <div className="animate-in delay-1">
        <input
          type="text"
          placeholder="Search by name or address..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          className="input max-w-md"
        />
      </div>

      {/* Table */}
      <div className="animate-in delay-2">
        <EnterpriseList enterprises={filtered} />
      </div>

      {search && filtered.length === 0 && enterprises.length > 0 && (
        <p className="text-sm text-zinc-500 animate-in delay-2">
          No enterprises match &ldquo;{search}&rdquo;.
        </p>
      )}
    </div>
  );
}
