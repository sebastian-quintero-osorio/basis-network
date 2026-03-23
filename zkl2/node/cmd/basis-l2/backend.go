package main

import (
	"context"
	"fmt"
	"math/big"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"

	"basis-network/zkl2/node/executor"
	"basis-network/zkl2/node/rpc"
	"basis-network/zkl2/node/sequencer"
	"basis-network/zkl2/node/statedb"
)

// NodeBackend implements rpc.Backend by delegating to real node components.
type NodeBackend struct {
	stateDB   *statedb.StateDB
	adapter   *statedb.Adapter
	exec      *executor.Executor
	seq       *sequencer.Sequencer
	l2ChainID uint64
	blockNum  atomic.Uint64

	// adapterMu protects the adapter during eth_call/eth_estimateGas read-only execution.
	// The block production loop must also hold this lock during transaction execution.
	AdapterMu sync.Mutex

	receiptsMu sync.RWMutex
	receipts   map[string]*rpc.TransactionReceipt

	blocksMu sync.RWMutex
	blocks   map[uint64]*StoredBlock

	txMu    sync.RWMutex
	txIndex map[string]*StoredTx

	logsMu     sync.RWMutex
	logsByBlock map[uint64][]map[string]interface{}
}

// StoredBlock holds block data for eth_getBlockByNumber.
type StoredBlock struct {
	Number    uint64
	Hash      common.Hash
	Timestamp uint64
	GasUsed   uint64
	TxHashes  []string
}

// StoredTx holds transaction data for eth_getTransactionByHash.
type StoredTx struct {
	Hash        string
	BlockNumber uint64
	From        string
	To          string
	Value       string
	Nonce       uint64
	Gas         uint64
	Data        string
}

// Compile-time check that NodeBackend implements rpc.Backend.
var _ rpc.Backend = (*NodeBackend)(nil)

func (b *NodeBackend) ChainID() uint64 {
	return b.l2ChainID
}

func (b *NodeBackend) BlockNumber() uint64 {
	return b.blockNum.Load()
}

func (b *NodeBackend) GetBalance(address string) (*big.Int, error) {
	addr := common.HexToAddress(address)
	key := statedb.AddressToKey(addr)
	return b.stateDB.GetBalance(key), nil
}

func (b *NodeBackend) GetNonce(address string) (uint64, error) {
	addr := common.HexToAddress(address)
	return b.adapter.GetNonce(addr), nil
}

func (b *NodeBackend) GetCode(address string) ([]byte, error) {
	addr := common.HexToAddress(address)
	return b.adapter.GetCode(addr), nil
}

func (b *NodeBackend) Call(from, to string, data []byte, value *big.Int) ([]byte, error) {
	if value == nil {
		value = new(big.Int)
	}
	fromAddr := common.HexToAddress(from)
	toAddr := common.HexToAddress(to)

	// Lock adapter to prevent concurrent access with block production.
	b.AdapterMu.Lock()
	defer b.AdapterMu.Unlock()

	// Snapshot state for read-only execution.
	snapID := b.adapter.Snapshot()
	defer b.adapter.RevertToSnapshot(snapID)

	msg := executor.Message{
		From:     fromAddr,
		To:       &toAddr,
		Value:    value,
		Gas:      30_000_000, // Block gas limit
		GasPrice: new(big.Int),
		Data:     data,
	}

	blockInfo := executor.BlockInfo{
		Number:    b.blockNum.Load(),
		Timestamp: 0,
		GasLimit:  30_000_000,
		BaseFee:   new(big.Int),
	}

	result, err := b.exec.ExecuteTransaction(context.Background(), b.adapter, blockInfo, msg)
	if err != nil {
		return nil, fmt.Errorf("eth_call execution error: %w", err)
	}
	if result.VMError != nil {
		// Return revert data if available (Hardhat/ethers.js need the raw bytes
		// to decode Error("reason") or custom errors from the contract).
		if len(result.ReturnData) > 0 {
			return result.ReturnData, fmt.Errorf("execution reverted")
		}
		return nil, fmt.Errorf("execution reverted: %v", result.VMError)
	}
	return result.ReturnData, nil
}

func (b *NodeBackend) EstimateGas(from, to string, data []byte, value *big.Int) (uint64, error) {
	if value == nil {
		value = new(big.Int)
	}
	fromAddr := common.HexToAddress(from)
	toAddr := common.HexToAddress(to)

	b.AdapterMu.Lock()
	defer b.AdapterMu.Unlock()

	snapID := b.adapter.Snapshot()
	defer b.adapter.RevertToSnapshot(snapID)

	msg := executor.Message{
		From:     fromAddr,
		To:       &toAddr,
		Value:    value,
		Gas:      30_000_000,
		GasPrice: new(big.Int),
		Data:     data,
	}

	blockInfo := executor.BlockInfo{
		Number:    b.blockNum.Load(),
		Timestamp: 0,
		GasLimit:  30_000_000,
		BaseFee:   new(big.Int),
	}

	result, err := b.exec.ExecuteTransaction(context.Background(), b.adapter, blockInfo, msg)
	if err != nil {
		return 0, fmt.Errorf("gas estimation error: %w", err)
	}
	// Add 20% buffer to gas estimate (standard practice).
	gas := result.GasUsed
	if gas < 21000 {
		gas = 21000
	}
	return gas + gas/5, nil
}

