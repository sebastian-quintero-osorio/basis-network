#!/usr/bin/env bash
# Download Validium circuit artifacts from GitHub Releases.
#
# These artifacts (proving key + compiled circuit) are required to run the
# Validium Node. They are not stored in git due to size (~130 MB total).
#
# Prerequisites: gh (GitHub CLI) authenticated, or curl.
#
# Usage:
#   bash scripts/download-circuit-artifacts.sh

set -euo pipefail

REPO="sebastian-quintero-osorio/basis-network"
TAG="circuit-v1.0.0"
DEST="validium/circuits/build/production"
WASM_DIR="${DEST}/state_transition_js"

ZKEY_SHA256="e5bcb51d72946385708a7e70ee32cbee71e70ed8111fc295505a2072bd8d2671"
WASM_SHA256="fd59f8410dbee5800106da1cc882bd67e64107c410601a191cac137ee20c0ef2"

echo "=== Downloading Validium Circuit Artifacts ==="
echo "Release: ${TAG}"
echo "Destination: ${DEST}"
echo ""

mkdir -p "${DEST}" "${WASM_DIR}"

# Download using gh if available, otherwise curl
if command -v gh &>/dev/null; then
  echo "[1/2] Downloading state_transition_final.zkey (127 MB)..."
  gh release download "${TAG}" --repo "${REPO}" --pattern "state_transition_final.zkey" --dir "${DEST}" --clobber

  echo "[2/2] Downloading state_transition.wasm (2.8 MB)..."
  gh release download "${TAG}" --repo "${REPO}" --pattern "state_transition.wasm" --dir "${WASM_DIR}" --clobber
else
  BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"

  echo "[1/2] Downloading state_transition_final.zkey (127 MB)..."
  curl -fSL "${BASE_URL}/state_transition_final.zkey" -o "${DEST}/state_transition_final.zkey"

  echo "[2/2] Downloading state_transition.wasm (2.8 MB)..."
  curl -fSL "${BASE_URL}/state_transition.wasm" -o "${WASM_DIR}/state_transition.wasm"
fi

# Verify checksums
echo ""
echo "Verifying checksums..."

ACTUAL_ZKEY=$(sha256sum "${DEST}/state_transition_final.zkey" | awk '{print $1}')
ACTUAL_WASM=$(sha256sum "${WASM_DIR}/state_transition.wasm" | awk '{print $1}')

PASS=true

if [ "${ACTUAL_ZKEY}" = "${ZKEY_SHA256}" ]; then
  echo "  state_transition_final.zkey: OK"
else
  echo "  state_transition_final.zkey: FAILED (expected ${ZKEY_SHA256}, got ${ACTUAL_ZKEY})"
  PASS=false
fi

if [ "${ACTUAL_WASM}" = "${WASM_SHA256}" ]; then
  echo "  state_transition.wasm: OK"
else
  echo "  state_transition.wasm: FAILED (expected ${WASM_SHA256}, got ${ACTUAL_WASM})"
  PASS=false
fi

echo ""
if [ "${PASS}" = true ]; then
  echo "All checksums verified. Circuit artifacts ready."
  echo ""
  echo "Files:"
  ls -lh "${DEST}/state_transition_final.zkey" "${WASM_DIR}/state_transition.wasm"
else
  echo "ERROR: Checksum verification failed. Files may be corrupted."
  exit 1
fi
