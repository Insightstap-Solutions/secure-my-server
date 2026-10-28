#!/usr/bin/env bash
# container_sweep.sh - what an attacker may have left INSIDE Docker: files added to each container's
# writable layer, native PHP session files in /tmp (the upload-progress exploit's leftovers), scripts
# and binaries in named volumes, containers no compose project owns, and stop signals PID 1 ignores.
#
# READ-ONLY. Runs docker ps/inspect/diff and docker volume ls/inspect; reads volume directories and
# /proc/<pid>/status on the host. Never runs anything inside a container, never prints file contents.
#
#   ssh host 'sudo bash -s -- --since 2026-10-15' < scripts/container_sweep.sh
#
# Output: LEVEL<TAB>CHECK<TAB>DETAIL lines, then SUMMARY. Exit 0 always; 2 on bad arguments.

SMS_NAME=container_sweep
SMS_ROOT=""
SMS_SINCE="2026-10-15"
SMS_DOCKER="auto"
SMS_MAX=10
SMS_VOLUMES=1
SMS_TIMEOUT=60
SMS_N_CRIT=0; SMS_N_WARN=0; SMS_N_INFO=0; SMS_N_OK=0; SMS_N_SKIP=0

usage() {
  cat <<'EOF'
container_sweep.sh [--since YYYY-MM-DD] [--max N] [--root DIR] [--docker|--no-docker] [--no-volumes] [--help]

Checks:
  container.diff        `docker diff` of every container, running or stopped: files ADDED after the image
                        was built. CRIT: PHP, scripts or shared objects in /tmp /var/tmp /dev/shm; anything
                        under /etc/cron* /var/spool/cron, ~/.ssh, /etc/ld.so.preload. WARN: other PHP,
                        .sh .py .pl .so .so.N files, new files in bin/sbin dirs, hidden files in temp dirs,
                        /etc/passwd /etc/shadow /etc/sudoers changed. INFO: shell history written
                        (somebody ran an interactive shell: read it). Laravel/Symfony caches, package
                        manager caches, logs and run dirs are left out
  container.sess_files  native PHP session files (/tmp/sess_*) in a container's writable layer: count only,
                        never the names (they are session ids). An app that keeps sessions in its framework
                        (Laravel, Symfony) or Redis should have none; the PHP upload-progress exploit
                        (PHP2Shell) leaves them behind
  container.volume      named volumes: PHP, scripts, shared objects and executables, with paths. CRIT: hidden
                        PHP files, .so and .so.N files, authorized_keys, files in cron dirs, and PHP in
                        upload-like dirs. A volume that holds application code (composer.json, artisan,
                        wp-config.php, package.json ...) gets an INFO pointer to webshell_scan.sh. These
                        high-signal files are still reported
  container.unmanaged   containers that belong to no compose project (started by hand?): WARN when created
                        since --since, INFO otherwise
  container.stop_signal the signal `docker stop` sends vs what PID 1 catches (/proc/<pid>/status SigCgt).
                        php-fpm images stop with SIGQUIT; a bash entrypoint that traps only TERM ignores it,
                        so every stop waits the whole grace period and then kills (deploy downtime)

Options:
  --since DATE   YYYY-MM-DD (default 2026-10-15). Used only to grade containers created outside
                 Compose. `docker diff` covers the container's whole life. Volumes are not date-filtered
  --max N        paths printed per container or volume (default 10; the rest are counted)
  --root DIR     prefix for every FILE path inspected (tests / mounted images); commands from PATH
  --docker / --no-docker   (default: docker when on PATH and no --root). Without docker only the
                 volume directories under /var/lib/docker/volumes are scanned
  --no-volumes   skip the volume scan
  --help         this text

LIMITS: `docker diff` covers the container's whole life, but does not see volumes, bind mounts or tmpfs.
Volumes are not date-filtered. A recreated container has a new, empty writable layer: what the old one
held is gone. Run this BEFORE any recreate.

READ-ONLY. Run as root, otherwise volume directories and /proc are unreadable (SKIP lines).
Output: LEVEL<TAB>CHECK<TAB>DETAIL (LEVEL = CRIT WARN INFO OK SKIP), '#' headers, SUMMARY last.
Exit 0 always; 2 on bad arguments.
EOF
}

