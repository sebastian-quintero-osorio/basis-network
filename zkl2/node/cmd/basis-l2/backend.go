package main

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"

	"basis-network/zkl2/node/rpc"
	"basis-network/zkl2/node/sequencer"
	"basis-network/zkl2/node/statedb"
)

// NodeBackend implements rpc.Backend by delegating to real node components.
type NodeBackend struct {
	stateDB   *statedb.StateDB
	seq       *sequencer.Sequencer
	l2ChainID uint64
	blockNum  uint64
}

// Compile-time check that NodeBackend implements rpc.Backend.
var _ rpc.Backend = (*NodeBackend)(nil)

func (b *NodeBackend) ChainID() uint64 {
	return b.l2ChainID
}

func (b *NodeBackend) BlockNumber() uint64 {
	return b.blockNum
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
	// Receipts not yet indexed. Return nil (not found).
	return nil, nil
}

func (b *NodeBackend) GetBatchStatus(batchID uint64) (*rpc.BatchStatus, error) {
	return &rpc.BatchStatus{
		BatchID: batchID,
		Stage:   "unknown",
	}, nil
}
