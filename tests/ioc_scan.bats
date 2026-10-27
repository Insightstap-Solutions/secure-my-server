#!/usr/bin/env bats

setup() { load helpers; }
run_ioc() { run bash "$SCRIPTS/php2shell_ioc_scan.sh" --root "$ROOT" "$@"; }

prep_logs() {
  setup_sandbox logs
  # a log not written since --since must be skipped
  "$TOUCH" -d 2026-10-01 "$ROOT/var/log/nginx/old-site.access.log"
}

@test "counts, first/last and top IPs per indicator" {
  prep_logs
  run_ioc --since 2026-10-15
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^WARN\tioc.fpm_child_crash\tcount=2 first=2026-10-20 03:14:15 last=2026-10-20 03:14:17 ')" ]
  [ -n "$(line_matching $'^CRIT\tioc.mem_exhausted_unknown\tcount=1 ')" ]
  [ -n "$(line_matching $'^CRIT\tioc.multipart_no_boundary\tcount=2 .*top_ips=198.51.100.7\\(2\\)')" ]
  [ -n "$(line_matching $'^CRIT\tioc.post_big_error\tcount=2 .*sources=2 ')" ]
  [ -n "$(line_matching $'^INFO\tioc.upstream_reset\tcount=2 .*top_ips=203.0.113.9\\(2\\)')" ]
  # 2 from access.log after the date + 1 from the rotated .gz + one 499
  [ -n "$(line_matching $'^INFO\tioc.post_502_499\tcount=4 first=2026-10-19 22:00:00 .*top_ips=203.0.113.9\\(3\\), 198.51.100.2\\(1\\)')" ]
}

@test "--since filters lines inside files and skips old files" {
  prep_logs
  run_ioc --since 2026-10-15
  ! grep -q 'old-site.access.log' <<<"$output"
  ! grep -q 'child 999' <<<"$output"
  run_ioc --since 2026-10-21
  [ -n "$(line_matching $'^OK\tioc.fpm_child_crash\t0 hits')" ]
  [ -n "$(line_matching $'^CRIT\tioc.post_big_error\tcount=1 ')" ]
}

@test "gzip-rotated logs are read" {
  prep_logs
  run_ioc --since 2026-10-15
  [ -n "$(line_matching $'^INFO\tioc.source\t/var/log/nginx/access.log.2.gz')" ]
}

@test "samples: at most N, query strings stripped, JSON lines summarised, no secrets" {
  prep_logs
  run_ioc --since 2026-10-15 --samples 1
  [ "$(grep -c $'^INFO\tioc.post_502_499.sample' <<<"$output")" -eq 1 ]
  ! grep -q FAKE_SECRET_DO_NOT_PRINT <<<"$output"
  ! grep -q 'token=' <<<"$output"
  ! grep -qi 'cookie' <<<"$output"
  [ -n "$(line_matching $'ioc.multipart_no_boundary.sample\t/www/wwwlogs/caddy-access.json: json: time=2026-10-20 03:14:15 ip=198.51.100.7 POST / status=502 request_bytes=8388608')" ]
  while IFS= read -r l; do [ "${#l}" -le 400 ]; done < <(grep '\.sample' <<<"$output")
  run_ioc --since 2026-10-15 --samples 0
  ! grep -q '\.sample' <<<"$output"
}

@test "a request WITH a boundary is not flagged" {
  prep_logs
  run_ioc --since 2026-10-15 --samples 5
  ! grep -q 'WebKitFormBoundary' <<<"$output"
  ! grep -q '198.51.100.8' <<<"$output"
}

@test "extra paths given as arguments are scanned" {
  setup_sandbox -
  mkdir -p "$BATS_TEST_TMPDIR/r/custom"
  printf '[22-Oct-2026 01:00:00] WARNING: [pool app] child 5 exited on signal 11 (SIGSEGV)\n' >"$BATS_TEST_TMPDIR/r/custom/fpm.log"
  run bash "$SCRIPTS/php2shell_ioc_scan.sh" --root "$BATS_TEST_TMPDIR/r" --since 2026-10-15 /custom/fpm.log
  [ -n "$(line_matching $'^WARN\tioc.fpm_child_crash\tcount=1 ')" ]
}

@test "docker logs of php/nginx containers are scanned" {
  setup_sandbox dockerhost docker
  run_ioc --docker --since 2026-10-15
  [ -n "$(line_matching $'^WARN\tioc.fpm_child_crash\tcount=1 ')" ]
  [ -n "$(line_matching $'^INFO\tioc.upstream_reset\tcount=1 .*203.0.113.77')" ]
  [ -n "$(line_matching 'docker:shop-app: ')" ]
}

@test "no logs found is a WARN that says what to do, and the limits are stated" {
  setup_sandbox -
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  run bash "$SCRIPTS/php2shell_ioc_scan.sh" --root "$BATS_TEST_TMPDIR/empty"
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^WARN\tioc.source\tno log file')" ]
  [ -n "$(line_matching $'^INFO\tioc.limits\t.*not proof of absence')" ]
}
