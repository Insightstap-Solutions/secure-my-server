#!/usr/bin/env bats
# Rules every script must follow: --help, bad arguments, syntax, output shape.

setup() { load helpers; }

DETECTORS="detect_stack php_runtimes php2shell_ioc_scan webshell_scan persistence_check"

@test "every script parses (bash -n)" {
  for f in "$SCRIPTS"/*.sh; do bash -n "$f"; done
}

@test "every script answers --help with exit 0" {
  for f in "$SCRIPTS"/*.sh; do
    run bash "$f" --help
    [ "$status" -eq 0 ] || { echo "$f: $status"; false; }
    [ -n "$output" ]
  done
}

@test "detector --help says it is read-only and describes the output" {
  for s in $DETECTORS; do
    run bash "$SCRIPTS/$s.sh" --help
    [[ $output == *"READ-ONLY"* ]] || { echo "$s"; false; }
    [[ $output == *"LEVEL<TAB>CHECK<TAB>DETAIL"* ]] || { echo "$s"; false; }
  done
}

@test "detectors exit 2 on an unknown option" {
  for s in $DETECTORS; do
    run bash "$SCRIPTS/$s.sh" --no-such-option
    [ "$status" -eq 2 ] || { echo "$s: $status"; false; }
  done
}

@test "detectors exit 2 on a bad --since, --root or --samples" {
  for s in php2shell_ioc_scan webshell_scan persistence_check; do
    run bash "$SCRIPTS/$s.sh" --since 15/10/2026
    [ "$status" -eq 2 ] || { echo "$s"; false; }
  done
  for s in $DETECTORS; do
    run bash "$SCRIPTS/$s.sh" --root /nonexistent/dir/for/test
    [ "$status" -eq 2 ] || { echo "$s"; false; }
  done
  run bash "$SCRIPTS/php2shell_ioc_scan.sh" --samples many
  [ "$status" -eq 2 ]
}

@test "output is header lines, LEVEL<TAB>CHECK<TAB>DETAIL lines, and one final SUMMARY" {
  setup_sandbox ubuntu dpkg-query ss
  for s in $DETECTORS; do
    args=(--root "$ROOT"); [ "$s" = webshell_scan ] || args+=(--no-docker)
    run bash "$SCRIPTS/$s.sh" "${args[@]}"
    [ "$status" -eq 0 ]
    [[ ${lines[-1]} =~ ^SUMMARY$'\t'$s$'\t'CRIT=[0-9]+\ WARN=[0-9]+\ INFO=[0-9]+\ OK=[0-9]+\ SKIP=[0-9]+$ ]] || { echo "$s: ${lines[-1]}"; false; }
    bad=$(printf '%s\n' "${lines[@]}" | grep -vE $'^(#|SUMMARY\t|(CRIT|WARN|INFO|OK|SKIP)\t[a-z0-9_.]+\t)' || true)
    [ -z "$bad" ] || { echo "$s: $bad"; false; }
  done
}

@test "detectors are self-contained (no source of a shared library)" {
  for s in $DETECTORS; do
    ! grep -qE '^[[:space:]]*(source|\.)[[:space:]]+[^ ]' "$SCRIPTS/$s.sh"
    grep -q '^\[\[ -n "${SMS_TEST:-}" \]\] || main "\$@"$' "$SCRIPTS/$s.sh"
  done
}

@test "a planted fake secret never appears in any detector output, on any fixture" {
  for fx in ubuntu aapanel cpanel rhel misc webroot compromised logs dockerhost; do
    setup_sandbox "$fx" dpkg-query ss ps ssh-keygen docker iptables
    for s in $DETECTORS; do
      args=(--root "$ROOT"); [ "$s" = webshell_scan ] || args+=(--docker)
      run bash "$SCRIPTS/$s.sh" "${args[@]}"
      [ "$status" -eq 0 ]
      if grep -q FAKE_SECRET_DO_NOT_PRINT <<<"$output"; then echo "$s on $fx leaked"; false; fi
    done
  done
}

@test "pure-bash date math agrees with GNU date (UTC)" {
  for s in php2shell_ioc_scan webshell_scan persistence_check; do
    (
      SMS_TEST=1 source "$SCRIPTS/$s.sh"
      for d in 1970-01-01 2000-02-29 2026-10-15 2026-12-31 2038-01-19; do
        [ "$(ymd_epoch "$d")" = "$(date -u -d "$d" +%s)" ] || { echo "$s $d"; exit 1; }
      done
      valid_ymd 2026-10-15 && ! valid_ymd 2026-13-01 && ! valid_ymd 2026-1-5 && ! valid_ymd 15/10/2026
    )
  done
}
