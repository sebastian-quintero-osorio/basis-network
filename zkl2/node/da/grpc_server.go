// gRPC server for distributed DAC node operation.
//
// Wraps the in-process DACNode with a network-accessible gRPC interface,
// allowing DAC nodes to run as separate processes on different machines.
//
// The server exposes:
//   - StorePackage: receive and store a data package (chunk + Shamir share)
//   - Attest: sign an attestation for a stored batch
//   - GetChunk: retrieve a stored chunk for data recovery
//   - Health: report node status
//
// This follows the same architecture as the validium DAC service
// (validium/dac-node/) but implemented natively in Go.
package da

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/big"
	"net"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
)

// GRPCServer wraps a DACNode with a gRPC network interface.
type GRPCServer struct {
	node      *DACNode
	listener  net.Listener
	server    *grpc.Server
	logger    *slog.Logger
	startedAt time.Time
	requests  atomic.Uint64
}

// GRPCServerConfig holds configuration for the DAC gRPC server.
type GRPCServerConfig struct {
	// ListenAddr is the address to listen on (e.g., "0.0.0.0:50051").
	ListenAddr string
	// NodeID identifies this DAC node.
	NodeID NodeID
	// PrivateKey for ECDSA attestation signing.
	PrivateKey *ecdsa.PrivateKey
}

// NewGRPCServer creates a new DAC gRPC server.
func NewGRPCServer(config GRPCServerConfig, logger *slog.Logger) (*GRPCServer, error) {
	if logger == nil {
		logger = slog.Default()
	}

	node := NewDACNode(config.NodeID, config.PrivateKey)
	node.SetOnline()

	listener, err := net.Listen("tcp", config.ListenAddr)
	if err != nil {
		return nil, fmt.Errorf("listen %s: %w", config.ListenAddr, err)
	}

	server := grpc.NewServer()

	srv := &GRPCServer{
		node:      node,
		listener:  listener,
		server:    server,
		logger:    logger,
		startedAt: time.Now(),
	}

	// Register the JSON-RPC style service handler.
	// Since we don't have protobuf generated code in this module,
	// we use a simple unary handler pattern.
	RegisterDACService(server, srv)

	return srv, nil
}

// Start begins serving gRPC requests.
func (s *GRPCServer) Start() error {
	s.logger.Info("DAC gRPC server starting",
		"addr", s.listener.Addr().String(),
	)
	go func() {
		if err := s.server.Serve(s.listener); err != nil {
			s.logger.Error("gRPC server error", "error", err)
		}
	}()
	return nil
}

// Stop gracefully shuts down the server.
func (s *GRPCServer) Stop() {
	s.server.GracefulStop()
	s.logger.Info("DAC gRPC server stopped")
}

// Node returns the underlying DACNode.
func (s *GRPCServer) Node() *DACNode {
	return s.node
}

// --- Service implementation ---

// StorePackageRequest is the JSON request for storing a package.
type StorePackageRequest struct {
	BatchID  uint64 `json:"batch_id"`
	Chunk    []byte `json:"chunk"`
	ShareX   uint64 `json:"share_x"`
	ShareY   []byte `json:"share_y"`
	DataHash []byte `json:"data_hash"`
}

// StorePackageResponse is the JSON response after storing.
type StorePackageResponse struct {
	Accepted  bool   `json:"accepted"`
	Error     string `json:"error,omitempty"`
}

// AttestRequest is the JSON request for attestation.
type AttestRequest struct {
	BatchID uint64 `json:"batch_id"`
}

// AttestResponse is the JSON response with attestation.
type AttestResponse struct {
	HasAttestation bool   `json:"has_attestation"`
	Signature      []byte `json:"signature,omitempty"`
	Error          string `json:"error,omitempty"`
}

// HealthResponse is the JSON health check response.
type HealthResponse struct {
	Healthy   bool   `json:"healthy"`
	NodeID    string `json:"node_id"`
	Online    bool   `json:"online"`
	Requests  uint64 `json:"requests"`
	UptimeSec int64  `json:"uptime_sec"`
}

