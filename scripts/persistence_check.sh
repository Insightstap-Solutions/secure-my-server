#!/usr/bin/env bash
# persistence_check.sh - after a possible break-in: did the attacker leave a way back in?
# Accounts, sudoers, SSH keys, cron, systemd units, ld.so.preload, rc.local, deleted/miner processes,
# outbound connections, risky Docker containers.
#
# READ-ONLY. Reads /etc, home directories' .ssh, cron spools and /proc; runs ss/netstat, ps,
# ssh-keygen -lf (fingerprints only), dpkg/rpm ownership queries and docker ps/inspect.
# NEVER prints key material, crontab lines or file contents: only paths, counts, fingerprints and rule names.
#
#   ssh host 'sudo bash -s -- --since 2026-10-15' < scripts/persistence_check.sh
#
# Output: LEVEL<TAB>CHECK<TAB>DETAIL lines, then SUMMARY. Exit 0 always; 2 on bad arguments.

SMS_NAME=persistence_check
SMS_ROOT=""
SMS_SINCE="2026-10-15"
SMS_DOCKER="auto"
SMS_TIMEOUT=20
SMS_N_CRIT=0; SMS_N_WARN=0; SMS_N_INFO=0; SMS_N_OK=0; SMS_N_SKIP=0
SMS_MINERS="kdevtmpfsi|kinsing|xmrig|xmr|minerd|c3pool|sysrv|watchbog|tsunami"
SINCE_EPOCH=0

usage() {
  cat <<'EOF'
persistence_check.sh [--since YYYY-MM-DD] [--root DIR] [--docker|--no-docker] [--help]

Checks (since = --since, default 2026-10-15):
  accounts      uid-0 accounts other than root (CRIT); login-shell accounts; /etc/passwd, /etc/shadow
                changed since; password last changed since (from /etc/shadow field 3 only)
  sudoers       /etc/sudoers and /etc/sudoers.d/* changed since; count of NOPASSWD lines
  ssh_keys      every authorized_keys / authorized_keys2: key count, ssh-keygen -lf fingerprints and
                comments, mtime (WARN when changed since). Key material is never printed
  cron          /etc/crontab, /etc/cron.d, /etc/cron.{hourly,daily,weekly,monthly}, /var/spool/cron*:
                lines with curl|wget|base64|/dev/tcp|bash -i|nc |python -c|perl -e (file:line + rule
                names only), and files changed since
  systemd       unit files changed since that no package owns (dpkg -S / rpm -qf; /lib <-> /usr/lib
                are both tried), plus per-user ~/.config/systemd/user units
  preload       /etc/ld.so.preload non-empty (CRIT); /etc/rc.local with commands
  processes     processes running a deleted binary; known miner/backdoor names; top CPU (name only)
  network       ESTABLISHED outbound connections to public addresses, with process names
  docker        privileged containers, host network, docker.sock mounted, created since

Options:
  --since DATE   YYYY-MM-DD (default 2026-10-15)
  --root DIR     prefix for every FILE path inspected (tests / mounted images); commands from PATH
  --docker / --no-docker   (default: docker when on PATH and no --root)
  --help         this text

READ-ONLY. Run as root, otherwise shadow, other users' keys and crontabs are unreadable (SKIP lines).
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
mtime() { stat -c %Y -- "$1" 2>/dev/null || echo 0; }
fmt_epoch() { date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$1"; }
is_new() { [[ $(mtime "$1") -ge $SINCE_EPOCH ]]; }

check_accounts() {
  local pw sh user uid home shell n=0 f logins=" "
  pw=$(rp /etc/passwd)
  [[ -r $pw ]] || { emit SKIP persist.accounts "/etc/passwd unreadable"; return; }
  while IFS=: read -r user _ uid _ _ home shell; do
    [[ $uid == 0 && $user != root ]] && emit CRIT persist.uid0 "account '$user' has uid 0 (a second root)"
    case $shell in */nologin | */false | */sync | */shutdown | */halt | "") continue ;; esac
    n=$((n + 1)); logins+="$user "
    emit INFO persist.login_shell "$user uid=$uid shell=$shell home=$home"
  done <"$pw"
  emit INFO persist.accounts "$n account(s) with a login shell"
  for f in /etc/passwd /etc/shadow /etc/group; do
    [[ -e $(rp "$f") ]] || continue
    if is_new "$(rp "$f")"; then emit WARN persist.accounts "$f changed since $SMS_SINCE ($(fmt_epoch "$(mtime "$(rp "$f")")")): compare with a backup (/etc/$(basename "$f")-)"; fi
  done
  sh=$(rp /etc/shadow)
  if [[ -r $sh ]]; then
    local since_days=$((SINCE_EPOCH / 86400)) last
    # Field 1 (name), 3 (day of last change) and whether field 2 starts with ! or * (locked) are
    # used; the hash itself is never printed. Only accounts with a login shell are considered:
    # every system account of a freshly built image has a recent field 3.
    local hash state
    while IFS=: read -r user hash last _; do
      [[ $logins == *" $user "* && $last =~ ^[0-9]+$ ]] || continue
      state="password set"; [[ -z $hash || $hash == '!'* || $hash == '*'* ]] && state="password locked/empty"
      [[ $last -ge $since_days ]] && emit WARN persist.password_changed "$user: password changed on $(fmt_epoch $((last * 86400)) | cut -d' ' -f1) (since $SMS_SINCE; $state)"
    done <"$sh"
    hash=""
  else
    emit SKIP persist.password_changed "/etc/shadow unreadable (run as root)"
  fi
}

