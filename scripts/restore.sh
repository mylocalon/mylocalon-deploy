#!/usr/bin/env bash
# Restore a backup into a database (default: mylocalon_restore, never the live one).
#   sudo -u postgres ./restore.sh /var/backups/mylocalon/mylocalon-2026....dump [target_db]
set -euo pipefail
dump="${1:?usage: restore.sh <file.dump> [target_db]}"
target="${2:-mylocalon_restore}"
createdb "$target"
pg_restore --no-owner --dbname="$target" "$dump"
echo "restored into $target — verify, then swap with ALTER DATABASE ... RENAME"
