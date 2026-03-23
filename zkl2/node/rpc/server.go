// Package rpc implements a JSON-RPC 2.0 server for the Basis L2 node.
//
// Provides standard Ethereum JSON-RPC endpoints (eth_*) and custom Basis
// endpoints (basis_*) for enterprise transaction submission, state queries,
// and pipeline monitoring.
//
// The server uses net/http with JSON-RPC 2.0 dispatch over a single HTTP
// endpoint. Rate limiting is applied per source IP.
package rpc

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
)

// Server is the JSON-RPC 2.0 HTTP server for the Basis L2 node.
type Server struct {
	config     ServerConfig
	logger     *slog.Logger
	httpServer *http.Server
	backend    Backend
	limiter    *IPRateLimiter
}

// ServerConfig holds the JSON-RPC server configuration.
type ServerConfig struct {
	Host            string
	Port            int
	RateLimitPerSec int
	RateLimitBurst  int
	ReadTimeout     time.Duration
	WriteTimeout    time.Duration
	MaxBodySize     int64 // Maximum request body size in bytes.
}

// DefaultServerConfig returns safe defaults for the RPC server.
func DefaultServerConfig() ServerConfig {
	return ServerConfig{
		Host:            "0.0.0.0",
		Port:            8545,
		RateLimitPerSec: 100,
		RateLimitBurst:  200,
		ReadTimeout:     30 * time.Second,
		WriteTimeout:    30 * time.Second,
		MaxBodySize:     1 << 20, // 1 MB
	}
}

// Backend is the interface to the L2 node internals that the RPC server queries.
// This decouples the RPC layer from the node implementation.
type Backend interface {
	// ChainID returns the L2 chain identifier.
	ChainID() uint64

	// BlockNumber returns the latest L2 block number.
	BlockNumber() uint64

	// GetBalance returns the balance of an account in the L2 state.
	GetBalance(address string) (*big.Int, error)

	// GetNonce returns the transaction count (nonce) for an account.
	GetNonce(address string) (uint64, error)

	// GetCode returns the bytecode deployed at an address.
	GetCode(address string) ([]byte, error)

	// Call executes a read-only EVM call (eth_call). Does not modify state.
	Call(from, to string, data []byte, value *big.Int) ([]byte, error)

	// EstimateGas estimates gas for a transaction.
	EstimateGas(from, to string, data []byte, value *big.Int) (uint64, error)

	// GetBlockByNumber returns block data by number.
	GetBlockByNumber(number uint64, fullTx bool) (map[string]interface{}, error)

	// GetTransactionByHash returns full transaction data.
	GetTransactionByHash(txHash string) (map[string]interface{}, error)

	// GetLogs returns logs matching a filter.
	GetLogs(fromBlock, toBlock uint64, addresses []common.Address, topics [][]common.Hash) ([]map[string]interface{}, error)

	// SubmitTransaction submits a decoded, signature-verified transaction to the L2 mempool.
	SubmitTransaction(from common.Address, tx *types.Transaction) error

	// GetTransactionReceipt returns the receipt for a transaction hash.
	GetTransactionReceipt(txHash string) (*TransactionReceipt, error)

	// GetBatchStatus returns the proving pipeline status for a batch.
	GetBatchStatus(batchID uint64) (*BatchStatus, error)
}

// TransactionReceipt is an Ethereum-compatible receipt for L2 transactions.
type TransactionReceipt struct {
	TxHash            string                   `json:"transactionHash"`
	BlockNumber       string                   `json:"blockNumber"`
	BlockHash         string                   `json:"blockHash"`
	TransactionIndex  string                   `json:"transactionIndex"`
	From              string                   `json:"from"`
	To                *string                  `json:"to"`
	ContractAddress   *string                  `json:"contractAddress"`
	GasUsed           string                   `json:"gasUsed"`
	CumulativeGasUsed string                   `json:"cumulativeGasUsed"`
	Status            string                   `json:"status"` // "0x1" = success, "0x0" = revert
	Logs              []map[string]interface{}  `json:"logs"`
	LogsBloom         string                   `json:"logsBloom"`
	Type              string                   `json:"type"`
	EffectiveGasPrice string                   `json:"effectiveGasPrice"`
}

// BatchStatus reports the proving pipeline status for a batch.
type BatchStatus struct {
	BatchID   uint64 `json:"batchId"`
	Stage     string `json:"stage"`
	TxCount   int    `json:"txCount"`
	ProofOnL1 bool   `json:"proofOnL1"`
}

