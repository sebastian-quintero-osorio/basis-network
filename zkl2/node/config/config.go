// Package config provides configuration loading and validation for the Basis L2 node.
//
// Configuration is loaded from a YAML file and validated at startup.
// All configuration values have safe defaults documented in DefaultConfig().
package config

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

// Config holds the complete configuration for a Basis L2 node.
type Config struct {
	// L1 connection to Basis Network (Avalanche Subnet-EVM).
	L1 L1Config `json:"l1"`

	// L2 chain parameters.
	L2 L2Config `json:"l2"`

	// Contracts holds deployed contract addresses on L1.
	Contracts ContractAddresses `json:"contracts"`

	// Sequencer configuration.
	Sequencer SequencerConfig `json:"sequencer"`

	// Pipeline (proving pipeline) configuration.
	Pipeline PipelineConfig `json:"pipeline"`

	// Prover (Rust ZK prover) configuration.
	Prover ProverConfig `json:"prover"`

	// DAC (Data Availability Committee) configuration.
	DAC DACConfig `json:"dac"`

	// RPC server configuration.
	RPC RPCConfig `json:"rpc"`

	// Logging configuration.
	Log LogConfig `json:"log"`
}

// L1Config holds L1 connection parameters.
type L1Config struct {
	// RPCURL is the JSON-RPC endpoint for the Basis Network L1.
	RPCURL string `json:"rpc_url"`

	// ChainID is the L1 chain identifier (43199 for Basis Network).
	ChainID uint64 `json:"chain_id"`

	// PrivateKey is the hex-encoded private key for L1 transactions.
	// Loaded from environment variable L1_PRIVATE_KEY at runtime.
	PrivateKey string `json:"-"`

	// PollInterval is the interval for polling L1 for new events.
	PollInterval time.Duration `json:"poll_interval"`
}

// L2Config holds L2 chain parameters.
type L2Config struct {
	// ChainID is the L2 chain identifier.
	ChainID uint64 `json:"chain_id"`

	// BlockInterval is the target block production interval.
	BlockInterval time.Duration `json:"block_interval"`

	// BatchSize is the number of L2 blocks per proving batch.
	BatchSize int `json:"batch_size"`

	// GasLimit is the gas limit per L2 block.
	GasLimit uint64 `json:"gas_limit"`

	// DataDir is the path for persistent state storage (LevelDB).
	// If empty, state is ephemeral (in-memory only).
	DataDir string `json:"data_dir"`
}

// ContractAddresses holds deployed L1 contract addresses.
type ContractAddresses struct {
	BasisRollup        string `json:"basis_rollup"`
	BasisBridge        string `json:"basis_bridge"`
	BasisDAC           string `json:"basis_dac"`
	BasisHub           string `json:"basis_hub"`
	BasisAggregator    string `json:"basis_aggregator"`
	BasisVerifier      string `json:"basis_verifier"`
	EnterpriseRegistry string `json:"enterprise_registry"`
}

// SequencerConfig holds sequencer parameters.
type SequencerConfig struct {
	// MempoolCapacity is the maximum number of pending transactions.
	MempoolCapacity int `json:"mempool_capacity"`

	// ForcedInclusionDeadline is the maximum blocks before forced inclusion.
	ForcedInclusionDeadline uint64 `json:"forced_inclusion_deadline"`
}

// PipelineConfig holds proving pipeline parameters.
type PipelineConfig struct {
	// MaxRetries is the maximum retry attempts per pipeline stage.
	MaxRetries int `json:"max_retries"`

	// RetryBaseDelay is the base delay for exponential backoff.
	RetryBaseDelay time.Duration `json:"retry_base_delay"`

	// ProofTimeout is the maximum time to wait for proof generation.
	ProofTimeout time.Duration `json:"proof_timeout"`

	// MaxConcurrentBatches is the maximum batches proving in parallel.
	MaxConcurrentBatches int `json:"max_concurrent_batches"`
}

// ProverConfig holds ZK prover parameters.
type ProverConfig struct {
	// BinaryPath is the path to the Rust prover binary.
	BinaryPath string `json:"binary_path"`

	// WitnessTimeout is the max time for witness generation.
	WitnessTimeout time.Duration `json:"witness_timeout"`

	// ProveTimeout is the max time for proof generation.
	ProveTimeout time.Duration `json:"prove_timeout"`
}

// DACConfig holds Data Availability Committee parameters.
type DACConfig struct {
	// Enabled controls whether DAC mode is active.
	Enabled bool `json:"enabled"`

	// Threshold is the minimum attestations required for a certificate.
	Threshold int `json:"threshold"`

	// CommitteeSize is the total number of DAC nodes.
	CommitteeSize int `json:"committee_size"`

	// NodeURLs is the list of DAC node endpoints.
	NodeURLs []string `json:"node_urls"`
}

