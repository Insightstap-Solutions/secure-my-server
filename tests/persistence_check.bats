#!/usr/bin/env bats

setup() { load helpers; }
run_pc() { run bash "$SCRIPTS/persistence_check.sh" --root "$ROOT" "$@"; }
prep() {
  setup_sandbox compromised ss ps ssh-keygen dpkg-query
  "$TOUCH" -d 2026-01-01 "$ROOT/etc/crontab" "$ROOT/root/.ssh/authorized_keys" "$ROOT/etc/sudoers"
}

@test "second uid-0 account is CRIT; password change since the date is WARN" {
  prep
  run_pc --since 2026-10-15
  [ "$status" -eq 0 ]
  [ -n "$(line_matching $'^CRIT\tpersist.uid0\taccount .toor. has uid 0')" ]
  [ -n "$(line_matching $'^WARN\tpersist.password_changed\tdeploy: password changed on 2026-10-20')" ]
  ! grep -q 'root: password changed' <<<"$output"
}

@test "authorized_keys: counts and fingerprints, never key material" {
  prep
  run_pc --since 2026-10-15
  line=$(line_matching $'persist.ssh_keys\t/home/deploy/.ssh/authorized_keys')
  [[ $line == WARN* && $line == *"keys=2 with_options=1"* && $line == *"SHA256:fakefingerprint2 backdoor"* ]]
  line=$(line_matching $'persist.ssh_keys\t/root/.ssh/authorized_keys')
  [[ $line == INFO* && $line == *"keys=1"* ]]
  ! grep -q 'AAAAC3' <<<"$output"
  ! grep -q FAKE_SECRET_DO_NOT_PRINT <<<"$output"
}

@test "cron: download piped to a shell is CRIT; only file:line and rule names are shown" {
  prep
  run_pc --since 2026-10-15
  [ -n "$(line_matching $'^CRIT\tpersist.cron\t/var/spool/cron/crontabs/www-data:2 rules=download_pipe_shell,curl$')" ]
  [ -n "$(line_matching $'^WARN\tpersist.cron\t/etc/cron.d/sysupdate:1 rules=wget$')" ]
  ! grep -q '203.0.113.5' <<<"$output"
  ! grep -q 'artisan' <<<"$output"
  ! grep -q $'persist.cron\t/etc/crontab changed' <<<"$output"
}

@test "sudoers.d changed since the date is WARN with its NOPASSWD count" {
  prep
  run_pc --since 2026-10-15
  [ -n "$(line_matching $'^WARN\tpersist.sudoers\t/etc/sudoers.d/90-cloud changed since .*NOPASSWD lines: 1')" ]
  [ -n "$(line_matching $'^INFO\tpersist.sudoers\t/etc/sudoers NOPASSWD lines: 0')" ]
}

@test "systemd: unowned new unit is WARN; package-owned ones (incl. /lib -> /usr/lib) are not" {
  prep
  run_pc --since 2026-10-15
  [ -n "$(line_matching $'^WARN\tpersist.systemd\t/etc/systemd/system/dbus-helper.service .*no package owns it')" ]
  ! grep -q 'nginx.service' <<<"$output"
  ! grep -q 'ssh.service' <<<"$output"
}

@test "ld.so.preload and rc.local" {
  prep
  run_pc --since 2026-10-15
  [ -n "$(line_matching $'^CRIT\tpersist.ld_preload\t/etc/ld.so.preload lists 1 ')" ]
  [ -n "$(line_matching $'^WARN\tpersist.rc_local\t/etc/rc.local has 1 command line')" ]
}

@test "processes: miner name, deleted binary from /tmp, top CPU" {
  prep
  run_pc --since 2026-10-15
  [ -n "$(line_matching $'^CRIT\tpersist.miner\tpid 4444 comm=kdevtmpfsi')" ]
  [ -n "$(line_matching $'^CRIT\tpersist.deleted_exe\tpid 4444 .*temp dir')" ]
  [ -n "$(line_matching $'^WARN\tpersist.deleted_exe\tpid 200 comm=php-fpm8.3')" ]
  [ -n "$(line_matching $'^INFO\tpersist.top_cpu\tpid=4444 user=www-data cpu=398.0% comm=kdevtmpfsi')" ]
}

@test "outbound: pool port CRIT, shell WARN, private and inbound ignored" {
  prep
  run_pc --since 2026-10-15
  [ -n "$(line_matching $'^CRIT\tpersist.outbound\tkdevtmpfsi -> 203.0.113.50:3333')" ]
  [ -n "$(line_matching $'^WARN\tpersist.outbound\tbash -> 203.0.113.60:4433')" ]
  [ -n "$(line_matching $'^INFO\tpersist.outbound\tphp-fpm8.3 -> 203.0.113.34:443')" ]
  ! grep -q '10.0.0.9' <<<"$output"
  ! grep -q '198.51.100.20' <<<"$output"
}

@test "docker: privileged, host network, docker.sock and / mounts, created since" {
  setup_sandbox dockerhost docker
  run_pc --docker --since 2026-10-15
  [ -n "$(line_matching $'^WARN\tpersist.docker\tupdater runs --privileged')" ]
  [ -n "$(line_matching $'^WARN\tpersist.docker\tupdater mounts the Docker socket')" ]
  [ -n "$(line_matching $'^CRIT\tpersist.docker\tupdater mounts the host root filesystem')" ]
  [ -n "$(line_matching $'^WARN\tpersist.docker\tupdater created 2026-10-20T03:30:00')" ]
  ! grep -q $'persist.docker\tshop-app created' <<<"$output"
}

@test "shadow hashes are never read into the output" {
  prep
  run_pc --since 2026-10-15
  ! grep -q 'FAKEHASH' <<<"$output"
}