check_sudoers() {
  local f n
  for f in "$(rp /etc/sudoers)" "$(rp /etc/sudoers.d)"/*; do
    [[ -f $f ]] || continue
    if [[ ! -r $f ]]; then emit SKIP persist.sudoers "${f#"$SMS_ROOT"} unreadable (run as root)"; continue; fi
    n=$(grep -cE '^[^#]*NOPASSWD' "$f")
    if is_new "$f"; then
      emit WARN persist.sudoers "${f#"$SMS_ROOT"} changed since $SMS_SINCE ($(fmt_epoch "$(mtime "$f")")), NOPASSWD lines: $n"
    else
      emit INFO persist.sudoers "${f#"$SMS_ROOT"} NOPASSWD lines: $n"
    fi
  done
}

check_ssh_keys() {
  local user home f n fp lvl seen=" "
  while IFS=: read -r user _ _ _ _ home _; do
    [[ -n $home && $home != / ]] || continue
    for f in "$(rp "$home")/.ssh/authorized_keys" "$(rp "$home")/.ssh/authorized_keys2"; do
      [[ -e $f ]] || continue
      [[ $seen == *" $f "* ]] && continue
      seen+="$f "
      if [[ ! -r $f ]]; then emit SKIP persist.ssh_keys "${f#"$SMS_ROOT"} unreadable (run as root)"; continue; fi
      n=$(grep -cvE '^[[:space:]]*(#|$)' "$f")
      lvl=INFO; is_new "$f" && lvl=WARN
      fp="ssh-keygen not available"
      if have ssh-keygen; then
        # -l prints bits, fingerprint, comment, type: no key material.
        fp=$(run_t ssh-keygen -lf "$f" 2>/dev/null | awk '{ $1 = $1; print }' | paste -sd ';' -)
        [[ -z $fp ]] && fp="no parseable keys"
      fi
      # a key line that does not START with a key type carries options (command=, from=, no-pty ...)
      local opts; opts=$(grep -cvE '^[[:space:]]*(#|$|ssh-|ecdsa-|sk-)' "$f")
      emit "$lvl" persist.ssh_keys "${f#"$SMS_ROOT"} user=$user keys=$n with_options=$opts mtime=$(fmt_epoch "$(mtime "$f")")$([[ $lvl == WARN ]] && printf ' CHANGED SINCE %s' "$SMS_SINCE") fingerprints: $fp"
    done
  done <"$(rp /etc/passwd)"
}

# Rule names for a cron line (never the line itself).
cron_rules() {
  local l=$1 r=""
  [[ $l =~ (curl|wget)[^|]*\|[[:space:]]*(ba|da|z)?sh ]] && r+="download_pipe_shell,"
  [[ $l =~ (^|[^a-z])curl([^a-z]|$) ]] && r+="curl,"
  [[ $l =~ (^|[^a-z])wget([^a-z]|$) ]] && r+="wget,"
  [[ $l =~ base64 ]] && r+="base64,"
  [[ $l =~ /dev/tcp ]] && r+="dev_tcp,"
  [[ $l =~ bash[[:space:]]+-i ]] && r+="bash_i,"
  [[ $l =~ (^|[^a-z])nc[[:space:]] ]] && r+="nc,"
  [[ $l =~ python[0-9.]*[[:space:]]+-c ]] && r+="python_c,"
  [[ $l =~ perl[[:space:]]+-e ]] && r+="perl_e,"
  printf '%s' "${r%,}"
}
check_cron() {
  local f d n i line rules lvl hits
  local -a files=()
  for f in "$(rp /etc/crontab)" "$(rp /etc/anacrontab)"; do [[ -f $f ]] && files+=("$f"); done
  for d in /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly \
    /var/spool/cron /var/spool/cron/crontabs /var/spool/cron/tabs; do
    for f in "$(rp "$d")"/*; do [[ -f $f ]] && files+=("$f"); done
  done
  n=0
  for f in ${files[@]+"${files[@]}"}; do
    [[ $(basename "$f") == .placeholder ]] && continue
    if [[ ! -r $f ]]; then emit SKIP persist.cron "${f#"$SMS_ROOT"} unreadable (run as root)"; continue; fi
    n=$((n + 1)); i=0; hits=0
    while IFS= read -r line || [[ -n $line ]]; do
      i=$((i + 1))
      [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
      rules=$(cron_rules "$line")
      [[ -z $rules ]] && continue
      hits=$((hits + 1))
      lvl=WARN
      [[ $rules =~ (download_pipe_shell|dev_tcp|bash_i|base64) ]] && lvl=CRIT
      emit "$lvl" persist.cron "${f#"$SMS_ROOT"}:$i rules=$rules"
    done <"$f"
    if is_new "$f"; then emit WARN persist.cron "${f#"$SMS_ROOT"} changed since $SMS_SINCE ($(fmt_epoch "$(mtime "$f")"))"; fi
  done
  emit INFO persist.cron "$n cron file(s) read"
}

# pkg owner of a path; tries the /lib <-> /usr/lib twin (Ubuntu/Debian merged /usr).
owned_by_pkg() {
  local p=$1 alt=""
  case $p in /lib/*) alt="/usr$p" ;; /usr/lib/*) alt="${p#/usr}" ;; esac
  if have dpkg-query; then
    dpkg-query -S "$p" >/dev/null 2>&1 && return 0
    [[ -n $alt ]] && dpkg-query -S "$alt" >/dev/null 2>&1 && return 0
  fi
  if have rpm; then
    rpm -qf "$p" >/dev/null 2>&1 && return 0
    [[ -n $alt ]] && rpm -qf "$alt" >/dev/null 2>&1 && return 0
  fi
  return 1
}
check_systemd() {
  local d f p n=0 home user can_check=0
  have dpkg-query && can_check=1
  have rpm && can_check=1
  local -a dirs=(/etc/systemd/system /lib/systemd/system /usr/lib/systemd/system /usr/local/lib/systemd/system /etc/systemd/user)
  while IFS=: read -r user _ _ _ _ home _; do
    [[ -n $home && $home != / && -d $(rp "$home/.config/systemd/user") ]] && dirs+=("$home/.config/systemd/user")
  done <"$(rp /etc/passwd)"
  for d in "${dirs[@]}"; do
    [[ -d $(rp "$d") && ! -L $(rp "$d") ]] || continue
    while IFS= read -r -d '' f; do
      p=${f#"$SMS_ROOT"}
      is_new "$f" || continue
      n=$((n + 1))
      if [[ $p == */.config/systemd/user/* ]]; then
        emit WARN persist.systemd "$p: per-user unit changed since $SMS_SINCE ($(fmt_epoch "$(mtime "$f")"))"
      elif [[ $can_check == 0 ]]; then
        emit WARN persist.systemd "$p changed since $SMS_SINCE; no dpkg/rpm to check ownership"
      elif ! owned_by_pkg "$p"; then
        emit WARN persist.systemd "$p changed since $SMS_SINCE ($(fmt_epoch "$(mtime "$f")")) and no package owns it"
      fi
    done < <(find "$(rp "$d")" -maxdepth 2 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.socket' -o -name '*.path' \) -print0 2>/dev/null)
  done
  emit INFO persist.systemd "$n unit file(s) changed since $SMS_SINCE (unowned ones listed above)"
}

check_preload() {
  local f n
  f=$(rp /etc/ld.so.preload)
  if [[ -s $f ]]; then
    n=$(grep -cvE '^[[:space:]]*(#|$)' "$f")
    if [[ $n -gt 0 ]]; then
      # library PATHS are listed (they are the indicator); nothing else from the file
      emit CRIT persist.ld_preload "/etc/ld.so.preload lists $n librar(y/ies): $(grep -vE '^[[:space:]]*(#|$)' "$f" | tr -s ' \t' '\n' | grep -E '^/' | paste -sd ' ' -). This hooks every process: classic rootkit"
    else
      emit OK persist.ld_preload "/etc/ld.so.preload has only comments"
    fi
  else
    emit OK persist.ld_preload "/etc/ld.so.preload absent or empty"
  fi
  for f in /etc/rc.local /etc/rc.d/rc.local; do
    [[ -f $(rp "$f") ]] || continue
    n=$(grep -cvE '^[[:space:]]*(#|$|exit 0)' "$(rp "$f")")
    if [[ $n -gt 0 ]]; then
      local lvl=INFO; is_new "$(rp "$f")" && lvl=WARN
      emit "$lvl" persist.rc_local "$f has $n command line(s), mtime $(fmt_epoch "$(mtime "$(rp "$f")")")"
    fi
  done
}

check_processes() {
  local d pid exe comm arg0 base
  for d in "$(rp /proc)"/[0-9]*; do
    [[ -d $d ]] || continue
    pid=${d##*/}
    comm=$(cat "$d/comm" 2>/dev/null)
    exe=$(readlink "$d/exe" 2>/dev/null) || exe=""
    arg0=$({ tr '\0' '\n' <"$d/cmdline"; } 2>/dev/null | head -n1)
    arg0=${arg0##*/}
    base=${exe##*/}; base=${base% (deleted)}
    if [[ $comm =~ ^($SMS_MINERS) || $base =~ ^($SMS_MINERS) || $arg0 =~ ^($SMS_MINERS) ]]; then
      emit CRIT persist.miner "pid $pid comm=$comm exe=${exe:-?}: known miner/backdoor name"
    fi
    if [[ $exe == *" (deleted)" ]]; then
      if [[ $exe =~ ^/(tmp|var/tmp|dev/shm)/ ]]; then
        emit CRIT persist.deleted_exe "pid $pid comm=$comm runs a DELETED binary from a temp dir: $exe"
      else
        emit WARN persist.deleted_exe "pid $pid comm=$comm runs a deleted binary $exe (often an upgrade without restart; malware also deletes itself)"
      fi
    fi
  done
  if have ps; then
    local line
    while IFS= read -r line; do
      [[ -n $line ]] && emit INFO persist.top_cpu "$line"
    done < <(ps -eo pid=,user=,pcpu=,comm= 2>/dev/null | sort -k3 -n -r | head -n 5 | awk '{ printf "pid=%s user=%s cpu=%s%% comm=%s\n", $1, $2, $3, $4 }')
  fi
}

is_private() {
  local a=${1#::ffff:}
  [[ $a =~ ^(127\.|10\.|192\.168\.|169\.254\.|0\.) || $a =~ ^172\.(1[6-9]|2[0-9]|3[01])\. || $a =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ||
    $a == ::1 || ${a,,} =~ ^(fe80|fc|fd) || $a == "*" ]]
}
check_network() {
  local out lports="" line local_a peer proc lp pa pp lvl
  if have ss; then
    lports=" $(run_t ss -ltn 2>/dev/null | awk '$1 == "LISTEN" { p = $4; sub(/.*:/, "", p); print p }' | sort -u | tr '\n' ' ')"
    out=$(run_t ss -tnp 2>/dev/null | awk '$1 == "ESTAB" { proc = "?"; if (match($0, /users:\(\("[^"]+"/)) proc = substr($0, RSTART + 9, RLENGTH - 10); print $4 " " $5 " " proc }')
  elif have netstat; then
    lports=" $(run_t netstat -ltn 2>/dev/null | awk '$6 == "LISTEN" { p = $4; sub(/.*:/, "", p); print p }' | sort -u | tr '\n' ' ')"
    out=$(run_t netstat -tnp 2>/dev/null | awk '$6 == "ESTABLISHED" { proc = $7; sub(/^[0-9]+\//, "", proc); print $4 " " $5 " " proc }')
  else
    emit SKIP persist.outbound "neither ss nor netstat available"; return
  fi
  local n=0
  while read -r local_a peer proc; do
    [[ -z $peer ]] && continue
    lp=${local_a##*:}
    [[ $lports == *" $lp "* ]] && continue      # inbound to one of our listeners
    pa=${peer%:*}; pp=${peer##*:}; pa=${pa#[}; pa=${pa%]}
    is_private "$pa" && continue
    n=$((n + 1)); lvl=INFO
    [[ $proc =~ ^(sh|bash|dash|zsh|perl|python[0-9.]*|nc|ncat|netcat|socat|php|php-cgi)$ ]] && lvl=WARN
    [[ $pp =~ ^(3333|4444|5555|7777|8888|14444|14433|45700)$ ]] && lvl=CRIT
    emit "$lvl" persist.outbound "$proc -> $pa:$pp"
  done <<<"$out"
  emit INFO persist.outbound "$n established outbound connection(s) to public addresses"
}

check_docker() {
  if ! have docker; then emit INFO persist.docker "docker not installed"; return; fi
  local ids name priv net created mounts lvl
  if ! ids=$(run_t docker ps -aq 2>/dev/null); then emit SKIP persist.docker "docker ps failed (run with sudo)"; return; fi
  [[ -z $ids ]] && { emit INFO persist.docker "no containers"; return; }
  # shellcheck disable=SC2086  # ids are word-split on purpose
  while IFS=$'\t' read -r name priv net created mounts; do
    [[ -z $name ]] && continue
    name=${name#/}
    [[ $priv == true ]] && emit WARN persist.docker "$name runs --privileged (root on the host if compromised)"
    [[ $net == host ]] && emit INFO persist.docker "$name uses the host network"
    if [[ ,$mounts, == *",/var/run/docker.sock,"* || ,$mounts, == *",/run/docker.sock,"* ]]; then
      emit WARN persist.docker "$name mounts the Docker socket (full control of the host)"
    fi
    if [[ ,$mounts, == *",/,"* ]]; then emit CRIT persist.docker "$name mounts the host root filesystem /"; fi
    if [[ ${created:0:10} > $SMS_SINCE || ${created:0:10} == "$SMS_SINCE" ]]; then
      lvl=INFO; [[ $priv == true || ,$mounts, == *docker.sock* ]] && lvl=WARN
      emit "$lvl" persist.docker "$name created ${created:0:19} (since $SMS_SINCE)"
    fi
  done < <(run_t docker inspect --format $'{{.Name}}\t{{.HostConfig.Privileged}}\t{{.HostConfig.NetworkMode}}\t{{.Created}}\t{{range .Mounts}}{{.Source}},{{end}}' $ids 2>/dev/null)
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --since)
        valid_ymd "${2:-}" || { echo "--since needs a date YYYY-MM-DD" >&2; return 2; }
        SMS_SINCE=$2; shift 2 ;;
      --root) [[ $# -ge 2 ]] || { echo "--root needs a directory" >&2; return 2; }; SMS_ROOT=${2%/}; shift 2 ;;
      --docker) SMS_DOCKER=on; shift ;;
      --no-docker) SMS_DOCKER=off; shift ;;
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
  SINCE_EPOCH=$(ymd_epoch "$SMS_SINCE")
  printf '# %s: ways back in, changed since %s (root=%s). Never prints keys, crontab lines or file contents.\n' \
    "$SMS_NAME" "$SMS_SINCE" "${SMS_ROOT:-/}"
  [[ $EUID -ne 0 ]] && emit INFO persist.privileges "not running as root: shadow, other users' keys and crontabs will be SKIP"
  if [[ -r $(rp /etc/passwd) ]]; then
    check_accounts
    check_sudoers
    check_ssh_keys
    check_systemd
  else
    emit SKIP persist.accounts "/etc/passwd unreadable"
  fi
  check_cron
  check_preload
  check_processes
  check_network
  if [[ $SMS_DOCKER == on || ($SMS_DOCKER == auto && -z $SMS_ROOT) ]]; then check_docker; fi
  summary
  exit 0
}

[[ -n "${SMS_TEST:-}" ]] || main "$@"
