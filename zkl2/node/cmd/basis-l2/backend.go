package main

import (
	"fmt"
	"math/big"
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
	seq       *sequencer.Sequencer
	l2ChainID uint64
	blockNum  atomic.Uint64

	receiptsMu sync.RWMutex
	receipts   map[string]*rpc.TransactionReceipt
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
func (b *NodeBackend) StoreReceipt(txHash sequencer.TxHash, blockNumber uint64, result *executor.TransactionResult) {
	b.receiptsMu.Lock()
	defer b.receiptsMu.Unlock()
	if b.receipts == nil {
		b.receipts = make(map[string]*rpc.TransactionReceipt)
	}
	status := uint64(1)
	if result.VMError != nil {
		status = 0
	}
	hashHex := fmt.Sprintf("0x%x", txHash)
	b.receipts[hashHex] = &rpc.TransactionReceipt{
		TxHash:      hashHex,
		BlockNumber: blockNumber,
		GasUsed:     result.GasUsed,
		Status:      status,
	}
}
