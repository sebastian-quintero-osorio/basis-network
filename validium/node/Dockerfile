# Basis Network Enterprise Validium Node
#
# Multi-stage build for production deployment.
# Stage 1: Build TypeScript to JavaScript
# Stage 2: Production image with minimal footprint
#
# Usage:
#   docker build -t basis-validium-node .
#   docker run --env-file .env -p 3000:3000 -v $(pwd)/data:/app/data basis-validium-node

# ---------------------------------------------------------------------------
# Stage 1: Build
# ---------------------------------------------------------------------------
FROM node:22-alpine AS builder

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci --production=false

COPY tsconfig.json ./
COPY src/ ./src/

RUN npx tsc

# ---------------------------------------------------------------------------
# Stage 2: Production
# ---------------------------------------------------------------------------
FROM node:22-alpine AS production

WORKDIR /app

# Install production dependencies only
COPY package.json package-lock.json* ./
RUN npm ci --production && npm cache clean --force

# Copy compiled JavaScript
COPY --from=builder /app/dist ./dist

# Create data directory for WAL and checkpoints
RUN mkdir -p /app/data/wal && chown -R node:node /app/data

# Circuit artifacts must be mounted at runtime
# Default paths: /app/circuits/state_transition.wasm and /app/circuits/state_transition_final.zkey

USER node

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "dist/index.js"]
