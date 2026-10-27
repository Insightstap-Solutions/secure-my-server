#!/usr/bin/env bash
# Run the plugin's checks: bash -n and shellcheck on scripts/*.sh, then the bats suite.
# Finds bats and shellcheck on PATH, or through $BATS_BIN / $SHELLCHECK_BIN.
#   tests/run.sh            everything
#   tests/run.sh FILE.bats  one bats file (shellcheck still runs)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(dirname "$here")
BATS=${BATS_BIN:-$(command -v bats || true)}
SHELLCHECK=${SHELLCHECK_BIN:-$(command -v shellcheck || true)}
rc=0

echo "== bash -n"
for f in "$repo"/scripts/*.sh "$here"/run.sh "$here"/shims/*; do
  bash -n "$f" || { echo "syntax error: $f"; rc=1; }
done

echo "== shellcheck"
if [[ -z $SHELLCHECK || ! -x $SHELLCHECK ]]; then
  echo "shellcheck not found: install it or set SHELLCHECK_BIN" >&2; rc=1
else
  (cd "$repo/scripts" && "$SHELLCHECK" -x -S style ./*.sh) && echo "shellcheck: clean" || rc=1
fi

echo "== bats"
if [[ -z $BATS || ! -x $BATS ]]; then
  echo "bats not found: install bats-core or set BATS_BIN" >&2; rc=1
else
  if [[ $# -gt 0 ]]; then "$BATS" "$@" || rc=1; else "$BATS" "$here" || rc=1; fi
fi
exit $rc
