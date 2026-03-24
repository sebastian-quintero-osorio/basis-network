package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDefaultConfig(t *testing.T) {
	cfg := DefaultConfig()

	if cfg.L1.ChainID != 43199 {
		t.Errorf("expected L1 chain ID 43199, got %d", cfg.L1.ChainID)
	}
	if cfg.L2.ChainID != 431990 {
		t.Errorf("expected L2 chain ID 431990, got %d", cfg.L2.ChainID)
	}
	if cfg.L2.BlockInterval != 2*time.Second {
		t.Errorf("expected 2s block interval, got %v", cfg.L2.BlockInterval)
	}
	if cfg.RPC.Port != 8545 {
		t.Errorf("expected RPC port 8545, got %d", cfg.RPC.Port)
	}
	if cfg.Log.Level != "info" {
		t.Errorf("expected log level info, got %s", cfg.Log.Level)
	}
}

func TestDefaultConfigValidation(t *testing.T) {
	cfg := DefaultConfig()
	if err := cfg.Validate(); err != nil {
		t.Errorf("default config should validate: %v", err)
	}
}

func TestValidation_MissingRPCURL(t *testing.T) {
	cfg := DefaultConfig()
	cfg.L1.RPCURL = ""
	if err := cfg.Validate(); err == nil {
		t.Error("expected validation error for empty L1 RPC URL")
	}
}

func TestValidation_InvalidPort(t *testing.T) {
	cfg := DefaultConfig()
	cfg.RPC.Port = 0
	if err := cfg.Validate(); err == nil {
		t.Error("expected validation error for port 0")
	}

	cfg.RPC.Port = 70000
	if err := cfg.Validate(); err == nil {
		t.Error("expected validation error for port 70000")
	}
}

func TestValidation_DACEnabled(t *testing.T) {
	cfg := DefaultConfig()
	cfg.DAC.Enabled = true
	cfg.DAC.Threshold = 0
	if err := cfg.Validate(); err == nil {
		t.Error("expected validation error for zero DAC threshold")
	}

	cfg.DAC.Threshold = 5
	cfg.DAC.CommitteeSize = 3
	if err := cfg.Validate(); err == nil {
		t.Error("expected validation error for committee < threshold")
	}

	cfg.DAC.CommitteeSize = 7
	if err := cfg.Validate(); err != nil {
		t.Errorf("valid DAC config should pass: %v", err)
	}
}

func TestValidation_NegativeRetries(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Pipeline.MaxRetries = -1
	if err := cfg.Validate(); err == nil {
		t.Error("expected validation error for negative retries")
	}
}

func TestLoadFromFile(t *testing.T) {
	// Create a temporary config file.
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	content := `{
		"l2": {
			"chain_id": 999,
			"batch_size": 50
		},
		"rpc": {
			"port": 9545
		}
	}`
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := LoadFromFile(path)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}

	// Overridden values.
	if cfg.L2.ChainID != 999 {
		t.Errorf("expected chain ID 999, got %d", cfg.L2.ChainID)
	}
	if cfg.L2.BatchSize != 50 {
		t.Errorf("expected batch size 50, got %d", cfg.L2.BatchSize)
	}
	if cfg.RPC.Port != 9545 {
		t.Errorf("expected port 9545, got %d", cfg.RPC.Port)
	}

	// Default values preserved.
	if cfg.L1.ChainID != 43199 {
		t.Errorf("expected default L1 chain ID 43199, got %d", cfg.L1.ChainID)
	}
	if cfg.Log.Level != "info" {
		t.Errorf("expected default log level info, got %s", cfg.Log.Level)
	}
}

func TestLoadFromFile_MissingFile(t *testing.T) {
	_, err := LoadFromFile("/nonexistent/path/config.json")
	if err == nil {
		t.Error("expected error for missing file")
	}
}

func TestLoadFromFile_InvalidJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bad.json")
	if err := os.WriteFile(path, []byte("not json"), 0644); err != nil {
		t.Fatalf("write file: %v", err)
	}

	_, err := LoadFromFile(path)
	if err == nil {
		t.Error("expected error for invalid JSON")
	}
}

func TestLoadFromFile_EnvOverride(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, []byte("{}"), 0644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	t.Setenv("L1_PRIVATE_KEY", "abc123")

	cfg, err := LoadFromFile(path)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}

	if cfg.L1.PrivateKey != "abc123" {
		t.Errorf("expected private key from env, got %q", cfg.L1.PrivateKey)
	}
}