func (b *NodeBackend) GetBlockByNumber(number uint64, fullTx bool) (map[string]interface{}, error) {
	b.blocksMu.RLock()
	block, ok := b.blocks[number]
	b.blocksMu.RUnlock()

	if !ok {
		// Return a synthetic block header for any number up to current.
		if number > b.blockNum.Load() {
			return nil, nil
		}
		return map[string]interface{}{
			"number":           fmt.Sprintf("0x%x", number),
			"hash":             common.Hash{}.Hex(),
			"parentHash":       common.Hash{}.Hex(),
			"timestamp":        "0x0",
			"gasLimit":         fmt.Sprintf("0x%x", 30_000_000),
			"gasUsed":          "0x0",
			"miner":            common.Address{}.Hex(),
			"transactions":     []interface{}{},
			"baseFeePerGas":    "0x0",
			"difficulty":       "0x0",
			"totalDifficulty":  "0x0",
			"size":             "0x0",
			"extraData":        "0x",
			"logsBloom":        "0x" + fmt.Sprintf("%0512x", 0),
			"transactionsRoot": ethtypes.EmptyRootHash.Hex(),
			"stateRoot":        common.Hash{}.Hex(),
			"receiptsRoot":     ethtypes.EmptyRootHash.Hex(),
			"sha3Uncles":       ethtypes.EmptyUncleHash.Hex(),
			"uncles":           []interface{}{},
			"nonce":            "0x0000000000000000",
			"mixHash":          common.Hash{}.Hex(),
		}, nil
	}

	txs := make([]interface{}, len(block.TxHashes))
	for i, h := range block.TxHashes {
		txs[i] = h
	}

	return map[string]interface{}{
		"number":           fmt.Sprintf("0x%x", block.Number),
		"hash":             block.Hash.Hex(),
		"parentHash":       common.Hash{}.Hex(),
		"timestamp":        fmt.Sprintf("0x%x", block.Timestamp),
		"gasLimit":         fmt.Sprintf("0x%x", 30_000_000),
		"gasUsed":          fmt.Sprintf("0x%x", block.GasUsed),
		"miner":            common.Address{}.Hex(),
		"transactions":     txs,
		"baseFeePerGas":    "0x0",
		"difficulty":       "0x0",
		"totalDifficulty":  "0x0",
		"size":             "0x0",
		"extraData":        "0x",
		"logsBloom":        "0x" + fmt.Sprintf("%0512x", 0),
		"transactionsRoot": ethtypes.EmptyRootHash.Hex(),
		"stateRoot":        common.Hash{}.Hex(),
		"receiptsRoot":     ethtypes.EmptyRootHash.Hex(),
		"sha3Uncles":       ethtypes.EmptyUncleHash.Hex(),
		"uncles":           []interface{}{},
		"nonce":            "0x0000000000000000",
		"mixHash":          common.Hash{}.Hex(),
	}, nil
}

func (b *NodeBackend) GetTransactionByHash(txHash string) (map[string]interface{}, error) {
	b.txMu.RLock()
	tx, ok := b.txIndex[txHash]
	b.txMu.RUnlock()
	if !ok {
		return nil, nil
	}
	return map[string]interface{}{
		"hash":             tx.Hash,
		"blockNumber":      fmt.Sprintf("0x%x", tx.BlockNumber),
		"from":             tx.From,
		"to":               tx.To,
		"value":            tx.Value,
		"nonce":            fmt.Sprintf("0x%x", tx.Nonce),
		"gas":              fmt.Sprintf("0x%x", tx.Gas),
		"gasPrice":         "0x0",
		"input":            tx.Data,
		"transactionIndex": "0x0",
		"blockHash":        common.Hash{}.Hex(),
	}, nil
}

func (b *NodeBackend) GetLogs(fromBlock, toBlock uint64, addresses []common.Address, topics [][]common.Hash) ([]map[string]interface{}, error) {
	b.logsMu.RLock()
	defer b.logsMu.RUnlock()

	var result []map[string]interface{}
	for blockNum := fromBlock; blockNum <= toBlock; blockNum++ {
		logs, ok := b.logsByBlock[blockNum]
		if !ok {
			continue
		}
		for _, log := range logs {
			// Filter by address if specified.
			if len(addresses) > 0 {
				logAddr, _ := log["address"].(string)
				match := false
				for _, a := range addresses {
					if strings.EqualFold(logAddr, a.Hex()) {
						match = true
						break
					}
				}
				if !match {
					continue
				}
			}
			result = append(result, log)
		}
	}
	if result == nil {
		return []map[string]interface{}{}, nil
	}
	return result, nil
}