# ---------- tiny helpers (duplicated in every script on purpose: scripts travel alone over ssh) ----------
# YYYY-MM-DD -> epoch seconds at 00:00 UTC, in pure bash arithmetic (busybox `date -d` differs).
ymd_epoch() {
  local y=$((10#${1:0:4})) m=$((10#${1:5:2})) d=$((10#${1:8:2})) era yoe doy doe
  ((m <= 2)) && y=$((y - 1))
  era=$(((y >= 0 ? y : y - 399) / 400)); yoe=$((y - era * 400))
  doy=$(((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  echo $(((era * 146097 + doe - 719468) * 86400))
}
valid_ymd() { [[ $1 =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]]; }
have() { command -v "$1" >/dev/null 2>&1; }
rp() { printf '%s%s' "$SMS_ROOT" "$1"; }
clean() { local s=$1; s=${s//[[:cntrl:]]/ }; printf '%s' "${s:0:1500}"; }
emit() {
  local level=$1 check=$2; shift 2
  case $level in
    CRIT) SMS_N_CRIT=$((SMS_N_CRIT + 1)) ;; WARN) SMS_N_WARN=$((SMS_N_WARN + 1)) ;;
    INFO) SMS_N_INFO=$((SMS_N_INFO + 1)) ;; OK) SMS_N_OK=$((SMS_N_OK + 1)) ;;
    SKIP) SMS_N_SKIP=$((SMS_N_SKIP + 1)) ;;
  esac
  printf '%s\t%s\t%s\n' "$level" "$check" "$(clean "$*")"
}
summary() {
  printf 'SUMMARY\t%s\tCRIT=%d WARN=%d INFO=%d OK=%d SKIP=%d\n' "$SMS_NAME" \
    "$SMS_N_CRIT" "$SMS_N_WARN" "$SMS_N_INFO" "$SMS_N_OK" "$SMS_N_SKIP"
}
# `timeout` is used only if it accepts GNU syntax (old busybox wants -t); main() sets SMS_TO_OK.
run_t() { if [[ ${SMS_TO_OK:-0} == 1 ]]; then timeout "$SMS_TIMEOUT" "$@"; else "$@"; fi; }

# ---------- docker diff ----------
# Paths a running app writes on its own: package-manager caches, logs, pid/run dirs.
DIFF_FRAMEWORK_CACHE='/storage/framework/(views|cache)/|/bootstrap/cache/'
DIFF_NOISE='/var/cache/|/var/log/|/var/lib/(apt|dpkg|apk)/|^/(var/)?run/|/\.(composer|npm|cache|yarn|pnpm-store)/|/\.config/psysh|^/tmp/(\.X11-unix|\.ICE-unix|\.font-unix|\.XIM-unix|\.Test-unix|pear)(/|$)|/__pycache__/'
TMP_RE='^/(tmp|var/tmp|dev/shm)/'
CODE_RE='\.(php[0-9]?|phtml|phar|inc)$'
SCRIPT_RE='\.(sh|py|pl|so(\.[0-9]+)*)$'

# diff_level KIND PATH -> "LEVEL reason", or nothing when the change is not interesting
diff_level() {
  local kind=$1 p=$2 base=${2##*/} p_lc
  p_lc=${p,,}
  if [[ $kind == C ]]; then
    case $p in
      /etc/ld.so.preload) echo "CRIT ld.so.preload changed" ;;
      /etc/crontab) echo "CRIT crontab changed" ;;
      /etc/cron.d/* | /etc/cron.hourly/* | /etc/cron.daily/* | /etc/cron.weekly/* | /etc/cron.monthly/* | /var/spool/cron/*)
        echo "CRIT cron entry changed" ;;
      /etc/passwd | /etc/shadow | /etc/sudoers | /etc/group) echo "WARN changed after the image was built, compare it with the image" ;;
      */.ssh/authorized_keys | */.ssh/authorized_keys2) echo "CRIT SSH keys changed" ;;
    esac
    return
  fi
  [[ $kind == A ]] || return   # D (deleted) is not reported
  [[ $p =~ $DIFF_FRAMEWORK_CACHE ]] && return
  [[ $base =~ ^\.(bash|zsh|sh|ash|python|psql|mysql|sqlite|php)_?history$ ]] && { echo "INFO shell history written: somebody ran an interactive shell here, read it"; return; }
  if [[ $p =~ $TMP_RE ]]; then
    [[ $p_lc =~ $CODE_RE || $p_lc =~ $SCRIPT_RE ]] && { echo "CRIT code or a library in a temp dir"; return; }
    [[ $base == .* ]] && { echo "WARN hidden file in a temp dir"; return; }
    return
  fi
  case $p in
    /etc/cron* | /var/spool/cron/*) echo "CRIT cron entry added"; return ;;
    */.ssh/*) echo "CRIT SSH file added"; return ;;
    /etc/ld.so.preload) echo "CRIT ld.so.preload added: it hooks every process"; return ;;
  esac
  [[ $p_lc =~ $CODE_RE ]] && { echo "WARN PHP added after the image was built: a web shell, or a hand edit that belongs in git"; return; }
  [[ $p_lc =~ $SCRIPT_RE ]] && { echo "WARN script or library added after the image was built"; return; }
  [[ $p =~ $DIFF_NOISE ]] && return
  [[ $p =~ ^/(usr/(local/)?)?s?bin/. ]] && { echo "WARN program added to a bin dir"; return; }
}

check_diff() {
  local name=$1 kind p lr total=0 shown=0 sess=0 hidden=0
  local out
  if ! out=$(run_t docker diff "$name" 2>/dev/null); then emit SKIP container.diff "$name: docker diff failed"; return; fi
  while read -r kind p; do
    [[ -z $p ]] && continue
    total=$((total + 1))
    if [[ $kind == A && $p =~ ^/tmp/sess_[A-Za-z0-9,-]+$ ]]; then sess=$((sess + 1)); continue; fi
    lr=$(diff_level "$kind" "$p")
    [[ -z $lr ]] && continue
    if [[ $shown -ge $SMS_MAX ]]; then hidden=$((hidden + 1)); continue; fi
    shown=$((shown + 1))
    emit "${lr%% *}" container.diff "$name: $kind $p: ${lr#* }"
  done <<<"$out"
  [[ $hidden -gt 0 ]] && emit INFO container.diff "$name: $hidden more finding(s) not shown (raise --max, or run: docker diff $name)"
  [[ $shown -eq 0 && $hidden -eq 0 ]] && emit OK container.diff "$name: nothing suspicious among $total change(s) to the writable layer"
  if [[ $sess -gt 0 ]]; then
    emit WARN container.sess_files "$name: $sess native PHP session file(s) in /tmp. Names not shown (they are session ids). An app on framework or Redis sessions has none; the upload-progress exploit leaves them. Their times and sizes, without names: docker exec $name find /tmp -maxdepth 1 -name 'sess_*' -exec stat -c '%y %s' {} +"
  fi
}

# ---------- named volumes ----------
# A volume that holds application code would list thousands of PHP files: report it once instead.
is_code_volume() {
  local mp=$1 f
  for f in composer.json artisan wp-config.php wp-settings.php package.json index.php autoload.php .package-lock.json; do
    [[ -e $mp/$f ]] && return 0
  done
  return 1
}
check_volume() {
  local name=$1 mp=$2 f rel base base_lc lvl why shown=0 hidden=0 code=0 php_count=0
  local find_failed=0 is_php=0 high_signal=0
  if [[ ! -d $mp ]]; then emit SKIP container.volume "$name: ${mp#"$SMS_ROOT"} missing"; return; fi
  if [[ ! -r $mp || ! -x $mp ]]; then emit SKIP container.volume "$name: ${mp#"$SMS_ROOT"} unreadable (run as root)"; return; fi
  is_code_volume "$mp" && code=1
  while IFS= read -r -d '' f; do
    if [[ $f == $'\001SMS_FIND_FAILED' ]]; then find_failed=1; continue; fi
    rel=${f#"$mp"}; base=${f##*/}; base_lc=${base,,}
    is_php=0; high_signal=0
    [[ $base_lc =~ $CODE_RE ]] && { is_php=1; php_count=$((php_count + 1)); }
    case $rel in */storage/framework/views/* | */storage/framework/cache/* | */bootstrap/cache/*) continue ;; esac
    lvl=WARN; why="script or executable in a data volume"
    if [[ $is_php == 1 && $base == .* ]]; then
      lvl=CRIT; why="hidden PHP file"; high_signal=1
    elif [[ $base_lc =~ \.so(\.[0-9]+)*$ ]]; then
      lvl=CRIT; why="shared object in a data volume: Redis module-load attacks drop one in /data"; high_signal=1
    elif [[ $base == authorized_keys || $base == authorized_keys2 ]]; then
      lvl=CRIT; why="SSH key file in a data volume: the Redis CONFIG SET dir trick"; high_signal=1
    elif [[ $rel =~ /(cron(\.d|\.hourly|\.daily|\.weekly|\.monthly)?|spool/cron)(/|$) ]]; then
      lvl=CRIT; why="file in a cron directory inside a data volume"; high_signal=1
    elif [[ $is_php == 1 && $rel =~ /(uploads?|avatars|media|files|images|tmp|cache)(/|$) ]]; then
      lvl=CRIT; why="PHP in an upload-like directory"; high_signal=1
    elif [[ $is_php == 1 ]]; then
      why="PHP in a data volume: in uploads, that is a web shell"
    fi
    [[ $code == 1 && $high_signal == 0 ]] && continue
    if [[ $shown -ge $SMS_MAX ]]; then hidden=$((hidden + 1)); continue; fi
    shown=$((shown + 1))
    emit "$lvl" container.volume "$name: $rel: $why"
  done < <(
    find "$mp" -xdev -type f \( -name '*.[pP][hH][pP]' -o -name '*.[pP][hH][pP][0-9]' \
      -o -name '*.[pP][hH][tT][mM][lL]' -o -name '*.[pP][hH][aA][rR]' -o -name '*.[iI][nN][cC]' \
      -o -name '*.[sS][hH]' -o -name '*.[pP][yY]' -o -name '*.[pP][lL]' \
      -o -name '*.[sS][oO]' -o -name '*.[sS][oO].*' \
      -o -name 'authorized_keys' -o -name 'authorized_keys2' \
      -o -path '*/cron/*' -o -path '*/cron.d/*' -o -path '*/cron.hourly/*' -o -path '*/cron.daily/*' \
      -o -path '*/cron.weekly/*' -o -path '*/cron.monthly/*' -o -path '*/spool/cron/*' \
      -o \( -perm -0100 -o -perm -0010 -o -perm -0001 \) \) -print0 2>/dev/null ||
      printf '\001SMS_FIND_FAILED\0'
  )
  if [[ $code == 1 ]]; then
    if [[ $find_failed == 1 ]]; then
      emit INFO container.volume "$name: holds application code (at least $php_count PHP files found before the scan error); scan it with webshell_scan.sh ${mp#"$SMS_ROOT"} and compare it with git"
    else
      emit INFO container.volume "$name: holds application code ($php_count PHP files); scan it with webshell_scan.sh ${mp#"$SMS_ROOT"} and compare it with git"
    fi
  fi
  [[ $hidden -gt 0 ]] && emit INFO container.volume "$name: $hidden more file(s) not shown (raise --max)"
  [[ $find_failed == 1 ]] && emit SKIP container.volume "$name: some directories were unreadable; the volume scan is incomplete"
  [[ $code == 0 && $shown -eq 0 && $hidden -eq 0 && $find_failed == 0 ]] && emit OK container.volume "$name: no scripts, PHP, libraries or executables"
}
check_volumes() {
  local name mp n=0
  if [[ ${SMS_USE_DOCKER:-0} == 1 ]]; then
    local names
    if ! names=$(run_t docker volume ls -q 2>/dev/null); then emit SKIP container.volume "docker volume ls failed (run with sudo)"; return; fi
    for name in $names; do
      if ! mp=$(run_t docker volume inspect --format '{{.Mountpoint}}' "$name" 2>/dev/null); then
        emit SKIP container.volume "$name: docker volume inspect failed"
        continue
      fi
      [[ -z $mp ]] && { emit SKIP container.volume "$name: no mountpoint (driver other than local?)"; continue; }
      n=$((n + 1)); check_volume "$name" "$(rp "$mp")"
    done
  else
    local d
    for d in "$(rp /var/lib/docker/volumes)"/*/_data; do
      [[ -d $d ]] || continue
      name=${d%/_data}; name=${name##*/}
      n=$((n + 1)); check_volume "$name" "$d"
    done
  fi
  emit INFO container.volume "$n named volume(s) checked"
}

