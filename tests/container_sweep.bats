#!/usr/bin/env bats

setup() { load helpers; }
run_cs() { run bash "$SCRIPTS/container_sweep.sh" --root "$ROOT" "$@"; }
prep() { setup_sandbox containers docker; }

@test "diff: code in a temp dir is CRIT; added PHP is WARN; shell history is INFO; caches are left out" {
  prep
  run_cs --docker --no-volumes
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^CRIT\tcontainer.diff\tshop-app: A /tmp/.x/kdevtmpfsi.sh:')" ]
  [ -n "$(line_matching $'^WARN\tcontainer.diff\tshop-app: A /tmp/.x: hidden file in a temp dir')" ]
  [ -n "$(line_matching $'^WARN\tcontainer.diff\tshop-app: A /var/www/html/public/wp-cache.php:')" ]
  [ -n "$(line_matching $'^WARN\tcontainer.diff\tshop-app: A /var/log/.x.so:')" ]
  [ -n "$(line_matching $'^WARN\tcontainer.diff\tshop-app: A /var/cache/update.sh:')" ]
  [ -n "$(line_matching $'^WARN\tcontainer.diff\tshop-app: A /opt/module.so.2:')" ]
  [ -n "$(line_matching $'^INFO\tcontainer.diff\tshop-app: A /root/.bash_history:')" ]
  [ -n "$(line_matching $'^WARN\tcontainer.diff\tshop-app: C /etc/passwd:')" ]
  ! grep -q 'storage/framework/views' <<<"$output"
  ! grep -q 'php-fpm.log' <<<"$output"
  ! grep -q 'access.log' <<<"$output"
  ! grep -q 'packages.idx' <<<"$output"
  ! grep -q 'old-tool' <<<"$output"
  [ -n "$(line_matching $'^OK\tcontainer.diff\tshop-web: nothing suspicious among 4 change')" ]
}

@test "diff: cron, SSH keys and new programs; a STOPPED container is checked too" {
  prep
  run_cs --docker --no-volumes
  [ -n "$(line_matching $'^CRIT\tcontainer.diff\tshop-queue: A /etc/cron.d/sysupdate:')" ]
  [ -n "$(line_matching $'^CRIT\tcontainer.diff\tshop-queue: C /etc/cron.daily/rotate:')" ]
  [ -n "$(line_matching $'^CRIT\tcontainer.diff\tshop-queue: C /var/spool/cron/root:')" ]
  [ -n "$(line_matching $'^CRIT\tcontainer.diff\tshop-queue: A /root/.ssh/authorized_keys:')" ]
  [ -n "$(line_matching $'^WARN\tcontainer.diff\tshop-queue: A /usr/local/bin/kworkerd:')" ]
  [ -n "$(line_matching $'^CRIT\tcontainer.diff\thelper: A /tmp/payload.php:')" ]
}

@test "native PHP session files are counted, never named" {
  prep
  run_cs --docker --no-volumes
  [ -n "$(line_matching $'^WARN\tcontainer.sess_files\tshop-app: 2 native PHP session file')" ]
  ! grep -q 'a1b2c3d4e5f6a7b8' <<<"$output"
  ! grep -q '0f9e8d7c6b5a4f3e' <<<"$output"
  ! grep -q 'container.sess_files	shop-web' <<<"$output"
}

@test "--max caps the paths per container and counts the rest" {
  prep
  run_cs --docker --no-volumes --max 1
  [ "$(grep -c $'container.diff\tshop-app: [ACD] /' <<<"$output")" -eq 1 ]
  [ -n "$(line_matching $'^INFO\tcontainer.diff\tshop-app: 7 more finding')" ]
  ! grep -q $'^OK\tcontainer.diff\tshop-app' <<<"$output"
}

@test "containers outside compose: WARN when created since the date, INFO when older" {
  prep
  run_cs --docker --no-volumes --since 2026-10-15
  [ -n "$(line_matching $'^WARN\tcontainer.unmanaged\thelper \\(image alpine:3.20\\) .*created 2026-10-20T03:30:00')" ]
  [ -n "$(line_matching $'^INFO\tcontainer.unmanaged\tportainer ')" ]
  ! grep -q $'container.unmanaged\tshop-' <<<"$output"
}

