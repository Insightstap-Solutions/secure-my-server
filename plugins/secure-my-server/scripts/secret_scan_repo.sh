#!/usr/bin/env bash
# Find REAL secret values (and common key patterns) inside a git repo's tracked files.
# Never prints a secret: only file names, needle numbers, lengths and masked prefixes.
# Usage: bash secret_scan_repo.sh <repo_dir> [needles_file]
#   needles_file: one real secret value per line, built from the server env files with umask 077,
#   e.g.  ssh host 'sudo -n bash -s' < build_needles.sh > needles.txt ; DELETE it afterwards.
set -euo pipefail
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
secret_scan_repo.sh REPO_DIR [NEEDLES_FILE]
  Looks for real secret values (from NEEDLES_FILE, built by build_needles.sh) and common key patterns in
  the repo's tracked files. Read-only. Never prints a secret: only file names, needle numbers, lengths
  and an 8-character masked prefix of pattern matches.
EOF
  exit 0
fi
[ $# -ge 1 ] || { echo "usage: secret_scan_repo.sh REPO_DIR [NEEDLES_FILE]  (--help for details)" >&2; exit 2; }
REPO=${1:?repo dir}; NEEDLES=${2:-}
cd "$REPO"
python3 - "$NEEDLES" <<'PY'
import re, subprocess, sys
needles = [l.rstrip("\n") for l in open(sys.argv[1])] if sys.argv[1] else []
needles = [n for n in needles if len(n) >= 12]
pat = re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]{20,}|\bsk-[A-Za-z0-9]{40,}|standard_[a-f0-9]{100,}"
                 r"|whsec_[A-Za-z0-9]{20,}|sk_live_[A-Za-z0-9]{20,}|rk_live_[A-Za-z0-9]+|AKIA[0-9A-Z]{16}"
                 r"|pcsk_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY")
example = re.compile(r"(x{6,}|X{6,}|\.\.\.|your|example|0{10,}|1234)", re.I)
files = subprocess.run(["git", "ls-files"], capture_output=True, text=True).stdout.splitlines()
total = 0
for f in files:
    try: txt = open(f, encoding="utf-8", errors="replace").read()
    except (IsADirectoryError, FileNotFoundError): continue
    hits = [f"real-secret#{i} (len {len(n)}) x{txt.count(n)}" for i, n in enumerate(needles) if n in txt]
    for m in set(pat.findall(txt)):
        real = any(n in m or m in n for n in needles)
        kind = "=REAL" if real else ("example?" if example.search(m) else "LOOKS-REAL")
        hits.append(f"pattern {m[:8]}… (len {len(m)}) {kind}")
    if hits:
        total += 1
        print(f + "\n    " + "\n    ".join(sorted(set(hits))))
print(f"\nfiles with hits: {total}. Map 'real-secret#N' to a key name WITHOUT printing it, redact real ones")
print("with [REDACTED], re-scan to 0, and remember: history and clones still hold them -> ROTATE.")
PY