// NewServer creates a new JSON-RPC server.
func NewServer(config ServerConfig, backend Backend, logger *slog.Logger) *Server {
	if logger == nil {
		logger = slog.Default()
	}
	return &Server{
		config:  config,
		logger:  logger,
		backend: backend,
		limiter: NewIPRateLimiter(config.RateLimitPerSec, config.RateLimitBurst),
	}
}

// Start begins listening for JSON-RPC requests.
func (s *Server) Start() error {
	addr := fmt.Sprintf("%s:%d", s.config.Host, s.config.Port)

	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleRequest)

	s.httpServer = &http.Server{
		Addr:         addr,
		Handler:      mux,
		ReadTimeout:  s.config.ReadTimeout,
		WriteTimeout: s.config.WriteTimeout,
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("rpc: listen %s: %w", addr, err)
	}

	s.logger.Info("JSON-RPC server listening", "addr", addr)

	go func() {
		if err := s.httpServer.Serve(ln); err != nil && err != http.ErrServerClosed {
			s.logger.Error("rpc server error", "error", err)
		}
	}()

	return nil
}

// Stop gracefully shuts down the HTTP server.
func (s *Server) Stop(ctx context.Context) error {
	if s.httpServer == nil {
		return nil
	}
	s.logger.Info("shutting down JSON-RPC server")
	return s.httpServer.Shutdown(ctx)
}

// ---------------------------------------------------------------------------
// JSON-RPC 2.0 Types
// ---------------------------------------------------------------------------

// jsonrpcRequest is a JSON-RPC 2.0 request object.
type jsonrpcRequest struct {
	JSONRPC string            `json:"jsonrpc"`
	Method  string            `json:"method"`
	Params  []json.RawMessage `json:"params"`
	ID      json.RawMessage   `json:"id"`
}

// jsonrpcResponse is a JSON-RPC 2.0 response object.
type jsonrpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	Result  interface{}     `json:"result,omitempty"`
	Error   *jsonrpcError   `json:"error,omitempty"`
	ID      json.RawMessage `json:"id"`
}

// jsonrpcError is a JSON-RPC 2.0 error object.
type jsonrpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// Standard JSON-RPC error codes.
const (
	errCodeParse          = -32700
	errCodeInvalidRequest = -32600
	errCodeMethodNotFound = -32601
	errCodeInvalidParams  = -32602
	errCodeInternal       = -32603
)

// ---------------------------------------------------------------------------
// Request Handling
// ---------------------------------------------------------------------------

// handleRequest processes a single HTTP request containing a JSON-RPC call.
func (s *Server) handleRequest(w http.ResponseWriter, r *http.Request) {
	// CORS headers for browser compatibility.
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusOK)
		return
	}

	if r.Method != http.MethodPost {
		s.writeError(w, nil, errCodeInvalidRequest, "only POST method is accepted")
		return
	}

	// Rate limiting.
	ip := extractIP(r)
	if !s.limiter.Allow(ip) {
		s.writeError(w, nil, -32099, "rate limit exceeded")
		return
	}

	// Read and parse request body.
	body, err := io.ReadAll(io.LimitReader(r.Body, s.config.MaxBodySize))
	if err != nil {
		s.writeError(w, nil, errCodeParse, "failed to read request body")
		return
	}

	var req jsonrpcRequest
	if err := json.Unmarshal(body, &req); err != nil {
		s.writeError(w, nil, errCodeParse, "invalid JSON")
		return
	}

	if req.JSONRPC != "2.0" {
		s.writeError(w, req.ID, errCodeInvalidRequest, "jsonrpc must be \"2.0\"")
		return
	}

	// Dispatch to method handler.
	result, rpcErr := s.dispatch(req)
	if rpcErr != nil {
		s.writeErrorObj(w, req.ID, rpcErr)
		return
	}

	resp := jsonrpcResponse{
		JSONRPC: "2.0",
		Result:  result,
		ID:      req.ID,
	}
	json.NewEncoder(w).Encode(resp)
}

