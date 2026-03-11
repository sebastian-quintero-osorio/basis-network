"use client";

import { useState } from "react";
import dynamic from "next/dynamic";
import { NetworkProvider, useNetwork } from "@/lib/NetworkContext";
import Sidebar from "./Sidebar";

const NetworkParticles = dynamic(() => import("./NetworkParticles"), {
  ssr: false,
});

function WarningBanner() {
  const { error, loading } = useNetwork();
  if (loading || !error) return null;
  return (
    <div className="warning-banner mb-6">
      Network unreachable — dashboard data may be unavailable or stale.
    </div>
  );
}

function LayoutShell({ children }: { children: React.ReactNode }) {
  const [sidebarOpen, setSidebarOpen] = useState(false);

  return (
    <>
      <NetworkParticles />
      <div className="bg-orbs" aria-hidden="true" />

      {/* Mobile Header */}
      <div className="mobile-header lg:hidden flex items-center justify-between px-5">
        <button
          onClick={() => setSidebarOpen(true)}
          className="p-1.5 -ml-1.5 rounded-lg hover:bg-black/[0.03] transition-colors"
          aria-label="Open navigation"
        >
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
            <line x1="3" y1="6" x2="21" y2="6" />
            <line x1="3" y1="12" x2="21" y2="12" />
            <line x1="3" y1="18" x2="21" y2="18" />
          </svg>
        </button>
        <div className="flex items-center gap-2">
          <svg width="20" height="20" viewBox="0 0 256 256" fill="none">
            <defs>
              <linearGradient id="mobile-logo-g" x1="32" y1="16" x2="224" y2="240" gradientUnits="userSpaceOnUse">
                <stop stopColor="#A7F3D0" />
                <stop offset="0.5" stopColor="#67E8F9" />
                <stop offset="1" stopColor="#93C5FD" />
              </linearGradient>
            </defs>
            <g stroke="url(#mobile-logo-g)" strokeWidth="16" strokeLinecap="round" strokeLinejoin="round">
              <path d="M128 32 L208 80 L208 176 L128 224 L48 176 L48 80 Z" opacity=".9" />
              <path d="M128 32 L128 128 M208 80 L128 128 M208 176 L128 128 M128 224 L128 128 M48 176 L128 128 M48 80 L128 128" opacity=".9" />
            </g>
            <circle cx="128" cy="128" r="22" fill="url(#mobile-logo-g)" />
          </svg>
          <span className="text-sm font-semibold tracking-tight text-zinc-800">
            Basis Network
          </span>
        </div>
        <span className="pill-active px-2 py-0.5 rounded-full text-[10px] font-medium">
          Fuji
        </span>
      </div>

      {/* Mobile Overlay */}
      {sidebarOpen && (
        <div
          className="lg:hidden fixed inset-0 bg-black/15 backdrop-blur-sm z-30"
          onClick={() => setSidebarOpen(false)}
        />
      )}

      {/* Sidebar */}
      <Sidebar open={sidebarOpen} onClose={() => setSidebarOpen(false)} />

      {/* Main Content */}
      <main className="relative z-10 lg:pl-[260px] pt-14 lg:pt-0 min-h-screen">
        <div className="max-w-[1100px] mx-auto px-6 py-8 lg:py-10">
          <WarningBanner />
          {children}
        </div>
      </main>
    </>
  );
}

export default function ClientLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <NetworkProvider>
      <LayoutShell>{children}</LayoutShell>
    </NetworkProvider>
  );
}