# ---------- stop signal ----------
sig_nums() {
  local s=${1#SIG} n first second
  case $s in
    '') echo 15 ;;
    HUP) echo 1 ;; INT) echo 2 ;; QUIT) echo 3 ;; KILL) echo 9 ;; USR1) echo 10 ;; USR2) echo 12 ;;
    TERM) echo 15 ;; WINCH) echo 28 ;; PWR) echo 30 ;;
    RTMIN) echo "34 35" ;;
    RTMAX) echo 64 ;;
    *)
      # Linux glibc exposes SIGRTMIN as 34; some musl builds expose it as 35.
      # Return both readings so callers only make a claim when both mask bits agree.
      if [[ $s =~ ^RTMIN\+([0-9]{1,2})$ ]]; then
        n=$((10#${BASH_REMATCH[1]})); first=$((34 + n)); second=$((35 + n))
        [[ $first -le 64 && $second -le 64 ]] || return 1
        echo "$first $second"
        return
      fi
      if [[ $s =~ ^RTMAX-([0-9]{1,2})$ ]]; then
        n=$((64 - 10#${BASH_REMATCH[1]}))
        [[ $n -ge 34 && $n -le 64 ]] || return 1
        echo "$n"
        return
      fi
      [[ $s =~ ^[0-9]+$ ]] || return 1
      s=$((10#$s))
      [[ $s -ge 1 && $s -le 64 ]] || return 1
      echo "$s" ;;
  esac
}
signal_mask_state() {
  local cgt=$1 ign=$2 blk=$3 num=$4
  if mask_has_signal "$blk" "$num"; then echo blocked
  elif mask_has_signal "$ign" "$num"; then echo ignored
  elif mask_has_signal "$cgt" "$num"; then echo caught
  else echo unhandled
  fi
}
mask_has_signal() {
  local mask=$1 num=$2 half bit
  [[ ${#mask} -gt 16 ]] && mask=${mask: -16}
  printf -v mask '%016s' "$mask"
  mask=${mask// /0}
  if [[ $num -le 32 ]]; then half=${mask:8:8}; bit=$((num - 1))
  else half=${mask:0:8}; bit=$((num - 33))
  fi
  (( (16#$half & (1 << bit)) != 0 ))
}
check_stop_signal() {
  local name=$1 sig=$2 pid=$3 nums num other st cgt ign blk comm state other_state reason
  [[ $pid =~ ^[0-9]+$ && $pid -gt 0 ]] || return 0   # not running
  [[ -z $sig ]] && sig=SIGTERM
  if ! nums=$(sig_nums "$sig"); then emit INFO container.stop_signal "$name: stops with $sig (not checked)"; return; fi
  read -r num other <<<"$nums"
  [[ $num == 9 ]] && { emit INFO container.stop_signal "$name: stops with SIGKILL, which PID 1 cannot catch"; return; }
  st=$(rp "/proc/$pid/status")
  if [[ ! -r $st ]]; then emit SKIP container.stop_signal "$name: /proc/$pid/status unreadable (run as root on the host)"; return; fi
  cgt=$(awk '$1 == "SigCgt:" { print $2 }' "$st"); ign=$(awk '$1 == "SigIgn:" { print $2 }' "$st")
  blk=$(awk '$1 == "SigBlk:" { print $2 }' "$st")
  comm=$(cat "$(rp "/proc/$pid/comm")" 2>/dev/null); comm=${comm:-?}
  [[ $cgt =~ ^[0-9a-fA-F]+$ && $ign =~ ^[0-9a-fA-F]+$ && $blk =~ ^[0-9a-fA-F]+$ ]] || { emit SKIP container.stop_signal "$name: no signal masks in /proc/$pid/status"; return; }
  state=$(signal_mask_state "$cgt" "$ign" "$blk" "$num")
  if [[ -n ${other:-} ]]; then
    other_state=$(signal_mask_state "$cgt" "$ign" "$blk" "$other")
    if [[ $state != "$other_state" ]]; then
      emit INFO container.stop_signal "$name: docker stop sends $sig, but it was not checked because SIGRTMIN may be 34 or 35 and the two signal-mask readings disagree"
      return
    fi
  fi
  case $state in
    caught) emit OK container.stop_signal "$name: docker stop sends $sig and PID 1 ($comm) catches it" ;;
    blocked)
      emit INFO container.stop_signal "$name: docker stop sends $sig, but whether PID 1 ($comm) handles it is unknown because it is blocked; a process can consume it with sigwait or signalfd, and /proc masks are per-thread" ;;
    *)
      reason="no handler is registered"
      [[ $state == ignored ]] && reason="it is ignored"
      emit WARN container.stop_signal "$name: docker stop sends $sig, which PID 1 ($comm) does not catch ($reason): every stop waits the whole grace period, then SIGKILL. Set stop_signal in compose and trap it early in the entrypoint" ;;
  esac
}

check_containers() {
  local ids ps_out id name proj created sig pid line batch_out batch_n=0 inspected_n=0
  local -a batch=() inspected=()
  if ! ids=$(run_t docker ps -aq 2>/dev/null); then emit SKIP container.docker "docker ps failed (run with sudo)"; return; fi
  [[ -z $ids ]] && { emit INFO container.docker "no containers"; return; }
  if ! ps_out=$(run_t docker ps -a --format $'{{.ID}}\037{{.Names}}\037{{.Label "com.docker.compose.project"}}\037{{.Image}}' 2>/dev/null); then
    emit SKIP container.docker "docker ps -a --format failed; container metadata was not checked"
    return
  fi
  # Fields are split on \037, not a tab: tabs are IFS whitespace, so an empty compose label or stop
  # signal would collapse and shift every field after it.
  local -A project=() image=()
  while IFS=$'\037' read -r id name proj line; do
    [[ -z $id ]] && continue
    project[$name]=$proj; image[$name]=$line
  done <<<"$ps_out"
  while IFS= read -r id; do
    [[ -z $id ]] && continue
    batch+=("$id")
    batch_n=$((batch_n + 1))
    if [[ $batch_n -eq 50 ]]; then
      if batch_out=$(run_t docker inspect --format $'{{.Name}}\037{{.Created}}\037{{.Config.StopSignal}}\037{{.State.Pid}}' "${batch[@]}" 2>/dev/null); then
        inspected+=("$batch_out")
        inspected_n=$((inspected_n + 1))
      else
        emit SKIP container.docker "docker inspect failed for a batch of $batch_n container(s); that batch was not checked"
      fi
      batch=(); batch_n=0
    fi
  done <<<"$ids"
  if [[ $batch_n -gt 0 ]]; then
    if batch_out=$(run_t docker inspect --format $'{{.Name}}\037{{.Created}}\037{{.Config.StopSignal}}\037{{.State.Pid}}' "${batch[@]}" 2>/dev/null); then
      inspected+=("$batch_out")
      inspected_n=$((inspected_n + 1))
    else
      emit SKIP container.docker "docker inspect failed for a batch of $batch_n container(s); that batch was not checked"
    fi
  fi
  if [[ $inspected_n -gt 0 ]]; then
    for batch_out in "${inspected[@]}"; do
      while IFS=$'\037' read -r name created sig pid; do
        [[ -z $name ]] && continue
        name=${name#/}
        check_diff "$name"
        if [[ -z ${project[$name]:-} ]]; then
          if [[ ${created:0:10} > $SMS_SINCE || ${created:0:10} == "$SMS_SINCE" ]]; then
            emit WARN container.unmanaged "$name (image ${image[$name]:-?}) belongs to no compose project and was created ${created:0:19}, since $SMS_SINCE: who started it?"
          else
            emit INFO container.unmanaged "$name (image ${image[$name]:-?}) belongs to no compose project (started by hand?)"
          fi
        fi
        check_stop_signal "$name" "$sig" "$pid"
      done <<<"$batch_out"
    done
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --since)
        valid_ymd "${2:-}" || { echo "--since needs a date YYYY-MM-DD" >&2; return 2; }
        SMS_SINCE=$2; shift 2 ;;
      --max)
        [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "--max needs a number" >&2; return 2; }
        SMS_MAX=$((10#$2)); shift 2 ;;
      --root) [[ $# -ge 2 ]] || { echo "--root needs a directory" >&2; return 2; }; SMS_ROOT=${2%/}; shift 2 ;;
      --docker) SMS_DOCKER=on; shift ;;
      --no-docker) SMS_DOCKER=off; shift ;;
      --no-volumes) SMS_VOLUMES=0; shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "unknown argument: $1 (see --help)" >&2; return 2 ;;
    esac
  done
  if [[ -n $SMS_ROOT && ! -d $SMS_ROOT ]]; then echo "--root $SMS_ROOT is not a directory" >&2; return 2; fi
  return 0
}

main() {
  set -uo pipefail
  shopt -s nullglob
  parse_args "$@" || exit 2
  SMS_TO_OK=0; have timeout && timeout 5 true 2>/dev/null && SMS_TO_OK=1
  local want=0
  [[ $SMS_DOCKER == on || ($SMS_DOCKER == auto && -z $SMS_ROOT) ]] && want=1
  SMS_USE_DOCKER=0; [[ $want == 1 ]] && have docker && SMS_USE_DOCKER=1
  printf '# %s: writable layers cover the whole life of each container; volumes are not date-filtered; --since=%s grades only containers outside Compose (root=%s, docker=%s). Never prints file contents or session ids.\n' \
    "$SMS_NAME" "$SMS_SINCE" "${SMS_ROOT:-/}" "$([[ $SMS_USE_DOCKER == 1 ]] && echo yes || echo no)"
  [[ $want == 1 && $SMS_USE_DOCKER == 0 ]] && emit SKIP container.docker "docker not on PATH"
  [[ $EUID -ne 0 ]] && emit INFO container.privileges "not running as root: volume directories and /proc may be SKIP"
  [[ $SMS_USE_DOCKER == 1 ]] && check_containers
  [[ $SMS_VOLUMES == 1 ]] && check_volumes
  summary
  exit 0
}

[[ -n "${SMS_TEST:-}" ]] || main "$@"