// dispatch routes a JSON-RPC request to the appropriate handler.
func (s *Server) dispatch(req jsonrpcRequest) (interface{}, *jsonrpcError) {
	switch req.Method {
	case "eth_chainId":
		return s.ethChainID()
	case "eth_blockNumber":
		return s.ethBlockNumber()
	case "eth_getBalance":
		return s.ethGetBalance(req.Params)
	case "eth_sendRawTransaction":
		return s.ethSendRawTransaction(req.Params)
	case "eth_getTransactionReceipt":
		return s.ethGetTransactionReceipt(req.Params)
	case "eth_getTransactionCount":
		return s.ethGetTransactionCount(req.Params)
	case "eth_getCode":
		return s.ethGetCode(req.Params)
	case "eth_call":
		return s.ethCall(req.Params)
	case "eth_estimateGas":
		return s.ethEstimateGas(req.Params)
	case "eth_getBlockByNumber":
		return s.ethGetBlockByNumber(req.Params)
	case "eth_getBlockByHash":
		return s.ethGetBlockByNumber(req.Params) // hash lookup falls back to number
	case "eth_getTransactionByHash":
		return s.ethGetTransactionByHash(req.Params)
	case "eth_getLogs":
		return s.ethGetLogs(req.Params)
	case "eth_gasPrice":
		return "0x0", nil
	case "eth_accounts":
		return []string{}, nil
	case "eth_mining":
		return false, nil
	case "eth_syncing":
		return false, nil
	case "eth_feeHistory":
		return map[string]interface{}{
			"oldestBlock":   "0x0",
			"baseFeePerGas": []string{"0x0", "0x0"},
			"gasUsedRatio":  []float64{0},
			"reward":        [][]string{{"0x0"}},
		}, nil
	case "eth_maxPriorityFeePerGas":
		return "0x0", nil
	case "net_version":
		return s.netVersion()
	case "web3_clientVersion":
		return s.web3ClientVersion()
	case "basis_getBatchStatus":
		return s.basisGetBatchStatus(req.Params)
	default:
		return nil, &jsonrpcError{Code: errCodeMethodNotFound, Message: fmt.Sprintf("method %q not found", req.Method)}
	}
}

// ---------------------------------------------------------------------------
// Ethereum Standard Methods
// ---------------------------------------------------------------------------

func (s *Server) ethChainID() (interface{}, *jsonrpcError) {
	chainID := s.backend.ChainID()
	return fmt.Sprintf("0x%x", chainID), nil
}

func (s *Server) ethBlockNumber() (interface{}, *jsonrpcError) {
	blockNum := s.backend.BlockNumber()
	return fmt.Sprintf("0x%x", blockNum), nil
}

func (s *Server) ethGetBalance(params []json.RawMessage) (interface{}, *jsonrpcError) {
	if len(params) < 1 {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "missing address parameter"}
	}
	var address string
	if err := json.Unmarshal(params[0], &address); err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid address parameter"}
	}

	balance, err := s.backend.GetBalance(address)
	if err != nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
	}
	return fmt.Sprintf("0x%x", balance), nil
}

func (s *Server) ethSendRawTransaction(params []json.RawMessage) (interface{}, *jsonrpcError) {
	if len(params) < 1 {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "missing raw transaction parameter"}
	}
	var rawTxHex string
	if err := json.Unmarshal(params[0], &rawTxHex); err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid raw transaction parameter"}
	}

	// Step 1: Hex decode.
	rawBytes, err := hex.DecodeString(strings.TrimPrefix(rawTxHex, "0x"))
	if err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid hex encoding"}
	}

	// Step 2: Decode transaction (supports both legacy RLP and EIP-2718 typed transactions).
	// go-ethereum's UnmarshalBinary handles: legacy (RLP), EIP-2930 (0x01), EIP-1559 (0x02).
	var tx types.Transaction
	if err := tx.UnmarshalBinary(rawBytes); err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: fmt.Sprintf("invalid transaction: %v", err)}
	}

	// Step 3: Recover sender address from ECDSA signature.
	chainID := new(big.Int).SetUint64(s.backend.ChainID())
	signer := types.LatestSignerForChainID(chainID)
	from, err := types.Sender(signer, &tx)
	if err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: fmt.Sprintf("invalid signature: %v", err)}
	}

	// Step 4: Submit decoded transaction to the backend.
	if err := s.backend.SubmitTransaction(from, &tx); err != nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
	}

	// Step 5: Return transaction hash.
	return tx.Hash().Hex(), nil
}

func (s *Server) ethGetTransactionReceipt(params []json.RawMessage) (interface{}, *jsonrpcError) {
	if len(params) < 1 {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "missing transaction hash parameter"}
	}
	var txHash string
	if err := json.Unmarshal(params[0], &txHash); err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid transaction hash"}
	}

	receipt, err := s.backend.GetTransactionReceipt(txHash)
	if err != nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
	}
	if receipt == nil {
		return nil, nil // null result = receipt not found
	}
	return receipt, nil
}

