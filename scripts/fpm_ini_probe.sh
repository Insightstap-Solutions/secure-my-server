#!/usr/bin/env bash
# Read PHP settings FROM PHP-FPM (not the CLI, whose ini can differ).
# Needs cgi-fcgi (package libfcgi-bin) inside the container.
# Usage: bash fpm_ini_probe.sh <container> [fpm_address=127.0.0.1:9000]
#        ssh host 'bash -s -- my-app-container' < fpm_ini_probe.sh
set -euo pipefail
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
fpm_ini_probe.sh CONTAINER [FPM_ADDRESS=127.0.0.1:9000]
  Asks PHP-FPM itself (over FastCGI, with cgi-fcgi inside the container) for the effective values of
  display_errors, session.upload_progress.enabled, post_max_size, memory_limit, ... and prints the pool's
  pm settings. Writes ONE temporary probe file inside the container and removes it (it says so if not).
  Changes no configuration and restarts nothing.
EOF
  exit 0
fi
[ $# -ge 1 ] || { echo "usage: fpm_ini_probe.sh CONTAINER [FPM_ADDRESS]  (--help for details)" >&2; exit 2; }
C=${1:?container name}; ADDR=${2:-127.0.0.1:9000}
docker exec -i "$C" sh -s "$ADDR" <<'IN'
ADDR=$1; P=/tmp/ini_probe_$$.php
cat > "$P" <<'PHP'
<?php
foreach (["display_errors","display_startup_errors","log_errors","expose_php",
          "session.upload_progress.enabled","upload_max_filesize","post_max_size",
          "memory_limit","max_execution_time","max_input_time"] as $k)
    echo str_pad($k, 34), "= ", var_export(ini_get($k), true), "\n";
echo "sapi = ", PHP_SAPI, "   php = ", PHP_VERSION, "\n";
PHP
command -v cgi-fcgi >/dev/null || { echo "cgi-fcgi missing (install libfcgi-bin in the image)"; rm -f "$P"; exit 1; }
SCRIPT_FILENAME="$P" SCRIPT_NAME=/probe.php REQUEST_METHOD=GET cgi-fcgi -bind -connect "$ADDR" | sed '1,/^\r\{0,1\}$/d'
rm -f "$P"; [ -e "$P" ] && echo "WARNING: probe file not removed" || echo "(probe file removed)"
IN
echo "--- pool:"; docker exec "$C" php-fpm -tt 2>&1 | grep -E '\spm(\.[a-z_]+)? =' | sed 's/.*NOTICE: *//'
