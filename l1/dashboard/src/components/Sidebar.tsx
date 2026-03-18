"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useNetwork } from "@/lib/NetworkContext";

interface SidebarProps {
  open: boolean;
  onClose: () => void;
}

const navItems = [
  {
    href: "/",
    label: "Overview",
    icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
        <rect x="3" y="3" width="7" height="7" rx="1" />
        <rect x="14" y="3" width="7" height="7" rx="1" />
        <rect x="3" y="14" width="7" height="7" rx="1" />
        <rect x="14" y="14" width="7" height="7" rx="1" />
      </svg>
    ),
  },
  {
    href: "/enterprises",
    label: "Enterprises",
    icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
        <path d="M6 22V4a2 2 0 012-2h8a2 2 0 012 2v18" />
        <path d="M6 12H4a2 2 0 00-2 2v6a2 2 0 002 2h2" />
        <path d="M18 9h2a2 2 0 012 2v9a2 2 0 01-2 2h-2" />
        <path d="M10 6h4" />
        <path d="M10 10h4" />
        <path d="M10 14h4" />
        <path d="M10 18h4" />
      </svg>
    ),
  },
  {
    href: "/activity",
    label: "Activity",
    icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
        <polyline points="22 12 18 12 15 21 9 3 6 12 2 12" />
      </svg>
    ),
  },
  {
    href: "/modules",
    label: "Modules",
    icon: (
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
        <path d="M21 16V8a2 2 0 00-1-1.73l-7-4a2 2 0 00-2 0l-7 4A2 2 0 003 8v8a2 2 0 001 1.73l7 4a2 2 0 002 0l7-4A2 2 0 0021 16z" />
        <polyline points="3.27 6.96 12 12.01 20.73 6.96" />
        <line x1="12" y1="22.08" x2="12" y2="12" />
      </svg>
    ),
  },
];

export default function Sidebar({ open, onClose }: SidebarProps) {
  const pathname = usePathname();
  const { connected, blockNumber, loading } = useNetwork();

  const isActive = (href: string) => {
    if (href === "/") return pathname === "/";
    return pathname.startsWith(href);
  };

  return (
    <aside className={`sidebar ${open ? "open" : ""}`}>
      {/* Logo */}
      <div className="px-5 py-6">
        <div className="flex items-center gap-3">
          <svg width="28" height="28" viewBox="0 0 256 256" fill="none">
            <defs>
              <linearGradient id="sidebar-logo-g" x1="32" y1="16" x2="224" y2="240" gradientUnits="userSpaceOnUse">
                <stop stopColor="#A7F3D0" />
                <stop offset="0.5" stopColor="#67E8F9" />
                <stop offset="1" stopColor="#93C5FD" />
              </linearGradient>
            </defs>
            <g stroke="url(#sidebar-logo-g)" strokeWidth="14" strokeLinecap="round" strokeLinejoin="round">
              <path d="M128 32 L208 80 L208 176 L128 224 L48 176 L48 80 Z" opacity=".9" />
              <path d="M128 32 L128 128 M208 80 L128 128 M208 176 L128 128 M128 224 L128 128 M48 176 L128 128 M48 80 L128 128" opacity=".9" />
            </g>
            <circle cx="128" cy="128" r="20" fill="url(#sidebar-logo-g)" />
            <circle cx="128" cy="32" r="18" fill="url(#sidebar-logo-g)" />
            <circle cx="208" cy="80" r="18" fill="url(#sidebar-logo-g)" />
            <circle cx="208" cy="176" r="18" fill="url(#sidebar-logo-g)" />
            <circle cx="128" cy="224" r="18" fill="url(#sidebar-logo-g)" />
            <circle cx="48" cy="176" r="18" fill="url(#sidebar-logo-g)" />
            <circle cx="48" cy="80" r="18" fill="url(#sidebar-logo-g)" />
          </svg>
          <div>
            <span className="text-[15px] font-semibold tracking-tight text-zinc-800">
              Basis Network
            </span>
            <p className="text-[10px] text-zinc-400 tracking-wide uppercase">
              Enterprise L1
            </p>
          </div>
        </div>
      </div>

      {/* Separator */}
      <div className="mx-5 border-b border-black/[0.04]" />

      {/* Navigation */}
      <nav className="flex-1 px-3 py-4 space-y-1">
        {navItems.map((item) => (
          <Link
            key={item.href}
            href={item.href}
            onClick={onClose}
            className={`nav-item ${isActive(item.href) ? "nav-item-active" : ""}`}
          >
            {item.icon}
            {item.label}
          </Link>
        ))}
      </nav>

      {/* Ecosystem Links */}
      <div className="mx-5 border-t border-black/[0.04]" />
      <div className="px-3 py-3 space-y-1">
        <p className="px-3 pb-1 text-[10px] font-medium text-zinc-400 uppercase tracking-widest">
          Ecosystem
        </p>
        <a
          href="https://basisnetwork.com.co"
          target="_blank"
          rel="noopener noreferrer"
          className="nav-item group"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="12" cy="12" r="10" />
            <path d="M2 12h20" />
            <path d="M12 2a15.3 15.3 0 014 10 15.3 15.3 0 01-4 10 15.3 15.3 0 01-4-10 15.3 15.3 0 014-10z" />
          </svg>
          Website
          <svg className="ml-auto w-3.5 h-3.5 text-zinc-300 group-hover:text-zinc-500 transition-colors" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M18 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V8a2 2 0 012-2h6" />
            <polyline points="15 3 21 3 21 9" />
            <line x1="10" y1="14" x2="21" y2="3" />
          </svg>
        </a>
        <a
          href="https://explorer.basisnetwork.com.co"
          target="_blank"
          rel="noopener noreferrer"
          className="nav-item group"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round">
            <circle cx="11" cy="11" r="8" />
            <line x1="21" y1="21" x2="16.65" y2="16.65" />
          </svg>
          Explorer
          <svg className="ml-auto w-3.5 h-3.5 text-zinc-300 group-hover:text-zinc-500 transition-colors" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M18 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V8a2 2 0 012-2h6" />
            <polyline points="15 3 21 3 21 9" />
            <line x1="10" y1="14" x2="21" y2="3" />
          </svg>
        </a>
      </div>

      {/* Network Status */}
      <div className="mx-5 border-t border-black/[0.04]" />
      <div className="px-5 py-4">
        {loading ? (
          <div className="space-y-2">
            <div className="skeleton h-3 w-24" />
            <div className="skeleton h-3 w-32" />
          </div>
        ) : (
          <div className="space-y-1.5">
            <div className="flex items-center gap-2">
              <span
                className={`w-2 h-2 rounded-full ${
                  connected ? "bg-emerald-400 pulse-live" : "bg-red-400"
                }`}
              />
              <span
                className={`text-xs font-medium ${
                  connected ? "text-emerald-600" : "text-red-600"
                }`}
              >
                {connected ? "Connected" : "Disconnected"}
              </span>
            </div>
            <p className="text-[11px] text-zinc-400">
              Fuji Testnet &middot; Chain 43199
            </p>
            {connected && blockNumber > 0 && (
              <p className="text-[11px] text-zinc-400 font-mono">
                Block {blockNumber.toLocaleString()}
              </p>
            )}
          </div>
        )}
      </div>
    </aside>
  );
}