func (s *Server) netVersion() (interface{}, *jsonrpcError) {
	return fmt.Sprintf("%d", s.backend.ChainID()), nil
}

func (s *Server) web3ClientVersion() (interface{}, *jsonrpcError) {
	return "basis-l2/v0.1.0", nil
}

func (s *Server) ethGetTransactionCount(params []json.RawMessage) (interface{}, *jsonrpcError) {
	if len(params) < 1 {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "missing address parameter"}
	}
	var address string
	if err := json.Unmarshal(params[0], &address); err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid address parameter"}
	}
	nonce, err := s.backend.GetNonce(address)
	if err != nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
	}
	return fmt.Sprintf("0x%x", nonce), nil
}

func (s *Server) ethGetCode(params []json.RawMessage) (interface{}, *jsonrpcError) {
	if len(params) < 1 {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "missing address parameter"}
	}
	var address string
	if err := json.Unmarshal(params[0], &address); err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid address parameter"}
	}
	code, err := s.backend.GetCode(address)
	if err != nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
	}
	if len(code) == 0 {
		return "0x", nil
	}
	return "0x" + hex.EncodeToString(code), nil
}

func (s *Server) ethCall(params []json.RawMessage) (interface{}, *jsonrpcError) {
	if len(params) < 1 {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "missing call object parameter"}
	}
	var callObj struct {
		From  string `json:"from"`
		To    string `json:"to"`
		Data  string `json:"data"`
		Value string `json:"value"`
	}
	if err := json.Unmarshal(params[0], &callObj); err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid call object"}
	}
	var data []byte
	if callObj.Data != "" {
		var err error
		data, err = hex.DecodeString(strings.TrimPrefix(callObj.Data, "0x"))
		if err != nil {
			return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid data hex"}
		}
	}
	var value *big.Int
	if callObj.Value != "" {
		value = new(big.Int)
		value.SetString(strings.TrimPrefix(callObj.Value, "0x"), 16)
	}
	result, err := s.backend.Call(callObj.From, callObj.To, data, value)
	if err != nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
	}
	if len(result) == 0 {
		return "0x", nil
	}
	return "0x" + hex.EncodeToString(result), nil
}

func (s *Server) ethEstimateGas(params []json.RawMessage) (interface{}, *jsonrpcError) {
	if len(params) < 1 {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "missing call object parameter"}
	}
	var callObj struct {
		From  string `json:"from"`
		To    string `json:"to"`
		Data  string `json:"data"`
		Value string `json:"value"`
	}
	if err := json.Unmarshal(params[0], &callObj); err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid call object"}
	}
	var data []byte
	if callObj.Data != "" {
		var err error
		data, err = hex.DecodeString(strings.TrimPrefix(callObj.Data, "0x"))
		if err != nil {
			return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid data hex"}
		}
	}
	var value *big.Int
	if callObj.Value != "" {
		value = new(big.Int)
		value.SetString(strings.TrimPrefix(callObj.Value, "0x"), 16)
	}
	gas, err := s.backend.EstimateGas(callObj.From, callObj.To, data, value)
	if err != nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
	}
	return fmt.Sprintf("0x%x", gas), nil
}

func (s *Server) ethGetBlockByNumber(params []json.RawMessage) (interface{}, *jsonrpcError) {
	if len(params) < 1 {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "missing block number parameter"}
	}
	var blockTag string
	if err := json.Unmarshal(params[0], &blockTag); err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid block number"}
	}
	var blockNum uint64
	switch blockTag {
	case "latest", "pending":
		blockNum = s.backend.BlockNumber()
	case "earliest":
		blockNum = 0
	default:
		fmt.Sscanf(strings.TrimPrefix(blockTag, "0x"), "%x", &blockNum)
	}
	fullTx := false
	if len(params) > 1 {
		json.Unmarshal(params[1], &fullTx)
	}
	block, err := s.backend.GetBlockByNumber(blockNum, fullTx)
	if err != nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
	}
	return block, nil
}

func (s *Server) ethGetTransactionByHash(params []json.RawMessage) (interface{}, *jsonrpcError) {
	if len(params) < 1 {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "missing transaction hash"}
	}
	var txHash string
	if err := json.Unmarshal(params[0], &txHash); err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid transaction hash"}
	}
	tx, err := s.backend.GetTransactionByHash(txHash)
	if err != nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
	}
	return tx, nil
}

