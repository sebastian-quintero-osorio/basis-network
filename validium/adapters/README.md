# Blockchain Adapter Layer

TypeScript adapter layer that integrates enterprise applications (PLASMA, Trace) with the Basis Network L1 using a dual-write pattern.

## Purpose

The adapter provides a bridge between existing enterprise applications and the blockchain. Applications continue writing to their databases (primary) while the adapter simultaneously writes critical events on-chain as an immutable audit trail.

## Architecture

```
PLASMA Backend ----> PLASMAAdapter ----> TransactionQueue ----> Basis Network L1
Trace Backend  ----> TraceAdapter  ----> TransactionQueue ----> Basis Network L1
```

## Features

- **Dual-write guarantee** -- existing databases are never disrupted
- **Fault tolerance** -- if the L1 is unavailable, events queue and sync on reconnection
- **Retry logic** -- configurable retry count with exponential backoff
- **Idempotency** -- duplicate events are rejected at the contract level

## Setup

```bash
npm install
cp .env.example .env    # Configure RPC URL, contract addresses, private key
npm run demo            # Simulates PLASMA + Trace events writing on-chain
```

## Relationship to Validium Node

The adapter layer was the first integration pattern implemented. With the validium node now operational, enterprises can route events through the validium pipeline for ZK proof generation before L1 submission. The adapter remains available for direct L1 writes where ZK privacy is not required.
