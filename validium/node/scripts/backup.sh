#!/bin/bash
# Backup script for Basis Network Validium Node.
# Backs up WAL directory and SMT checkpoint.
#
# Usage: ./scripts/backup.sh [backup_dir]
# Default backup_dir: ./backups/$(date +%Y%m%d_%H%M%S)

set -euo pipefail

DATA_DIR="${DATA_DIR:-./data}"
BACKUP_DIR="${1:-./backups/$(date +%Y%m%d_%H%M%S)}"

echo "Validium Node Backup"
echo "  Data dir:   $DATA_DIR"
echo "  Backup dir: $BACKUP_DIR"

mkdir -p "$BACKUP_DIR"

# Backup WAL
if [ -d "$DATA_DIR/wal" ]; then
    cp -r "$DATA_DIR/wal" "$BACKUP_DIR/wal"
    echo "  WAL: $(du -sh "$BACKUP_DIR/wal" | cut -f1)"
else
    echo "  WAL: not found (skipped)"
fi

# Backup SMT checkpoint
if [ -f "$DATA_DIR/wal/smt-checkpoint.json" ]; then
    cp "$DATA_DIR/wal/smt-checkpoint.json" "$BACKUP_DIR/smt-checkpoint.json"
    echo "  SMT checkpoint: $(du -sh "$BACKUP_DIR/smt-checkpoint.json" | cut -f1)"
else
    echo "  SMT checkpoint: not found (skipped)"
fi

# Create metadata
cat > "$BACKUP_DIR/metadata.json" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "hostname": "$(hostname)",
  "data_dir": "$DATA_DIR"
}
EOF

echo ""
echo "Backup complete: $BACKUP_DIR ($(du -sh "$BACKUP_DIR" | cut -f1))"
