# zkEVM L2 -- JSON-RPC API Reference

## Overview

The Basis L2 node exposes a standard Ethereum JSON-RPC 2.0 API on a single HTTP endpoint (default `http://localhost:8545`). Compatible with MetaMask, Hardhat, and ethers.js v6.

All requests use POST with `Content-Type: application/json`.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `RPC_HOST` | `0.0.0.0` | Bind address |
| `RPC_PORT` | `8545` | Listen port |
| `RPC_RATE_LIMIT_PER_SEC` | `100` | Max requests per second per IP |
| `RPC_RATE_LIMIT_BURST` | `200` | Burst capacity |
| Max body size | 1 MB | Request body limit |

## Standard Ethereum Methods (eth_*)

### eth_chainId

Returns the L2 chain identifier.

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
```
```json
{"jsonrpc":"2.0","id":1,"result":"0x69726"}
```

### eth_blockNumber

Returns the latest L2 block number.

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```
```json
{"jsonrpc":"2.0","id":1,"result":"0x2a"}
```

### eth_getBalance

Returns the balance of an address.

**Parameters:** `[address, blockNumber]` (blockNumber ignored, always latest)

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0xA5Ee89Af692d47547Dedf79DF02A3e3e96e48bfD","latest"],"id":1}'
```

### eth_getTransactionCount

Returns the nonce for an address.

**Parameters:** `[address, blockNumber]`

### eth_getCode

Returns the contract bytecode at an address.

**Parameters:** `[address, blockNumber]`

### eth_sendRawTransaction

Submits a signed transaction to the L2 mempool.

**Parameters:** `[signedTxData]` (RLP-encoded, hex-prefixed)

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_sendRawTransaction","params":["0xf86c..."],"id":1}'
```
```json
{"jsonrpc":"2.0","id":1,"result":"0x<txHash>"}
```

### eth_getTransactionReceipt

Returns the receipt for a mined transaction.

**Parameters:** `[txHash]`

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "transactionHash": "0x...",
    "blockNumber": "0x2a",
    "blockHash": "0x...",
    "from": "0x...",
    "to": "0x...",
    "status": "0x1",
    "gasUsed": "0x5208",
    "contractAddress": null,
    "logs": []
  }
}
```

### eth_getTransactionByHash

Returns full transaction data by hash.

**Parameters:** `[txHash]`

### eth_call

Executes a read-only EVM call (does not modify state).

**Parameters:** `[{from, to, data, value}, blockNumber]`

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"0x52C8...","data":"0x..."},"latest"],"id":1}'
```

If the call reverts, the error includes revert data in `error.data`.

### eth_estimateGas

Estimates gas consumption for a transaction.

**Parameters:** `[{from, to, data, value}]`

### eth_getBlockByNumber

Returns block data by number.

**Parameters:** `[blockNumber, fullTransactions]`

### eth_getBlockByHash

Returns block data by hash.

**Parameters:** `[blockHash, fullTransactions]`

### eth_getLogs

Returns event logs matching a filter.

**Parameters:** `[{fromBlock, toBlock, address, topics}]`

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getLogs","params":[{"fromBlock":"0x0","toBlock":"latest"}],"id":1}'
```

### eth_gasPrice

Returns the current gas price (always 0 on Basis Network zero-fee model).

### eth_accounts

Returns an empty array (node does not manage accounts).

### eth_mining

Returns `false` (not a PoW miner).

### eth_syncing

Returns `false` (L2 node is always synced).

### eth_feeHistory

Returns fee history data for EIP-1559 compatibility.

**Parameters:** `[blockCount, newestBlock, rewardPercentiles]`

### eth_maxPriorityFeePerGas

Returns `"0x0"` (zero-fee network).

## Network Methods

### net_version

Returns the network ID as a string.

```json
{"jsonrpc":"2.0","id":1,"result":"431990"}
```

### web3_clientVersion

Returns the client identifier.

```json
{"jsonrpc":"2.0","id":1,"result":"basis-l2/v0.1.0"}
```

## Custom Basis Methods (basis_*)

### basis_getBatchStatus

Returns the proving pipeline status for a batch.

**Parameters:** `[batchId]`

## Rate Limiting

The server applies per-IP token bucket rate limiting:
- Sustained rate: `RPC_RATE_LIMIT_PER_SEC` requests/second (default 100)
- Burst capacity: `RPC_RATE_LIMIT_BURST` (default 200)

Exceeded requests receive HTTP 429 Too Many Requests.

## Error Codes

| Code | Message | Description |
|------|---------|-------------|
| -32700 | Parse error | Invalid JSON |
| -32600 | Invalid Request | Missing jsonrpc/method/id |
| -32601 | Method not found | Unknown RPC method |
| -32602 | Invalid params | Wrong parameter types or count |
| -32603 | Internal error | Server-side failure |
| 3 | Execution reverted | eth_call revert (data in error.data) |

## Compatibility

Tested with:
- MetaMask (browser wallet)
- Hardhat (development framework)
- ethers.js v6 (JavaScript library)
- curl (manual testing)
