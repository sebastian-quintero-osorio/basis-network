#!/bin/bash
# Setup and run script for EVM Executor Experiment (RU-L1)
# Requires: Go 1.22+
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh

set -euo pipefail

echo "=== EVM Executor Experiment Setup ==="

# Check Go version
if ! command -v go &> /dev/null; then
    echo "ERROR: Go is not installed."
    echo "Install Go 1.22+ from https://go.dev/dl/"
    echo "On Windows: winget install GoLang.Go"
    echo "On Ubuntu:  sudo snap install go --classic"
    exit 1
fi

GO_VERSION=$(go version | awk '{print $3}')
echo "Go version: ${GO_VERSION}"

# Initialize module and download dependencies
echo "Downloading go-ethereum dependency..."
go mod tidy

echo "Resolving dependency graph..."
go mod download

# Show dependency size
echo ""
echo "=== Dependency Analysis ==="
go list -m all | wc -l | xargs -I{} echo "Total Go modules: {}"

# Count lines in key Geth packages
echo ""
echo "=== Geth Module Size Analysis ==="
GOPATH=$(go env GOPATH)
GETH_PATH="${GOPATH}/pkg/mod/github.com/ethereum/go-ethereum@v1.14.12"

if [ -d "${GETH_PATH}" ]; then
    echo "core/vm/:"
    find "${GETH_PATH}/core/vm" -name "*.go" -not -name "*_test.go" | xargs wc -l | tail -1
    echo "core/state/:"
    find "${GETH_PATH}/core/state" -name "*.go" -not -name "*_test.go" | xargs wc -l | tail -1
    echo "core/types/:"
    find "${GETH_PATH}/core/types" -name "*.go" -not -name "*_test.go" | xargs wc -l | tail -1
    echo "core/tracing/:"
    find "${GETH_PATH}/core/tracing" -name "*.go" -not -name "*_test.go" | xargs wc -l | tail -1
    echo "ethdb/:"
    find "${GETH_PATH}/ethdb" -name "*.go" -not -name "*_test.go" | xargs wc -l | tail -1
    echo ""
    echo "Total Geth codebase:"
    find "${GETH_PATH}" -name "*.go" -not -name "*_test.go" | xargs wc -l | tail -1
else
    echo "Warning: Geth module not found at expected path"
    echo "Run 'go mod download' first"
fi

# Build
echo ""
echo "=== Building ==="
go build -o evm-experiment .
echo "Build successful: ./evm-experiment"

# Run
echo ""
echo "=== Running Experiment ==="
./evm-experiment

echo ""
echo "=== Done ==="
