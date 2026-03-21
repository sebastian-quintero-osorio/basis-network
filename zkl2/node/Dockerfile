# Basis Network zkEVM L2 Node -- Multi-Stage Docker Build
#
# Stage 1: Build the Go binary
# Stage 2: Build the Rust prover binary
# Stage 3: Minimal runtime image
#
# Usage:
#   docker build -t basis-l2 -f zkl2/node/Dockerfile .
#   docker run --env-file zkl2/node/.env basis-l2

# ---------------------------------------------------------------------------
# Stage 1: Go Builder
# ---------------------------------------------------------------------------
FROM golang:1.24-bookworm AS go-builder

WORKDIR /build

# Copy go.mod and go.sum first for dependency caching.
COPY zkl2/node/go.mod zkl2/node/go.sum ./
RUN go mod download

# Copy source and build.
COPY zkl2/node/ ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-s -w -X main.version=0.1.0 -X main.buildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -o /basis-l2 \
    ./cmd/basis-l2/

# ---------------------------------------------------------------------------
# Stage 2: Rust Builder
# ---------------------------------------------------------------------------
FROM rust:1.83-bookworm AS rust-builder

WORKDIR /build

# Copy Cargo workspace files first for dependency caching.
COPY zkl2/prover/Cargo.toml zkl2/prover/Cargo.lock ./
COPY zkl2/prover/witness/Cargo.toml ./witness/
COPY zkl2/prover/circuit/Cargo.toml ./circuit/
COPY zkl2/prover/aggregator/Cargo.toml ./aggregator/

# Create dummy source files for dependency compilation.
RUN mkdir -p witness/src circuit/src aggregator/src && \
    echo "fn main() {}" > witness/src/lib.rs && \
    echo "fn main() {}" > circuit/src/lib.rs && \
    echo "fn main() {}" > aggregator/src/lib.rs && \
    cargo build --release 2>/dev/null || true

# Copy actual source and rebuild.
COPY zkl2/prover/ ./
RUN cargo build --release

# ---------------------------------------------------------------------------
# Stage 3: Runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

# Install minimal runtime dependencies.
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user.
RUN useradd -m -s /bin/bash basis

# Copy binaries from builder stages.
COPY --from=go-builder /basis-l2 /usr/local/bin/basis-l2
COPY --from=rust-builder /build/target/release/witness /usr/local/bin/witness-generator
COPY --from=rust-builder /build/target/release/circuit /usr/local/bin/basis-circuit
COPY --from=rust-builder /build/target/release/aggregator /usr/local/bin/basis-aggregator

# Set working directory and user.
WORKDIR /home/basis
USER basis

# Default port for JSON-RPC.
EXPOSE 8545

# Health check.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["basis-l2", "--version"]

ENTRYPOINT ["basis-l2"]
CMD ["--log-level", "info"]