// RPCConfig holds JSON-RPC server parameters.
type RPCConfig struct {
	// Host is the bind address for the RPC server.
	Host string `json:"host"`

	// Port is the port for the RPC server.
	Port int `json:"port"`

	// RateLimitPerSec is the maximum requests per second per IP.
	RateLimitPerSec int `json:"rate_limit_per_sec"`

	// RateLimitBurst is the maximum burst size for rate limiting.
	RateLimitBurst int `json:"rate_limit_burst"`
}

// LogConfig holds logging parameters.
type LogConfig struct {
	// Level is the log level (debug, info, warn, error).
	Level string `json:"level"`

	// Format is the log format (json, text).
	Format string `json:"format"`
}

// DefaultConfig returns a Config with safe production defaults.
func DefaultConfig() *Config {
	return &Config{
		L1: L1Config{
			RPCURL:       "https://rpc.basisnetwork.com.co",
			ChainID:      43199,
			PollInterval: 5 * time.Second,
		},
		L2: L2Config{
			ChainID:       431990, // Default L2 chain ID
			BlockInterval: 2 * time.Second,
			BatchSize:     100,
			GasLimit:      30_000_000,
		},
		Contracts: ContractAddresses{
			BasisRollup:        "0x3984a7ab6d7f05A49d11C347b63E7bc7e5c95f49",
			BasisBridge:        "0x9Df0814CFBfE352C942bac682A378ff887486Dd8",
			BasisDAC:           "0xa7D5771fA69404438d79a1F8C192F7257A514691",
			BasisHub:           "0xBf997eFD945Fe99ECDD129C86De7f75355b1AC42",
			BasisAggregator:    "0x98272431b8B270CABeE37A158e01bdC3412744E2",
			BasisVerifier:      "0xFE9DF13c038414773Ac96189742b6c1f93999f29",
			EnterpriseRegistry: "0xB030b8c0aE2A9b5EE4B09861E088572832cd7EA5",
		},
		Sequencer: SequencerConfig{
			MempoolCapacity:         10000,
			ForcedInclusionDeadline: 7200, // ~24h at 12s blocks
		},
		Pipeline: PipelineConfig{
			MaxRetries:           3,
			RetryBaseDelay:       5 * time.Second,
			ProofTimeout:         5 * time.Minute,
			MaxConcurrentBatches: 2,
		},
		Prover: ProverConfig{
			BinaryPath:     "./target/release/basis-prover",
			WitnessTimeout: 30 * time.Second,
			ProveTimeout:   5 * time.Minute,
		},
		DAC: DACConfig{
			Enabled:       false,
			Threshold:     5,
			CommitteeSize: 7,
		},
		RPC: RPCConfig{
			Host:            "0.0.0.0",
			Port:            8545,
			RateLimitPerSec: 100,
			RateLimitBurst:  200,
		},
		Log: LogConfig{
			Level:  "info",
			Format: "json",
		},
	}
}

// LoadFromFile loads configuration from a JSON file, merging with defaults.
func LoadFromFile(path string) (*Config, error) {
	cfg := DefaultConfig()

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: read file %s: %w", path, err)
	}

	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("config: parse file %s: %w", path, err)
	}

	// Load sensitive values from environment.
	if key := os.Getenv("L1_PRIVATE_KEY"); key != "" {
		cfg.L1.PrivateKey = key
	}

	return cfg, nil
}

// Validate checks that the configuration is internally consistent.
func (c *Config) Validate() error {
	if c.L1.RPCURL == "" {
		return fmt.Errorf("config: l1.rpc_url is required")
	}
	if c.L1.ChainID == 0 {
		return fmt.Errorf("config: l1.chain_id is required")
	}
	if c.L2.ChainID == 0 {
		return fmt.Errorf("config: l2.chain_id is required")
	}
	if c.L2.BlockInterval <= 0 {
		return fmt.Errorf("config: l2.block_interval must be positive")
	}
	if c.L2.BatchSize <= 0 {
		return fmt.Errorf("config: l2.batch_size must be positive")
	}
	if c.RPC.Port <= 0 || c.RPC.Port > 65535 {
		return fmt.Errorf("config: rpc.port must be 1-65535")
	}
	if c.Pipeline.MaxRetries < 0 {
		return fmt.Errorf("config: pipeline.max_retries must be non-negative")
	}
	if c.DAC.Enabled {
		if c.DAC.Threshold <= 0 {
			return fmt.Errorf("config: dac.threshold must be positive when DAC is enabled")
		}
		if c.DAC.CommitteeSize < c.DAC.Threshold {
			return fmt.Errorf("config: dac.committee_size must be >= dac.threshold")
		}
	}
	return nil
}
