#!/bin/bash
# Restore script for Basis Network Validium Node.
# Restores WAL and SMT checkpoint from a backup.
#
# Usage: ./scripts/restore.sh <backup_dir>
# WARNING: This overwrites the current data directory.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <backup_dir>"
    echo "  Restores WAL and SMT checkpoint from a backup directory."
    exit 1
fi

BACKUP_DIR="$1"
DATA_DIR="${DATA_DIR:-./data}"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "Error: Backup directory not found: $BACKUP_DIR"
    exit 1
fi

echo "Validium Node Restore"
echo "  Backup dir: $BACKUP_DIR"
echo "  Data dir:   $DATA_DIR"

# Verify metadata
if [ -f "$BACKUP_DIR/metadata.json" ]; then
    echo "  Backup metadata:"
    cat "$BACKUP_DIR/metadata.json"
    echo ""
fi

# Restore WAL
if [ -d "$BACKUP_DIR/wal" ]; then
    mkdir -p "$DATA_DIR"
    rm -rf "$DATA_DIR/wal"
    cp -r "$BACKUP_DIR/wal" "$DATA_DIR/wal"
    echo "  WAL restored: $(du -sh "$DATA_DIR/wal" | cut -f1)"
else
    echo "  WAL: not in backup (skipped)"
fi

# Restore SMT checkpoint
if [ -f "$BACKUP_DIR/smt-checkpoint.json" ]; then
    mkdir -p "$DATA_DIR/wal"
    cp "$BACKUP_DIR/smt-checkpoint.json" "$DATA_DIR/wal/smt-checkpoint.json"
    echo "  SMT checkpoint restored"
else
    echo "  SMT checkpoint: not in backup (skipped)"
fi

echo ""
echo "Restore complete. Start the node to replay WAL and recover state."