@test "failed formatted docker ps is SKIP and does not label every container unmanaged" {
  prep
  export SMS_DOCKER_FAIL_PS_FORMAT=1
  run_cs --docker --no-volumes
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^SKIP\tcontainer.docker\tdocker ps -a --format failed')" ]
  ! grep -q $'container.unmanaged\t' <<<"$output"
}

@test "failed docker inspect batch is SKIP and its containers are not parsed" {
  prep
  export SMS_DOCKER_FAIL_INSPECT=1
  run_cs --docker --no-volumes
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^SKIP\tcontainer.docker\tdocker inspect failed for a batch')" ]
  ! grep -q $'container.unmanaged\t' <<<"$output"
  ! grep -q $'container.diff\t' <<<"$output"
}

@test "docker inspect is split into batches of at most 50 ids" {
  prep
  "$CP" -a "$SMS_FAKE" "$SBX/fake-many"
  export SMS_FAKE="$SBX/fake-many"
  for n in {100..155}; do
    printf 'c%s\tbatch-%s\talpine:3.20\tshop\t\tfalse\tshop_default\t2026-09-01T10:00:00.000Z\t\t\t0\n' "$n" "$n" >>"$SMS_FAKE/docker/containers"
  done
  export SMS_DOCKER_MAX_INSPECT=50
  run_cs --docker --no-volumes
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^OK\tcontainer.diff\tbatch-155: nothing suspicious')" ]
  ! grep -q 'docker inspect failed for a batch' <<<"$output"
}

@test "exactly 50 containers with every inspect batch failing still reaches SUMMARY" {
  prep
  mkdir -p "$SBX/fake-fifty/docker"
  : >"$SBX/fake-fifty/docker/containers"
  for n in {1..50}; do
    printf 'f%s\tbatch-%s\talpine:3.20\tshop\t\tfalse\tshop_default\t2026-09-01T10:00:00.000Z\t\t\t0\n' "$n" "$n" >>"$SBX/fake-fifty/docker/containers"
  done
  export SMS_FAKE="$SBX/fake-fifty"
  export SMS_DOCKER_FAIL_INSPECT=1
  run_cs --docker --no-volumes
  [ "$status" -eq 0 ]
  [ "$(grep -c $'^SKIP\tcontainer.docker\tdocker inspect failed for a batch of 50 container' <<<"$output")" -eq 1 ]
  [ -n "$(line_matching $'^SUMMARY\tcontainer_sweep\t')" ]
  ! grep -q 'unbound variable' <<<"$output"
}

@test "PHP and script suffixes are matched without case in diffs and volumes" {
  prep
  "$CP" -a "$SMS_FAKE" "$SBX/fake-case"
  export SMS_FAKE="$SBX/fake-case"
  printf 'A /tmp/audit.PHP\n' >>"$SMS_FAKE/docker/diff/c1"
  printf 'plain uppercase extension test\n' >"$ROOT/var/lib/docker/volumes/shop_uploads/_data/avatars/.audit.PHP"
  run_cs --docker
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^CRIT\tcontainer.diff\tshop-app: A /tmp/audit.PHP: code or a library in a temp dir')" ]
  [ -n "$(line_matching $'^CRIT\tcontainer.volume\tshop_uploads: /avatars/.audit.PHP: hidden PHP file')" ]
}

@test "stop signal: caught signals are OK, and a signal PID 1 does not catch is WARN" {
  prep
  run_cs --docker --no-volumes
  [ -n "$(line_matching $'^WARN\tcontainer.stop_signal\tshop-queue: docker stop sends SIGQUIT, which PID 1 \\(bash\\) does not catch')" ]
  [ -n "$(line_matching $'^OK\tcontainer.stop_signal\tshop-app: docker stop sends SIGQUIT and PID 1 \\(php-fpm\\) catches it')" ]
  [ -n "$(line_matching $'^OK\tcontainer.stop_signal\tshop-web: docker stop sends SIGTERM and PID 1 \\(nginx\\)')" ]
  [ -n "$(line_matching $'^OK\tcontainer.stop_signal\tportainer: ')" ]
  [ -n "$(line_matching $'^OK\tcontainer.stop_signal\tsignaler: docker stop sends 35 and PID 1 \\(signaler\\) catches it')" ]
  [ -n "$(line_matching $'^WARN\tcontainer.stop_signal\tignored: docker stop sends SIGTERM, which PID 1 \\(ignored\\) does not catch \\(it is ignored\\)')" ]
  ! grep -q $'container.stop_signal\thelper' <<<"$output"
}

