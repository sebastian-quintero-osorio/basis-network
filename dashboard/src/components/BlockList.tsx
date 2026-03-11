"use client";

import type { BlockInfo } from "@/lib/contracts";

interface BlockListProps {
  blocks: BlockInfo[];
}

function timeAgo(timestamp: number): string {
  const seconds = Math.floor(Date.now() / 1000 - timestamp);
  if (seconds < 0) return "just now";
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  return `${Math.floor(seconds / 86400)}d ago`;
}

export default function BlockList({ blocks }: BlockListProps) {
  if (blocks.length === 0) {
    return (
      <div className="card-static p-8 text-center text-zinc-500 text-sm">
        No blocks available.
      </div>
    );
  }

  return (
    <div className="card-static overflow-hidden">
      <div className="divide-y divide-black/[0.03]">
        {blocks.map((block, i) => (
          <div
            key={block.number}
            className={`flex items-center justify-between px-5 py-3 hover:bg-white/30 transition-colors ${
              i === 0 ? "block-flash" : ""
            }`}
          >
            <div className="flex items-center gap-3">
              <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-basis-cyan/10 to-basis-sky/10 flex items-center justify-center">
                <svg
                  width="14"
                  height="14"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  className="text-basis-cyan"
                >
                  <path d="M21 16V8a2 2 0 00-1-1.73l-7-4a2 2 0 00-2 0l-7 4A2 2 0 003 8v8a2 2 0 001 1.73l7 4a2 2 0 002 0l7-4A2 2 0 0021 16z" />
                </svg>
              </div>
              <div>
                <p className="text-sm font-medium text-zinc-800 font-mono">
                  {block.number.toLocaleString()}
                </p>
                <p className="text-[11px] text-zinc-400">
                  {block.transactions} tx
                </p>
              </div>
            </div>
            <span className="text-[11px] text-zinc-400">
              {timeAgo(block.timestamp)}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
