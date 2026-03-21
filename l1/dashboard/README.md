# Basis Network Dashboard

Live network dashboard for the Basis Network L1, providing real-time enterprise and blockchain metrics.

**Live:** [dashboard.basisnetwork.com.co](https://dashboard.basisnetwork.com.co)

## Pages

| Page | Description |
|------|-------------|
| Overview | Block height, gas price, enterprise count, ZK batch stats, recent blocks |
| Enterprises | Registered enterprises, authorization status, registration dates |
| Activity | Real-time event feed with type badges (auto-refresh every 10s) |
| Modules | Deployed protocol components and their status (7 contracts) |
| Validium | Batch history, ZK circuit specifications, DAC status, state machine |

## Tech Stack

- **Framework:** Next.js 14
- **Styling:** Tailwind CSS with glass morphism design (cyan/sky/blue palette)
- **Blockchain:** ethers.js v6 (direct RPC queries)
- **State:** NetworkContext with 10-second polling
- **Hosting:** Vercel (edge network)

## Setup

```bash
npm install
cp .env.example .env.local    # Configure contract addresses
npm run dev                    # http://localhost:3000
```

## Deployment

```bash
npx vercel login
npx vercel --yes --prod
```

All `NEXT_PUBLIC_*` environment variables must also be set in the Vercel project settings (Production scope).