@test "real-time stop signals use safe glibc and musl mask readings" {
  prep
  "$CP" -a "$SMS_FAKE" "$SBX/fake-realtime"
  export SMS_FAKE="$SBX/fake-realtime"
  printf 'rt1\trt-agree\talpine:3.20\tshop\t\tfalse\tshop_default\t2026-09-01T10:00:00.000Z\t\tSIGRTMIN+3\t4190\n' >>"$SMS_FAKE/docker/containers"
  printf 'rt2\trt-ambiguous\talpine:3.20\tshop\t\tfalse\tshop_default\t2026-09-01T10:00:00.000Z\t\tSIGRTMIN+3\t4191\n' >>"$SMS_FAKE/docker/containers"
  printf 'rt3\trt-max\talpine:3.20\tshop\t\tfalse\tshop_default\t2026-09-01T10:00:00.000Z\t\tSIGRTMAX-3\t4193\n' >>"$SMS_FAKE/docker/containers"
  mkdir -p "$ROOT/proc/4190" "$ROOT/proc/4191" "$ROOT/proc/4193"
  printf 'SigBlk:\t0000000000000000\nSigIgn:\t0000000000000000\nSigCgt:\t0000003000000000\n' >"$ROOT/proc/4190/status"
  printf 'rt-agree\n' >"$ROOT/proc/4190/comm"
  printf 'SigBlk:\t0000000000000000\nSigIgn:\t0000000000000000\nSigCgt:\t0000001000000000\n' >"$ROOT/proc/4191/status"
  printf 'rt-ambiguous\n' >"$ROOT/proc/4191/comm"
  printf 'SigBlk:\t0000000000000000\nSigIgn:\t0000000000000000\nSigCgt:\t1000000000000000\n' >"$ROOT/proc/4193/status"
  printf 'rt-max\n' >"$ROOT/proc/4193/comm"
  run_cs --docker --no-volumes
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^OK\tcontainer.stop_signal\trt-agree: docker stop sends SIGRTMIN\+3 .* catches it')" ]
  [ -n "$(line_matching $'^INFO\tcontainer.stop_signal\trt-ambiguous: .* not checked .* readings disagree')" ]
  [ -n "$(line_matching $'^OK\tcontainer.stop_signal\trt-max: docker stop sends SIGRTMAX-3 .* catches it')" ]
}

@test "a blocked stop signal is INFO unknown rather than WARN" {
  prep
  mkdir -p "$ROOT/proc/4192"
  printf 'SigBlk:\t0000000000004000\nSigIgn:\t0000000000000000\nSigCgt:\t0000000000000000\n' >"$ROOT/proc/4192/status"
  printf 'waiter\n' >"$ROOT/proc/4192/comm"
  run env SMS_TEST=1 bash -c '
    source "$1"
    SMS_ROOT=$2
    check_stop_signal blocked SIGTERM 4192
    summary
  ' _ "$SCRIPTS/container_sweep.sh" "$ROOT"
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^INFO\tcontainer.stop_signal\tblocked: .* unknown because it is blocked')" ]
  ! grep -q $'^WARN\tcontainer.stop_signal\tblocked:' <<<"$output"
}

