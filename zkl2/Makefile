# Basis Network zkEVM L2 -- Build System
#
# Targets:
#   make build          Build all binaries (Go + Rust)
#   make test           Run all tests (Go + Rust + Solidity)
#   make lint           Run linters
#   make clean          Remove build artifacts
#   make docker-build   Build Docker image
#   make docker-up      Start via Docker Compose
#   make docker-down    Stop Docker Compose

.PHONY: build build-go build-rust test test-go test-rust test-contracts lint clean docker-build docker-up docker-down

# Build all binaries.
build: build-go build-rust

build-go:
	cd node && go build -ldflags="-s -w" -o ../bin/basis-l2 ./cmd/basis-l2/
	@echo "Built: bin/basis-l2"

build-rust:
	cd prover && cargo build --release
	@echo "Built: prover/target/release/"

# Run all tests.
test: test-go test-rust test-contracts

test-go:
	cd node && go test ./... -count=1 -timeout 120s
	cd bridge && go test ./... -count=1 -timeout 60s

test-rust:
	cd prover && cargo test

test-contracts:
	cd contracts && npx hardhat test

# Lint all code.
lint: lint-go lint-rust

lint-go:
	cd node && go vet ./...
	cd bridge && go vet ./...

lint-rust:
	cd prover && cargo clippy -- -D warnings

# Clean build artifacts.
clean:
	rm -rf bin/
	cd prover && cargo clean

# Docker targets.
docker-build:
	cd .. && docker build -t basis-l2 -f zkl2/node/Dockerfile .

docker-up:
	cd .. && docker compose -f zkl2/docker-compose.yml up -d

docker-down:
	cd .. && docker compose -f zkl2/docker-compose.yml down
