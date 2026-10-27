#!/usr/bin/env bash
# Print real secret VALUES from env files, one per line, for secret_scan_repo.sh.
# This output IS secret: redirect it straight into a file created with umask 077, never to the screen.
# Usage: umask 077; ssh host 'sudo -n bash -s -- /path/.env /path/.env.staging' < build_needles.sh > needles.txt
set -uo pipefail
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
build_needles.sh ENV_FILE [ENV_FILE...]
  Prints the secret VALUES (>= 16 chars, placeholders dropped) found in the given env files, one per
  line, as input for secret_scan_repo.sh. Reads only the named files; writes nothing itself.
  THE OUTPUT IS SECRET: redirect it into a file created under `umask 077` and delete that file after use.
EOF
  exit 0
fi
[ $# -gt 0 ] || { echo "usage: build_needles.sh ENV_FILE [ENV_FILE...]  (--help for details)" >&2; exit 2; }
for f in "$@"; do [ -f "$f" ] || continue
  sed '1s/^\xEF\xBB\xBF//' "$f" | tr -d '\r' \
  | grep -E '^[A-Z_]*(KEY|SECRET|PASSWORD|TOKEN|DSN)[A-Z_]*=|^(DATABASE_URL|REDIS_URL)=' | cut -d= -f2- | tr -d '"'"'" \
  | sed -E 's#^[a-z+]+://[^:/@]*:([^@]+)@.*#\1#' | grep -vE '^[a-z+]+://' ; done \
 | awk 'length($0) >= 16' | grep -viE '^(none|null|true|false)$|changeme|change_me|your[-_]|example|placeholder' | sort -u
