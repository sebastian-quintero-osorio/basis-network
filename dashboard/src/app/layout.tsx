import type { Metadata } from "next";
import "./globals.css";

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
    <html lang="en">
      <body className="min-h-screen bg-basis-darker text-gray-200 antialiased">
        <header className="border-b border-basis-border bg-basis-dark">
          <div className="max-w-7xl mx-auto px-6 py-4 flex items-center justify-between">
            <div className="flex items-center gap-3">
              <div className="w-8 h-8 bg-basis-primary rounded-lg flex items-center justify-center font-bold text-white text-sm">
                BN
              </div>
              <div>
                <h1 className="text-lg font-semibold text-white">Basis Network</h1>
                <p className="text-xs text-gray-400">Avalanche L1 — Enterprise Dashboard</p>
              </div>
            </div>
            <div className="flex items-center gap-4 text-sm">
              <span className="px-2 py-1 bg-green-900/30 text-green-400 rounded text-xs font-medium">
                Fuji Testnet
              </span>
              <span className="text-gray-400">
                Chain ID: {process.env.NEXT_PUBLIC_CHAIN_ID || "43199"}
              </span>
            </div>
          </div>
        </header>
        <main className="max-w-7xl mx-auto px-6 py-8">
          {children}
        </main>
        <footer className="border-t border-basis-border mt-16 py-6 text-center text-sm text-gray-500">
          <a href="https://basisnetwork.com.co" target="_blank" rel="noopener noreferrer" className="hover:text-gray-300">Basis Network</a>
          {" "}&mdash;{" "}
          <a href="https://basecomputing.com.co" target="_blank" rel="noopener noreferrer" className="hover:text-gray-300">Base Computing S.A.S.</a>
          {" "}&mdash; Avalanche Build Games 2026
        </footer>
      </body>
    </html>
  );
}
