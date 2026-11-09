#!/usr/bin/env bash
# Daily logical backup of the source-of-truth database. Redis is not backed
# up on purpose: it only holds disposable runtime state (ARCHITECTURE.md §5).
set -euo pipefail
BACKUP_DIR="${BACKUP_DIR:-/var/backups/mylocalon}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
DB="${DB:-mylocalon}"

umask 077
mkdir -p "$BACKUP_DIR"
out="$BACKUP_DIR/$DB-$(date -u +%Y%m%dT%H%M%SZ).dump"
pg_dump --format=custom --no-owner "$DB" > "$out.tmp"
pg_restore --list "$out.tmp" > /dev/null   # fail loudly on a corrupt dump
mv "$out.tmp" "$out"
find "$BACKUP_DIR" -name "$DB-*.dump" -mtime +"$RETENTION_DAYS" -delete
echo "backup ok: $out ($(du -h "$out" | cut -f1))"