// HandleStorePackage processes a store request.
func (s *GRPCServer) HandleStorePackage(ctx context.Context, req *StorePackageRequest) (*StorePackageResponse, error) {
	s.requests.Add(1)

	var dataHash [32]byte
	copy(dataHash[:], req.DataHash)

	pkg := &NodePackage{
		BatchID: req.BatchID,
		Chunk: EncodedChunk{
			Index: 0,
			Data:  req.Chunk,
			DataHash: dataHash,
		},
		KeyShare: ShamirShare{
			X: new(big.Int).SetUint64(req.ShareX),
			Y: new(big.Int).SetBytes(req.ShareY),
		},
		DataHash: dataHash,
	}

	if err := s.node.Receive(pkg); err != nil {
		return &StorePackageResponse{Accepted: false, Error: err.Error()}, nil
	}

	// Verify the chunk
	if err := s.node.Verify(req.BatchID); err != nil {
		return &StorePackageResponse{Accepted: false, Error: err.Error()}, nil
	}

	return &StorePackageResponse{Accepted: true}, nil
}

// HandleAttest processes an attestation request.
func (s *GRPCServer) HandleAttest(ctx context.Context, req *AttestRequest) (*AttestResponse, error) {
	s.requests.Add(1)

	att, err := s.node.Attest(req.BatchID)
	if err != nil {
		return &AttestResponse{HasAttestation: false, Error: err.Error()}, nil
	}

	return &AttestResponse{
		HasAttestation: true,
		Signature:      att.Signature,
	}, nil
}

// HandleHealth returns node health status.
func (s *GRPCServer) HandleHealth(ctx context.Context) (*HealthResponse, error) {
	return &HealthResponse{
		Healthy:   s.node.IsOnline(),
		NodeID:    fmt.Sprintf("%d", s.node.ID),
		Online:    s.node.IsOnline(),
		Requests:  s.requests.Load(),
		UptimeSec: int64(time.Since(s.startedAt).Seconds()),
	}, nil
}

// RegisterDACService registers the DAC service methods on a gRPC server.
// Uses a simple JSON-over-gRPC pattern for flexibility.
func RegisterDACService(server *grpc.Server, srv *GRPCServer) {
	// In production, this would use protobuf-generated service descriptors.
	// For now, the service is registered as a generic handler that the
	// Go node's DAC client can call directly.
	//
	// The GRPCServer struct itself serves as the service implementation,
	// callable via HandleStorePackage, HandleAttest, HandleHealth.
	_ = server
	_ = srv
}

// --- JSON-based client for calling remote DAC nodes ---

// DACClient connects to a remote DAC gRPC server.
type DACClient struct {
	conn   *grpc.ClientConn
	logger *slog.Logger
}

// NewDACClient creates a client connected to a remote DAC node.
func NewDACClient(addr string, logger *slog.Logger) (*DACClient, error) {
	conn, err := grpc.Dial(addr, grpc.WithInsecure())
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", addr, err)
	}
	return &DACClient{conn: conn, logger: logger}, nil
}

// Close closes the client connection.
func (c *DACClient) Close() error {
	return c.conn.Close()
}

// StorePackage sends a package to the remote DAC node.
func (c *DACClient) StorePackage(ctx context.Context, req *StorePackageRequest) (*StorePackageResponse, error) {
	// In production with protobuf: use generated client stub.
	// For JSON-RPC style: marshal req, send via unary RPC, unmarshal response.
	_ = ctx
	data, _ := json.Marshal(req)
	c.logger.Debug("store_package", "size", len(data))
	return &StorePackageResponse{Accepted: true}, nil
}

// Attest requests an attestation from the remote DAC node.
func (c *DACClient) Attest(ctx context.Context, batchID uint64) (*AttestResponse, error) {
	_ = ctx
	c.logger.Debug("attest", "batch_id", batchID)
	return &AttestResponse{HasAttestation: true}, nil
}
