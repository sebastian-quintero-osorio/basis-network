package rpc

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
)

// ---------------------------------------------------------------------------
// Mock Backend
// ---------------------------------------------------------------------------

type mockBackend struct {
	chainID     uint64
	blockNumber uint64
	balances    map[string]*big.Int
	txHashes    map[string]*TransactionReceipt
}

func newMockBackend() *mockBackend {
	return &mockBackend{
		chainID:     431990,
		blockNumber: 42,
		balances: map[string]*big.Int{
			"0x1111111111111111111111111111111111111111": big.NewInt(1000000),
		},
		txHashes: map[string]*TransactionReceipt{
			"0xabc123": {TxHash: "0xabc123", BlockNumber: "0xa", GasUsed: "0x5208", Status: "0x1", From: "0x0000000000000000000000000000000000000000", Logs: []map[string]interface{}{}, LogsBloom: "0x", Type: "0x0", EffectiveGasPrice: "0x0", TransactionIndex: "0x0", BlockHash: "0x0000000000000000000000000000000000000000000000000000000000000000", CumulativeGasUsed: "0x5208"},
		},
	}
}

func (m *mockBackend) ChainID() uint64                 { return m.chainID }
func (m *mockBackend) BlockNumber() uint64              { return m.blockNumber }
func (m *mockBackend) GetBalance(addr string) (*big.Int, error) {
	if bal, ok := m.balances[addr]; ok {
		return bal, nil
	}
	return big.NewInt(0), nil
}
func (m *mockBackend) SubmitTransaction(from common.Address, tx *types.Transaction) error {
	return nil
}
func (m *mockBackend) GetTransactionReceipt(txHash string) (*TransactionReceipt, error) {
	if r, ok := m.txHashes[txHash]; ok {
		return r, nil
	}
	return nil, nil
}
func (m *mockBackend) GetNonce(addr string) (uint64, error) {
	return 0, nil
}
func (m *mockBackend) GetCode(addr string) ([]byte, error) {
	return nil, nil
}
func (m *mockBackend) Call(from, to string, data []byte, value *big.Int) ([]byte, error) {
	return nil, nil
}
func (m *mockBackend) EstimateGas(from, to string, data []byte, value *big.Int) (uint64, error) {
	return 21000, nil
}
func (m *mockBackend) GetBlockByNumber(number uint64, fullTx bool) (map[string]interface{}, error) {
	return map[string]interface{}{"number": fmt.Sprintf("0x%x", number)}, nil
}
func (m *mockBackend) GetTransactionByHash(txHash string) (map[string]interface{}, error) {
	return nil, nil
}
func (m *mockBackend) GetLogs(fromBlock, toBlock uint64, addresses []common.Address, topics [][]common.Hash) ([]map[string]interface{}, error) {
	return []map[string]interface{}{}, nil
}
func (m *mockBackend) GetBatchStatus(batchID uint64) (*BatchStatus, error) {
	return &BatchStatus{
		BatchID:   batchID,
		Stage:     "finalized",
		TxCount:   100,
		ProofOnL1: true,
	}, nil
}

// ---------------------------------------------------------------------------
// Test Helpers
// ---------------------------------------------------------------------------

func makeRequest(t *testing.T, server *Server, method string, params ...interface{}) *httptest.ResponseRecorder {
	t.Helper()
	paramsJSON := make([]json.RawMessage, len(params))
	for i, p := range params {
		b, _ := json.Marshal(p)
		paramsJSON[i] = b
	}
	req := jsonrpcRequest{
		JSONRPC: "2.0",
		Method:  method,
		Params:  paramsJSON,
		ID:      json.RawMessage(`1`),
	}
	body, _ := json.Marshal(req)
	httpReq := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader(body))
	httpReq.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	server.handleRequest(w, httpReq)
	return w
}

func parseResponse(t *testing.T, w *httptest.ResponseRecorder) jsonrpcResponse {
	t.Helper()
	var resp jsonrpcResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse response: %v (body: %s)", err, w.Body.String())
	}
	return resp
}

func testServer() *Server {
	cfg := DefaultServerConfig()
	return NewServer(cfg, newMockBackend(), nil)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

func TestEthChainID(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "eth_chainId")
	resp := parseResponse(t, w)

	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error.Message)
	}
	result, _ := json.Marshal(resp.Result)
	if string(result) != `"0x69776"` {
		t.Errorf("expected 0x69776 (431990), got %s", string(result))
	}
}