// StoreLogs indexes logs for a block for eth_getLogs.
func (b *NodeBackend) StoreLogs(blockNumber uint64, logs []map[string]interface{}) {
	b.logsMu.Lock()
	defer b.logsMu.Unlock()
	if b.logsByBlock == nil {
		b.logsByBlock = make(map[uint64][]map[string]interface{})
	}
	b.logsByBlock[blockNumber] = append(b.logsByBlock[blockNumber], logs...)
}

func (b *NodeBackend) SubmitTransaction(from common.Address, tx *ethtypes.Transaction) error {
	seqTx := sequencer.FromEthTransaction(from, tx)
	return b.seq.Mempool().Add(seqTx)
}

func (b *NodeBackend) GetTransactionReceipt(txHash string) (*rpc.TransactionReceipt, error) {
	b.receiptsMu.RLock()
	defer b.receiptsMu.RUnlock()
	if b.receipts == nil {
		return nil, nil
	}
	receipt, ok := b.receipts[txHash]
	if !ok {
		return nil, nil
	}
	return receipt, nil
}

func (b *NodeBackend) GetBatchStatus(batchID uint64) (*rpc.BatchStatus, error) {
	return &rpc.BatchStatus{
		BatchID: batchID,
		Stage:   "unknown",
	}, nil
}

// SetBlockNumber updates the current block number (called by block production loop).
func (b *NodeBackend) SetBlockNumber(num uint64) {
	b.blockNum.Store(num)
}

// StoreReceipt indexes a transaction receipt after EVM execution.
func (b *NodeBackend) StoreReceipt(txHash sequencer.TxHash, blockNumber uint64, from common.Address, to *common.Address, result *executor.TransactionResult) {
	b.receiptsMu.Lock()
	defer b.receiptsMu.Unlock()
	if b.receipts == nil {
		b.receipts = make(map[string]*rpc.TransactionReceipt)
	}
	status := "0x1"
	if result.VMError != nil {
		status = "0x0"
	}
	hashHex := fmt.Sprintf("0x%x", txHash)
	fromHex := from.Hex()

	var toPtr *string
	if to != nil {
		s := to.Hex()
		toPtr = &s
	}

	var contractPtr *string
	if result.ContractAddress != nil {
		s := result.ContractAddress.Hex()
		contractPtr = &s
	}

	// Collect logs from trace if available.
	var logs []map[string]interface{}
	if result.Trace != nil && result.Trace.Logs != nil {
		for i, l := range result.Trace.Logs {
			topics := make([]string, len(l.Topics))
			for j, t := range l.Topics {
				topics[j] = t.Hex()
			}
			logs = append(logs, map[string]interface{}{
				"address":          l.Address.Hex(),
				"topics":           topics,
				"data":             fmt.Sprintf("0x%x", l.Data),
				"blockNumber":      fmt.Sprintf("0x%x", blockNumber),
				"transactionHash":  hashHex,
				"transactionIndex": "0x0",
				"blockHash":        common.Hash{}.Hex(),
				"logIndex":         fmt.Sprintf("0x%x", i),
				"removed":          false,
			})
		}
	}
	if logs == nil {
		logs = []map[string]interface{}{}
	}

	b.receipts[hashHex] = &rpc.TransactionReceipt{
		TxHash:            hashHex,
		BlockNumber:       fmt.Sprintf("0x%x", blockNumber),
		BlockHash:         common.Hash{}.Hex(),
		TransactionIndex:  "0x0",
		From:              fromHex,
		To:                toPtr,
		ContractAddress:   contractPtr,
		GasUsed:           fmt.Sprintf("0x%x", result.GasUsed),
		CumulativeGasUsed: fmt.Sprintf("0x%x", result.GasUsed),
		Status:            status,
		Logs:              logs,
		LogsBloom:         "0x" + fmt.Sprintf("%0512x", 0),
		Type:              "0x0",
		EffectiveGasPrice: "0x0",
	}
}

// StoreBlock indexes a block for eth_getBlockByNumber.
func (b *NodeBackend) StoreBlock(block *StoredBlock) {
	b.blocksMu.Lock()
	defer b.blocksMu.Unlock()
	if b.blocks == nil {
		b.blocks = make(map[uint64]*StoredBlock)
	}
	b.blocks[block.Number] = block
}

// StoreTx indexes a transaction for eth_getTransactionByHash.
func (b *NodeBackend) StoreTx(tx *StoredTx) {
	b.txMu.Lock()
	defer b.txMu.Unlock()
	if b.txIndex == nil {
		b.txIndex = make(map[string]*StoredTx)
	}
	b.txIndex[tx.Hash] = tx
}