func (s *Server) ethGetLogs(params []json.RawMessage) (interface{}, *jsonrpcError) {
	if len(params) < 1 {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "missing filter object"}
	}
	var filter struct {
		FromBlock string        `json:"fromBlock"`
		ToBlock   string        `json:"toBlock"`
		Address   interface{}   `json:"address"`
		Topics    []interface{} `json:"topics"`
	}
	if err := json.Unmarshal(params[0], &filter); err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid filter object"}
	}
	var fromBlock, toBlock uint64
	if filter.FromBlock != "" && filter.FromBlock != "latest" {
		fmt.Sscanf(strings.TrimPrefix(filter.FromBlock, "0x"), "%x", &fromBlock)
	}
	if filter.ToBlock == "" || filter.ToBlock == "latest" {
		toBlock = s.backend.BlockNumber()
	} else {
		fmt.Sscanf(strings.TrimPrefix(filter.ToBlock, "0x"), "%x", &toBlock)
	}
	// Parse addresses.
	var addresses []common.Address
	if addrStr, ok := filter.Address.(string); ok && addrStr != "" {
		addresses = append(addresses, common.HexToAddress(addrStr))
	} else if addrList, ok := filter.Address.([]interface{}); ok {
		for _, a := range addrList {
			if s, ok := a.(string); ok {
				addresses = append(addresses, common.HexToAddress(s))
			}
		}
	}
	logs, err := s.backend.GetLogs(fromBlock, toBlock, addresses, nil)
	if err != nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
	}
	if logs == nil {
		return []interface{}{}, nil
	}
	return logs, nil
}

// ---------------------------------------------------------------------------
// Custom Basis Methods
// ---------------------------------------------------------------------------

func (s *Server) basisGetBatchStatus(params []json.RawMessage) (interface{}, *jsonrpcError) {
	if len(params) < 1 {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "missing batch ID parameter"}
	}
	var batchID uint64
	if err := json.Unmarshal(params[0], &batchID); err != nil {
		return nil, &jsonrpcError{Code: errCodeInvalidParams, Message: "invalid batch ID"}
	}

	status, err := s.backend.GetBatchStatus(batchID)
	if err != nil {
		return nil, &jsonrpcError{Code: errCodeInternal, Message: err.Error()}
	}
	return status, nil
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func (s *Server) writeError(w http.ResponseWriter, id json.RawMessage, code int, msg string) {
	resp := jsonrpcResponse{
		JSONRPC: "2.0",
		Error:   &jsonrpcError{Code: code, Message: msg},
		ID:      id,
	}
	json.NewEncoder(w).Encode(resp)
}

func (s *Server) writeErrorObj(w http.ResponseWriter, id json.RawMessage, err *jsonrpcError) {
	resp := jsonrpcResponse{
		JSONRPC: "2.0",
		Error:   err,
		ID:      id,
	}
	json.NewEncoder(w).Encode(resp)
}

func extractIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		return xff
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	return host
}

// ---------------------------------------------------------------------------
// IP Rate Limiter (Token Bucket)
// ---------------------------------------------------------------------------

// IPRateLimiter implements per-IP rate limiting using a simple token bucket.
type IPRateLimiter struct {
	mu      sync.Mutex
	rate    int // tokens per second
	burst   int // maximum burst
	buckets map[string]*tokenBucket
}

type tokenBucket struct {
	tokens   float64
	lastTime time.Time
}

// NewIPRateLimiter creates a new per-IP rate limiter.
func NewIPRateLimiter(rate, burst int) *IPRateLimiter {
	return &IPRateLimiter{
		rate:    rate,
		burst:   burst,
		buckets: make(map[string]*tokenBucket),
	}
}

// Allow returns true if the request from the given IP is within rate limits.
func (l *IPRateLimiter) Allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := time.Now()
	bucket, ok := l.buckets[ip]
	if !ok {
		bucket = &tokenBucket{tokens: float64(l.burst), lastTime: now}
		l.buckets[ip] = bucket
	}

	// Replenish tokens.
	elapsed := now.Sub(bucket.lastTime).Seconds()
	bucket.tokens += elapsed * float64(l.rate)
	if bucket.tokens > float64(l.burst) {
		bucket.tokens = float64(l.burst)
	}
	bucket.lastTime = now

	if bucket.tokens < 1 {
		return false
	}
	bucket.tokens--
	return true
}