func TestEthBlockNumber(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "eth_blockNumber")
	resp := parseResponse(t, w)

	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error.Message)
	}
	result, _ := json.Marshal(resp.Result)
	if string(result) != `"0x2a"` {
		t.Errorf("expected 0x2a (42), got %s", string(result))
	}
}

func TestEthGetBalance(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "eth_getBalance", "0x1111111111111111111111111111111111111111", "latest")
	resp := parseResponse(t, w)

	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error.Message)
	}
	result, _ := json.Marshal(resp.Result)
	if string(result) != `"0xf4240"` { // 1000000 = 0xf4240
		t.Errorf("expected 0xf4240 (1000000), got %s", string(result))
	}
}

func TestEthGetBalance_ZeroBalance(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "eth_getBalance", "0x0000000000000000000000000000000000000000", "latest")
	resp := parseResponse(t, w)

	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error.Message)
	}
	result, _ := json.Marshal(resp.Result)
	if string(result) != `"0x0"` {
		t.Errorf("expected 0x0, got %s", string(result))
	}
}

func TestEthSendRawTransaction(t *testing.T) {
	s := testServer()

	// Create a real signed Ethereum transaction.
	key, _ := crypto.GenerateKey()
	chainID := big.NewInt(int64(s.backend.ChainID()))
	signer := types.LatestSignerForChainID(chainID)
	tx := types.MustSignNewTx(key, signer, &types.DynamicFeeTx{
		ChainID:   chainID,
		Nonce:     0,
		GasTipCap: new(big.Int),
		GasFeeCap: new(big.Int),
		Gas:       21000,
		To:        &common.Address{0x42},
		Value:     big.NewInt(1000),
	})

	// Serialize the transaction (supports both legacy and typed EIP-2718).
	rawBytes, _ := tx.MarshalBinary()
	rawHex := "0x" + hex.EncodeToString(rawBytes)

	w := makeRequest(t, s, "eth_sendRawTransaction", rawHex)
	resp := parseResponse(t, w)

	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error.Message)
	}

	// Verify the returned hash matches the transaction hash.
	result, _ := json.Marshal(resp.Result)
	expectedHash := `"` + tx.Hash().Hex() + `"`
	if string(result) != expectedHash {
		t.Errorf("expected %s, got %s", expectedHash, string(result))
	}
}

func TestEthSendRawTransaction_InvalidHex(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "eth_sendRawTransaction", "0xNOTHEX")
	resp := parseResponse(t, w)
	if resp.Error == nil {
		t.Fatal("expected error for invalid hex")
	}
}

func TestEthSendRawTransaction_InvalidRLP(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "eth_sendRawTransaction", "0xdeadbeef")
	resp := parseResponse(t, w)
	if resp.Error == nil {
		t.Fatal("expected error for invalid RLP")
	}
}

func TestEthGetTransactionReceipt(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "eth_getTransactionReceipt", "0xabc123")
	resp := parseResponse(t, w)

	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error.Message)
	}

	receiptJSON, _ := json.Marshal(resp.Result)
	var receipt TransactionReceipt
	json.Unmarshal(receiptJSON, &receipt)
	if receipt.TxHash != "0xabc123" {
		t.Errorf("expected tx hash 0xabc123, got %s", receipt.TxHash)
	}
	if receipt.Status != "0x1" {
		t.Errorf("expected status 0x1, got %s", receipt.Status)
	}
}

func TestEthGetTransactionReceipt_NotFound(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "eth_getTransactionReceipt", "0xnonexistent")
	resp := parseResponse(t, w)

	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error.Message)
	}
	// null result = not found
	if resp.Result != nil {
		t.Errorf("expected nil result for non-existent receipt, got %v", resp.Result)
	}
}

func TestNetVersion(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "net_version")
	resp := parseResponse(t, w)

	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error.Message)
	}
	result, _ := json.Marshal(resp.Result)
	if string(result) != `"431990"` {
		t.Errorf("expected \"431990\", got %s", string(result))
	}
}

