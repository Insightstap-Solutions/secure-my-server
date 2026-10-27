#!/usr/bin/env bash
# List secret-bearing keys in env files WITHOUT printing any value.
# Usage (on the server, as a user who can read the files):
#   bash env_inventory.sh "app-prod=/path/to/.env" "app-staging=/path/.env.staging" | column -t -s'|'
#   ssh host 'sudo -n bash -s -- "app-prod=/srv/app/.env"' < env_inventory.sh | column -t -s'|'
# Output: label|KEY|class|group   (group G1, G2... = the SAME value appears under more than one label)
set -uo pipefail
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
env_inventory.sh LABEL=/path/to/envfile [...]
  Lists secret-bearing KEYS in env files and classifies their values (empty, placeholder, set, ...)
  WITHOUT printing any value. Values shared across labels are grouped (G1, G2...) by a hash prefix.
  Read-only: reads the named files; uses one temporary file (mode 600) that is removed on exit.
  Output: label|KEY|class|group
EOF
  exit 0
fi
[ $# -gt 0 ] || { echo "usage: $0 label=/path/to/envfile [...]" >&2; exit 2; }
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT; chmod 600 "$TMP"
for pair in "$@"; do
  label=${pair%%=*}; f=${pair#*=}
  [ -f "$f" ] || { echo "$label|-|FILE MISSING|"; continue; }
  sed '1s/^\xEF\xBB\xBF//' "$f" | tr -d '\r' | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' | while IFS= read -r line; do
    k=${line%%=*}; v=${line#*=}; v=${v%\"}; v=${v#\"}; v=${v%\'}; v=${v#\'}
    s=0
    [[ $k =~ (KEY|SECRET|TOKEN|PASSWORD|PASSWD|PASS$|PWD|DSN|CREDENTIAL|PRIVATE|SALT|SIGNING|WEBHOOK) ]] && s=1
    [[ $v =~ ://[^/@:]*:[^/@]+@ ]] && s=1
    [ $s = 1 ] || continue
    [[ $k =~ (PUBLIC|PUBLISHABLE|_ID$|_ENDPOINT$|_HOST$|_PORT$|_PREFIX$|_MODEL$|_BUCKET$|_PROFILE$|_EXPIRE) && ! $k =~ SECRET ]] && continue
    sv=$v; [[ $v =~ ://[^/@:]*:([^/@]+)@ ]] && sv=${BASH_REMATCH[1]}
    lc=$(printf %s "$sv" | tr '[:upper:]' '[:lower:]')
    if   [ -z "$sv" ]; then c=empty
    elif [[ $lc =~ ^(null|none)$ ]]; then c="empty(null)"
    elif [[ $lc =~ ^(changeme|change_me|change-me|secret|password|xxx+|todo|placeholder)$ || $lc =~ (your[-_]|example|placeholder|changeme|change_me) ]]; then c=PLACEHOLDER/WEAK
    elif [[ $sv =~ ^(sk|rk)_live_ ]]; then c=STRIPE-LIVE-SECRET
    elif [[ $sv =~ ^whsec_ ]]; then c=webhook-signing-secret
    elif [[ $sv =~ ^(sk|rk)_test_ ]]; then c=stripe-test
    elif [[ $sv =~ ^pk_ ]]; then continue
    elif [ ${#sv} -lt 12 ]; then c="set(short:${#sv})"
    else c="set"; fi
    h=-; [ -n "$sv" ] && h=$(printf %s "$sv" | sha256sum | cut -c1-16)
    echo "$label|$k|$c|$h" >> "$TMP"
  done
done
awk -F'|' '{ r[NR]=$0; if ($4!="-" && !(($4 SUBSEP $1) in s)) { s[$4 SUBSEP $1]=1; n[$4]++ } }
  END { g=0; for (i=1;i<=NR;i++) { split(r[i],a,"|"); h=a[4]; t="";
        if (h!="-" && n[h]>1) { if (!(h in id)) id[h]="G" (++g); t=id[h] }
        print a[1] "|" a[2] "|" a[3] "|" t } }' "$TMP"
