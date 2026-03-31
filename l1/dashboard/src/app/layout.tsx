import type { Metadata } from "next";
import { Inter, JetBrains_Mono } from "next/font/google";
import "./globals.css";
import ClientLayout from "@/components/ClientLayout";

const inter = Inter({
  subsets: ["latin"],
  variable: "--font-inter",
});

const jetbrainsMono = JetBrains_Mono({
  subsets: ["latin"],
  variable: "--font-mono",
});

export const metadata: Metadata = {
  title: "Basis Network — Dashboard",
  description:
    "Enterprise-grade Avalanche L1 network dashboard. Real-time monitoring, enterprise registry, ZK proofs, and on-chain activity.",
  metadataBase: new URL("https://dashboard.basisnetwork.com.co"),
  openGraph: {
    title: "Basis Network — Enterprise L1 Dashboard",
    description:
      "Real-time monitoring for Basis Network: zero-fee Avalanche L1 with ZK proofs, enterprise registry, and industrial traceability.",
    url: "https://dashboard.basisnetwork.com.co",
    siteName: "Basis Network",
    type: "website",
    locale: "en_US",
  },
  twitter: {
    card: "summary",
    title: "Basis Network — Enterprise L1 Dashboard",
    description:
      "Real-time monitoring for Basis Network: zero-fee Avalanche L1 with ZK proofs, enterprise registry, and industrial traceability.",
  },
  icons: {
    icon: "/favicon.svg",
    apple: "/favicon.svg",
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en" className={`${inter.variable} ${jetbrainsMono.variable}`}>
      <body className="min-h-screen font-sans antialiased bg-zinc-100 text-zinc-800">
        <ClientLayout>{children}</ClientLayout>
      </body>
    </html>
  );
}
