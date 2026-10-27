#!/usr/bin/env bash
# Is the LIVE code really in git? For each branch, count code files that differ from a live folder.
# Run ON THE SERVER inside (or pointing at) a git checkout that has the remote branches fetched.
# Usage: bash drift_check.sh <checkout_dir> <path_in_repo e.g. apps/api/app> <live_dir e.g. /root/app/app> [ref...]
#   With no refs: every remote branch matching develop|staging|main|master|prod/*|release/*
set -uo pipefail
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
drift_check.sh CHECKOUT_DIR PATH_IN_REPO LIVE_DIR [REF...]
  For each ref, counts code files that differ between the ref's PATH_IN_REPO and LIVE_DIR (rsync dry run).
  Read-only towards LIVE_DIR; runs `git fetch` in CHECKOUT_DIR and uses a temporary directory it removes.
  With no refs: every remote branch matching develop|staging|main|master|prod/*|release/*, plus HEAD.
EOF
  exit 0
fi
[ $# -ge 3 ] || { echo "usage: drift_check.sh CHECKOUT_DIR PATH_IN_REPO LIVE_DIR [REF...]  (--help for details)" >&2; exit 2; }
REPO=${1:?checkout dir}; SUB=${2:?path inside repo}; LIVE=${3:?live dir}; shift 3
cd "$REPO" || { echo "cannot cd to $REPO" >&2; exit 2; }
git fetch -q origin 2>/dev/null || true
refs=("$@")
[ ${#refs[@]} -gt 0 ] || mapfile -t refs < <(git branch -r --format='%(refname:short)' | grep -E 'origin/(develop|staging|main|master|prod/|release/)'; git rev-parse --short HEAD)
for r in "${refs[@]}"; do
  t=$(mktemp -d)
  if git archive "$r" "$SUB" 2>/dev/null | tar -x -C "$t" 2>/dev/null; then
    # -i is REQUIRED: rsync -n without -i prints nothing.
    n=$(sudo -n rsync -anci --delete --exclude='__pycache__' --exclude='*.pyc' --exclude='node_modules' "$t/$SUB/" "$LIVE/" 2>/dev/null \
        | grep -cE '^[<>]f.?c|^\*deleting|^>f\+')
    printf '%-45s %4s files differ  (%s)\n' "$r" "$n" "$(git log -1 --format='%h %ad' --date=short "$r")"
  fi
  rm -rf "$t"
done | sort -k2 -n
echo "0 = live matches that ref. If no ref is 0, a deploy would DELETE live-only code: snapshot live first."
