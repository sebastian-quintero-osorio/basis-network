import type { Metadata } from "next";
import { Inter } from "next/font/google";
import "./globals.css";

const inter = Inter({
  subsets: ["latin"],
  variable: "--font-inter",
});

export const metadata: Metadata = {
  title: "Basis Network — Dashboard",
  description: "Enterprise-grade Avalanche L1 network explorer and activity dashboard. Native currency: Lithos (LITHOS).",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className={inter.variable}>
      <body className="min-h-screen font-sans antialiased">
        {/* Gradient blobs */}
        <div className="blob-container" aria-hidden="true">
          <div className="blob blob-1" />
          <div className="blob blob-2" />
          <div className="blob blob-3" />
        </div>

        <div className="relative z-10">
          {/* Header */}
          <header className="sticky top-0 z-50 bg-white/70 backdrop-blur-xl border-b border-black/[0.04]">
            <div className="max-w-6xl mx-auto px-6 h-14 flex items-center justify-between">
              <div className="flex items-center gap-2.5">
                <svg width="24" height="24" viewBox="0 0 32 32" fill="none">
                  <circle cx="16" cy="16" r="14" stroke="url(#logo-grad)" strokeWidth="2.5" fill="none" />
                  <circle cx="16" cy="16" r="4" fill="url(#logo-grad)" />
                  <circle cx="16" cy="7" r="2" fill="url(#logo-grad)" opacity="0.6" />
                  <circle cx="23.5" cy="20.5" r="2" fill="url(#logo-grad)" opacity="0.6" />
                  <circle cx="8.5" cy="20.5" r="2" fill="url(#logo-grad)" opacity="0.6" />
                  <line x1="16" y1="12" x2="16" y2="9" stroke="url(#logo-grad)" strokeWidth="1.5" opacity="0.4" />
                  <line x1="19.5" y1="18" x2="22" y2="19.5" stroke="url(#logo-grad)" strokeWidth="1.5" opacity="0.4" />
                  <line x1="12.5" y1="18" x2="10" y2="19.5" stroke="url(#logo-grad)" strokeWidth="1.5" opacity="0.4" />
                  <defs>
                    <linearGradient id="logo-grad" x1="0" y1="0" x2="32" y2="32">
                      <stop offset="0%" stopColor="#00C8AA" />
                      <stop offset="100%" stopColor="#8B5CF6" />
                    </linearGradient>
                  </defs>
                </svg>
                <span className="text-[15px] font-semibold tracking-tight">
                  <span className="text-basis-navy">Basis</span>{" "}
                  <span className="text-basis-cyan">Network</span>
                </span>
              </div>
              <div className="flex items-center gap-3 text-xs">
                <span className="pill-active px-2 py-0.5 rounded-full font-medium text-[11px]">
                  Fuji Testnet
                </span>
                <span className="text-basis-faint font-mono">
                  Chain {process.env.NEXT_PUBLIC_CHAIN_ID || "43199"}
                </span>
              </div>
            </div>
          </header>

          {/* Content */}
          <main className="max-w-6xl mx-auto px-6 py-8">
            {children}
          </main>

          {/* Footer */}
          <footer className="border-t border-black/[0.04] mt-12 py-6 text-center text-[11px] text-basis-faint">
            <a href="https://basisnetwork.com.co" target="_blank" rel="noopener noreferrer" className="hover:text-basis-cyan transition-colors">Basis Network</a>
            {" "}&mdash;{" "}
            <a href="https://basecomputing.com.co" target="_blank" rel="noopener noreferrer" className="hover:text-basis-cyan transition-colors">Base Computing S.A.S.</a>
            {" "}&mdash; Avalanche Build Games 2026
          </footer>
        </div>
      </body>
    </html>
  );
}