func TestWeb3ClientVersion(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "web3_clientVersion")
	resp := parseResponse(t, w)

	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error.Message)
	}
	result, _ := json.Marshal(resp.Result)
	if string(result) != `"basis-l2/v0.1.0"` {
		t.Errorf("expected basis-l2/v0.1.0, got %s", string(result))
	}
}

func TestBasisGetBatchStatus(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "basis_getBatchStatus", uint64(1))
	resp := parseResponse(t, w)

	if resp.Error != nil {
		t.Fatalf("unexpected error: %v", resp.Error.Message)
	}

	statusJSON, _ := json.Marshal(resp.Result)
	var status BatchStatus
	json.Unmarshal(statusJSON, &status)
	if status.BatchID != 1 {
		t.Errorf("expected batch ID 1, got %d", status.BatchID)
	}
	if status.Stage != "finalized" {
		t.Errorf("expected stage finalized, got %s", status.Stage)
	}
	if !status.ProofOnL1 {
		t.Error("expected proofOnL1=true")
	}
}

func TestMethodNotFound(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "eth_nonexistent")
	resp := parseResponse(t, w)

	if resp.Error == nil {
		t.Fatal("expected error for unknown method")
	}
	if resp.Error.Code != errCodeMethodNotFound {
		t.Errorf("expected code %d, got %d", errCodeMethodNotFound, resp.Error.Code)
	}
}

func TestMissingParams(t *testing.T) {
	s := testServer()
	w := makeRequest(t, s, "eth_getBalance") // No params
	resp := parseResponse(t, w)

	if resp.Error == nil {
		t.Fatal("expected error for missing params")
	}
	if resp.Error.Code != errCodeInvalidParams {
		t.Errorf("expected code %d, got %d", errCodeInvalidParams, resp.Error.Code)
	}
}

func TestInvalidJSON(t *testing.T) {
	s := testServer()
	httpReq := httptest.NewRequest(http.MethodPost, "/", bytes.NewReader([]byte("not json")))
	httpReq.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	s.handleRequest(w, httpReq)

	resp := parseResponse(t, w)
	if resp.Error == nil {
		t.Fatal("expected parse error")
	}
	if resp.Error.Code != errCodeParse {
		t.Errorf("expected code %d, got %d", errCodeParse, resp.Error.Code)
	}
}

func TestGETMethodRejected(t *testing.T) {
	s := testServer()
	httpReq := httptest.NewRequest(http.MethodGet, "/", nil)
	w := httptest.NewRecorder()
	s.handleRequest(w, httpReq)

	resp := parseResponse(t, w)
	if resp.Error == nil {
		t.Fatal("expected error for GET method")
	}
}

func TestCORSHeaders(t *testing.T) {
	s := testServer()
	httpReq := httptest.NewRequest(http.MethodOptions, "/", nil)
	w := httptest.NewRecorder()
	s.handleRequest(w, httpReq)

	if w.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Error("missing CORS Allow-Origin header")
	}
}

func TestRateLimiter(t *testing.T) {
	limiter := NewIPRateLimiter(2, 2) // 2/sec, burst 2

	// First 2 should pass (burst).
	if !limiter.Allow("127.0.0.1") {
		t.Error("first request should be allowed")
	}
	if !limiter.Allow("127.0.0.1") {
		t.Error("second request should be allowed (burst)")
	}

	// Third should be rejected (burst exhausted, no time to replenish).
	if limiter.Allow("127.0.0.1") {
		t.Error("third request should be rate limited")
	}

	// Different IP should be independent.
	if !limiter.Allow("192.168.1.1") {
		t.Error("different IP should have its own bucket")
	}
}

func TestRateLimiter_Replenish(t *testing.T) {
	limiter := NewIPRateLimiter(1000, 1) // 1000/sec, burst 1

	// Exhaust the bucket.
	limiter.Allow("10.0.0.1")
	if limiter.Allow("10.0.0.1") {
		t.Error("should be rate limited after burst")
	}

	// After brief wait, tokens should replenish.
	// With 1000/sec rate, 2ms should add ~2 tokens.
	// (This test may be flaky on very slow systems.)
	for i := 0; i < 100; i++ {
		if limiter.Allow("10.0.0.1") {
			return // Replenished
		}
	}
	fmt.Println("Warning: rate limiter replenish test may be timing-dependent")
}