@test "volumes: high-signal files stay CRIT in code volumes; .so.N and group execute bits are found" {
  local chmod_bin
  chmod_bin=$(command -v chmod)
  prep
  "$chmod_bin" 0010 "$ROOT/var/lib/docker/volumes/shop_uploads/_data/avatars/run"
  run_cs --docker
  [ -n "$(line_matching $'^CRIT\tcontainer.volume\tshop_uploads: /avatars/.cache.php: hidden PHP file')" ]
  [ -n "$(line_matching $'^CRIT\tcontainer.volume\tshop_uploads: /avatars/thumb.php: PHP in an upload-like directory')" ]
  [ -n "$(line_matching $'^WARN\tcontainer.volume\tshop_uploads: /avatars/run:')" ]
  [ -n "$(line_matching $'^CRIT\tcontainer.volume\tshop_redis: /exp.so:')" ]
  [ -n "$(line_matching $'^CRIT\tcontainer.volume\tshop_redis: /exp.so.2:')" ]
  [ -n "$(line_matching $'^CRIT\tcontainer.volume\tshop_redis: /authorized_keys:')" ]
  [ -n "$(line_matching $'^INFO\tcontainer.volume\tshop_code: holds application code \\(2 PHP files\\)')" ]
  [ -n "$(line_matching $'^CRIT\tcontainer.volume\tshop_marked: /.audit.php: hidden PHP file')" ]
  [ -n "$(line_matching $'^CRIT\tcontainer.volume\tshop_marked: /uploads/photo.php: PHP in an upload-like directory')" ]
  [ -n "$(line_matching $'^CRIT\tcontainer.volume\tshop_marked: /etc/cron.daily/audit-note: file in a cron directory')" ]
  [ -n "$(line_matching $'^INFO\tcontainer.volume\tshop_marked: holds application code \\(3 PHP files\\)')" ]
  [ -n "$(line_matching $'^OK\tcontainer.volume\tshop_db: ')" ]
  [ -n "$(line_matching $'^OK\tcontainer.volume\tshop_storage: ')" ]
  ! grep -q 'u1.jpg' <<<"$output"
  ! grep -q 'Kernel.php' <<<"$output"
  ! grep -q FAKE_SECRET_DO_NOT_PRINT <<<"$output"
  [ -n "$(line_matching $'^INFO\tcontainer.volume\t6 named volume')" ]
}

@test "without docker, volume directories are scanned straight from disk" {
  setup_sandbox containers
  run_cs
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^CRIT\tcontainer.volume\tshop_redis: /exp.so:')" ]
  [ -n "$(line_matching $'^INFO\tcontainer.volume\t6 named volume')" ]
  ! grep -q $'container.diff' <<<"$output"
  run_cs --docker
  [ -n "$(line_matching $'^SKIP\tcontainer.docker\tdocker not on PATH')" ]
}

@test "a find traversal error emits SKIP and never emits OK for that volume" {
  prep
  run env SMS_TEST=1 bash -c '
    source "$1"
    SMS_ROOT=$2
    find() { command find "$@"; return 1; }
    check_volume broken "$2/var/lib/docker/volumes/shop_db/_data"
    summary
  ' _ "$SCRIPTS/container_sweep.sh" "$ROOT"
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^SKIP\tcontainer.volume\tbroken: some directories were unreadable')" ]
  ! grep -q $'^OK\tcontainer.volume\tbroken:' <<<"$output"
}

@test "Laravel queue trap requires several seconds of timeout safety margin" {
  local traps text
  traps="$BATS_TEST_DIRNAME/../plugins/secure-my-server/skills/secure-my-server/references/07-traps.md"
  text=$(<"$traps")
  [[ $text == *'must be at least several seconds shorter than the `retry_after`'* ]]
  [[ $text == *'use `timeout` 200 with `retry_after` 240'* ]]
}

@test "--max and --since refuse bad values" {
  run bash "$SCRIPTS/container_sweep.sh" --max many
  [ "$status" -eq 2 ]
  run bash "$SCRIPTS/container_sweep.sh" --since 2026-13-01
  [ "$status" -eq 2 ]
}

@test "--help and the header explain the narrow use of --since" {
  run bash "$SCRIPTS/container_sweep.sh" --help
  [ "$status" -eq 0 ]
  [[ $output == *"Used only to grade containers created outside"* ]]
  [[ $output == *"docker diff"* ]]
  [[ $output == *"covers the container's whole life"* ]]
  [[ $output == *"Volumes are not date-filtered"* ]]

  prep
  run_cs --no-docker --no-volumes
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == *"writable layers cover the whole life of each container"* ]]
  [[ ${lines[0]} == *"volumes are not date-filtered"* ]]
  [[ ${lines[0]} == *"--since=2026-10-15 grades only containers outside Compose"* ]]
}
