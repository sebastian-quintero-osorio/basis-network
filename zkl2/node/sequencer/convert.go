package sequencer

import (
	"math/big"

	"github.com/ethereum/go-ethereum/common"
	ethtypes "github.com/ethereum/go-ethereum/core/types"
)

// FromEthTransaction converts a go-ethereum signed transaction into a
// sequencer Transaction. The sender address must be pre-recovered by the
// caller (via types.Sender) since ECDSA recovery is expensive.
//
// This is the entry point for transactions arriving from the JSON-RPC server.
func FromEthTransaction(from common.Address, ethTx *ethtypes.Transaction) Transaction {
	var to *Address
	if ethTx.To() != nil {
		addr := Address(*ethTx.To())
		to = &addr
	}

	fromAddr := Address(from)
	hash := TxHash(ethTx.Hash())

	return Transaction{
		Hash:     hash,
		From:     fromAddr,
		To:       to,
		Nonce:    ethTx.Nonce(),
		Data:     ethTx.Data(),
		GasLimit: ethTx.Gas(),
		Value:    new(big.Int).Set(ethTx.Value()),
	}
}

// ToCommonAddress converts a sequencer Address to a go-ethereum common.Address.
func (a Address) ToCommon() common.Address {
	return common.Address(a)
}

// ToCommonAddressPtr converts a sequencer *Address to a *common.Address.
// Returns nil if the input is nil (contract creation).
func ToCommonAddressPtr(a *Address) *common.Address {
	if a == nil {
		return nil
	}
	addr := common.Address(*a)
	return &addr
}
