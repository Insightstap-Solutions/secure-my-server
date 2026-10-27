# Shared bats helpers. Every test runs with PATH restricted to a sandbox bin dir that holds the
# core tools the scripts are allowed to use plus the shims a test asks for, so nothing on this
# machine (real docker, ss, dpkg...) leaks into a result.
SCRIPTS="$BATS_TEST_DIRNAME/../plugins/secure-my-server/scripts"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"
SHIMS="$BATS_TEST_DIRNAME/shims"
SMS_ORIG_PATH=${SMS_ORIG_PATH:-$PATH}
# bats needs its own tools back after each test
teardown() { export PATH="$SMS_ORIG_PATH"; }
SMS_CORE_TOOLS="bash sh env cat grep sed awk find sort head tail cut tr wc uniq readlink dirname basename \
stat date sha256sum zcat gzip timeout ls printf id od xargs test true false mkdir paste"

# setup_sandbox FIXTURE [SHIM...]   FIXTURE may be "-" for none
setup_sandbox() {
  local fixture=$1 t p; shift
  export PATH="$SMS_ORIG_PATH"
  SBX="$BATS_TEST_TMPDIR/sbx"
  rm -rf "$SBX"; mkdir -p "$SBX/bin"
  for t in $SMS_CORE_TOOLS; do
    p=$(type -P "$t") && ln -sf "$p" "$SBX/bin/$t"
  done
  for t in "$@"; do cp "$SHIMS/$t" "$SBX/bin/$t"; chmod +x "$SBX/bin/$t"; done
  # SMS_TEST_AWK=/usr/bin/gawk (or "busybox") runs the suite against another awk implementation
  if [ -n "${SMS_TEST_AWK:-}" ]; then
    rm -f "$SBX/bin/awk"
    if [ "$SMS_TEST_AWK" = busybox ]; then printf '#!/bin/sh\nexec %s awk "$@"\n' "$(type -P busybox)" >"$SBX/bin/awk"
    else printf '#!/bin/sh\nexec %s "$@"\n' "$SMS_TEST_AWK" >"$SBX/bin/awk"; fi
    chmod +x "$SBX/bin/awk"
  fi
  ROOT=""
  # real tools for test set-up only (the scripts under test never see them)
  TOUCH=$(type -P touch); HEAD=$(type -P head); CP=$(type -P cp)
  if [ "$fixture" != "-" ]; then
    cp -a "$FIXTURES/$fixture/root" "$SBX/root"
    # Symlinks and NUL bytes are kept out of git (plugin directories refuse them):
    # links.tsv lists "path<TAB>target", and *.nulsrc files get each newline turned into a NUL.
    local lp lt n
    if [ -f "$FIXTURES/$fixture/links.tsv" ]; then
      while IFS=$'\t' read -r lp lt; do
        [ -n "$lp" ] || continue
        mkdir -p "$(dirname "$SBX/root/$lp")"; ln -s "$lt" "$SBX/root/$lp"
      done <"$FIXTURES/$fixture/links.tsv"
    fi
    while IFS= read -r n; do tr '\n' '\000' <"$n" >"${n%.nulsrc}"; rm -f "$n"; done < <(find "$SBX/root" -type f -name '*.nulsrc')
    find "$SBX/root" -type f -name changelog.Debian -exec gzip -n {} +
    # *.gzsrc fixture files become *.gz (git keeps the readable text)
    local g
    while IFS= read -r g; do gzip -nc "$g" >"${g%src}"; rm -f "$g"; done < <(find "$SBX/root" -type f -name '*.gzsrc')
    ROOT="$SBX/root"
    export SMS_FAKE="$FIXTURES/$fixture/fake"
  fi
  export PATH="$SBX/bin"
}

# line_matching REGEX -> the first output line matching (bats $output)
line_matching() { grep -E -- "$1" <<<"$output" | head -n1; }
