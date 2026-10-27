#!/usr/bin/env bash
# detect_stack.sh - what kind of server is this? OS, init, container/VM, control panels, web servers
# (and who really owns :80/:443), PHP runtimes (short list), Docker, firewall tooling, and every
# listener on all interfaces, with public database/cache/FastCGI ports flagged.
#
# READ-ONLY. Reads files under /etc, /proc, /sys and runs ss/netstat, docker ps, ufw/firewalld/nft/
# iptables listing commands and `<php> -v`. It changes nothing.
#
#   ssh host 'sudo bash -s' < scripts/detect_stack.sh
#
# Output: LEVEL<TAB>CHECK<TAB>DETAIL lines, then SUMMARY. Exit 0 always; 2 on bad arguments.

SMS_NAME=detect_stack
SMS_ROOT=""
SMS_DOCKER="auto"
SMS_TIMEOUT=15
SMS_N_CRIT=0; SMS_N_WARN=0; SMS_N_INFO=0; SMS_N_OK=0; SMS_N_SKIP=0
# Ports that must never be reachable from the internet: MySQL, PostgreSQL, Redis, MongoDB,
# Elasticsearch, Memcached, CouchDB, PHP-FPM (FastCGI = remote code execution).
SMS_DB_PORTS="3306 5432 6379 27017 9200 11211 5984 9000"
FW_ACTIVE=""          # names of active firewall tools, space separated
DOCKER_USER_FILTERS=0 # 1 when the DOCKER-USER chain holds rules beyond the default RETURN
LISTENERS=""          # "addr SEP port SEP process" lines, filled by collect_listeners
SEP=$'\037'

usage() {
  cat <<'EOF'
detect_stack.sh [--root DIR] [--docker|--no-docker] [--help]

Reports what this server is, so later steps pick the right commands:
  OS + version (/etc/os-release), init system, container/VM hint, control panels (cPanel, Plesk,
  aaPanel, DirectAdmin, CyberPanel, HestiaCP, Webmin, ISPConfig), web servers present and which
  process owns :80/:443 (ss -ltnp, fallback netstat -ltnp), more than one nginx binary (WARN),
  PHP runtimes (short list; run php_runtimes.sh for detail), Docker containers and compose
  projects, firewall tooling (ufw, firewalld, nftables, iptables DOCKER-USER), every listener on
  0.0.0.0/[::], and CRIT for database/cache/php-fpm ports listening publicly (3306 5432 6379 27017
  9200 11211 5984 9000) unless a firewall is active (then WARN). The script cannot prove
  reachability: always check from OUTSIDE (e.g. nc -vz HOST PORT from another machine).

Options:
  --root DIR     prefix for every FILE path inspected (tests / mounted images); commands still
                 come from PATH
  --docker       query docker (default when docker is on PATH and no --root)
  --no-docker    do not query docker
  --help         this text

READ-ONLY: reads files and runs listing commands only. Run as root for process names on sockets.
Output: LEVEL<TAB>CHECK<TAB>DETAIL (LEVEL = CRIT WARN INFO OK SKIP), '#' headers, SUMMARY last.
Exit 0 always; 2 on bad arguments.
EOF
}

# ---------- tiny helpers (duplicated in every script on purpose: scripts travel alone over ssh) ----------
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
# Read KEY from an os-release style file without sourcing it (sourcing would execute it).
osr() { sed -nE "s/^$1=\"?([^\"]*)\"?\$/\\1/p" "$2" 2>/dev/null | head -n1; }

check_os() {
  local f id ver pretty
  f=$(rp /etc/os-release); [[ -r $f ]] || f=$(rp /usr/lib/os-release)
  if [[ -r $f ]]; then
    id=$(osr ID "$f"); ver=$(osr VERSION_ID "$f"); pretty=$(osr PRETTY_NAME "$f")
    emit INFO stack.os "${pretty:-unknown} (id=${id:-?} version=${ver:-?} like=$(osr ID_LIKE "$f"))"
  elif [[ -r $(rp /etc/alpine-release) ]]; then
    emit INFO stack.os "Alpine $(head -n1 "$(rp /etc/alpine-release)")"
  elif [[ -r $(rp /etc/redhat-release) ]]; then
    emit INFO stack.os "$(head -n1 "$(rp /etc/redhat-release)")"
  else
    emit SKIP stack.os "no /etc/os-release"
  fi
  local k; k=$(cat "$(rp /proc/sys/kernel/osrelease)" 2>/dev/null)
  [[ -n $k ]] && emit INFO stack.kernel "$k"
}

check_init() {
  local p1 init
  p1=$(cat "$(rp /proc/1/comm)" 2>/dev/null)
  if [[ -d $(rp /run/systemd/system) ]]; then init=systemd
  elif [[ -n $p1 ]]; then init=$p1
  elif [[ -x $(rp /sbin/openrc) || -d $(rp /etc/init.d) ]]; then init="sysvinit/openrc (guess)"
  else init=unknown; fi
  emit INFO stack.init "init=$init (pid 1: ${p1:-unreadable})"
}

check_virt() {
  local hints="" v cg prod vendor
  [[ -e $(rp /.dockerenv) ]] && hints+="docker-container "
  [[ -e $(rp /run/.containerenv) ]] && hints+="podman-container "
  cg=$(cat "$(rp /proc/1/cgroup)" 2>/dev/null)
  [[ $cg =~ (docker|containerd|kubepods|lxc|libpod) ]] && hints+="cgroup:${BASH_REMATCH[1]} "
  if [[ -z $SMS_ROOT ]] && have systemd-detect-virt; then
    v=$(run_t systemd-detect-virt 2>/dev/null); [[ -n $v ]] && hints+="systemd-detect-virt:$v "
  fi
  prod=$(cat "$(rp /sys/class/dmi/id/product_name)" 2>/dev/null)
  vendor=$(cat "$(rp /sys/class/dmi/id/sys_vendor)" 2>/dev/null)
  [[ -n $prod || -n $vendor ]] && hints+="dmi:'${vendor:-?} ${prod:-?}' "
  grep -qw hypervisor "$(rp /proc/cpuinfo)" 2>/dev/null && hints+="cpu:hypervisor-flag "
  emit INFO stack.virt "${hints:-no container/VM hint (bare metal, or unreadable)}"
  [[ $hints == *container* || $hints == *cgroup:* ]] &&
    emit WARN stack.virt "this looks like the INSIDE of a container: the host's listeners, panels and firewall are not visible from here"
}

check_panels() {
  local n=0 entry name path found=""
  for entry in "cPanel:/usr/local/cpanel" "Plesk:/usr/local/psa" "aaPanel:/www/server/panel" \
    "DirectAdmin:/usr/local/directadmin" "CyberPanel:/usr/local/CyberCP" "HestiaCP:/usr/local/hestia" \
    "Webmin:/etc/webmin" "ISPConfig:/usr/local/ispconfig"; do
    name=${entry%%:*}; path=${entry#*:}
    if [[ -d $(rp "$path") ]]; then n=$((n + 1)); found+="$name "; emit INFO stack.panel "$name ($path)"; fi
  done
  if [[ $n -eq 0 ]]; then emit INFO stack.panel "no control panel found (plain server)"
  elif [[ $n -gt 1 ]]; then emit WARN stack.panel "more than one control panel: ${found% }; they fight over web server and PHP config"; fi
}

check_webservers() {
  local entry name path nginx=() f
  for entry in "nginx:/usr/sbin/nginx" "nginx:/usr/local/nginx/sbin/nginx" "nginx:/www/server/nginx/sbin/nginx" \
    "nginx:/usr/local/openresty/nginx/sbin/nginx" "nginx:/usr/bin/nginx" \
    "apache:/usr/sbin/apache2" "apache:/usr/sbin/httpd" "apache:/usr/local/apache/bin/httpd" \
    "apache:/www/server/apache/bin/httpd" "apache:/usr/local/apache2/bin/httpd" \
    "litespeed:/usr/local/lsws/bin/lshttpd" "litespeed:/usr/local/lsws/bin/openlitespeed" \
    "caddy:/usr/bin/caddy" "caddy:/usr/local/bin/caddy" "lighttpd:/usr/sbin/lighttpd" \
    "traefik:/usr/local/bin/traefik" "traefik:/usr/bin/traefik"; do
    name=${entry%%:*}; path=${entry#*:}
    f=$(rp "$path")
    [[ -f $f && -x $f ]] || continue
    # /usr/sbin/nginx and /usr/bin/nginx are often the same file via the /usr merge.
    if [[ $name == nginx ]]; then
      local dup=0 x
      for x in ${nginx[@]+"${nginx[@]}"}; do [[ $(rp "$x") -ef $f ]] && dup=1; done
      [[ $dup == 1 ]] && continue
      nginx+=("$path")
    fi
    emit INFO stack.webserver "$name binary at $path"
  done
  if [[ ${#nginx[@]} -gt 1 ]]; then
    emit WARN stack.webserver "${#nginx[@]} nginx binaries: ${nginx[*]}. A package nginx and a panel nginx can both claim init scripts; after a reboot the wrong one may start and :443 stays down. Make sure exactly one is enabled."
  fi
}

# ---------- sockets ----------
# Prints "addr SEP port SEP process" for each TCP listener.
collect_listeners() {
  local out
  if have ss; then
    out=$(run_t ss -ltnp 2>/dev/null)
    awk -v S="$SEP" '$1 == "LISTEN" { a = $4; p = a; sub(/.*:/, "", p); sub(/:[^:]*$/, "", a); sub(/%.*/, "", a)
        proc = "?"; if (match($0, /users:\(\("[^"]+"/)) { proc = substr($0, RSTART + 9, RLENGTH - 10) }
        print a S p S proc }' <<<"$out"
  elif have netstat; then
    out=$(run_t netstat -ltnp 2>/dev/null)
    awk -v S="$SEP" '$1 ~ /^tcp/ && $6 == "LISTEN" { a = $4; p = a; sub(/.*:/, "", p); sub(/:[^:]*$/, "", a)
        proc = $7; sub(/^[0-9]+\//, "", proc); sub(/:.*/, "", proc); if (proc == "-" || proc == "") proc = "?"
        print a S p S proc }' <<<"$out"
  else
    return 1
  fi
}
is_wild() { [[ $1 == 0.0.0.0 || $1 == "*" || $1 == "[::]" || $1 == "::" || $1 == "[::ffff:0.0.0.0]" ]]; }
is_loopback() { [[ $1 == 127.* || $1 == "[::1]" || $1 == ::1 || $1 == localhost ]]; }

check_listeners() {
  if ! LISTENERS=$(collect_listeners); then
    emit SKIP stack.listen "neither ss nor netstat available"; return
  fi
  if [[ -z $LISTENERS ]]; then emit SKIP stack.listen "no listeners parsed (run as root?)"; return; fi
  local a p proc web=""
  while IFS=$SEP read -r a p proc; do
    [[ -z $p ]] && continue
    if [[ $p == 80 || $p == 443 ]]; then web+="${web:+, }:$p=$proc@$a"; fi
    if is_loopback "$a"; then continue; fi
    if is_wild "$a"; then emit INFO stack.listen "$a:$p $proc (all interfaces)"
    else emit INFO stack.listen "$a:$p $proc (specific address)"; fi
  done <<<"$LISTENERS"
  if [[ -n $web ]]; then emit INFO stack.web_owner "ports 80/443 owned by: $web"
  else emit INFO stack.web_owner "nothing listens on :80/:443 (or process names need root)"; fi
  if grep -q "docker-proxy" <<<"$LISTENERS"; then
    emit INFO stack.listen "docker-proxy owns published container ports: those bypass ufw/firewalld INPUT rules; only DOCKER-USER filters them"
  fi
}

check_firewall() {
  local en out rules
  en=$(sed -nE 's/^ENABLED=(.*)/\1/p' "$(rp /etc/ufw/ufw.conf)" 2>/dev/null | tr -d '"')
  if [[ $en == yes ]]; then FW_ACTIVE+="ufw "; emit INFO stack.firewall "ufw enabled (/etc/ufw/ufw.conf)"
  elif [[ -n $en ]]; then emit INFO stack.firewall "ufw installed but disabled"; fi
  local d
  for d in "$(rp /proc)"/[0-9]*; do
    [[ $(cat "$d/comm" 2>/dev/null) == firewalld ]] && { FW_ACTIVE+="firewalld "; emit INFO stack.firewall "firewalld running (pid ${d##*/})"; break; }
  done
  if have nft; then
    out=$(run_t nft list ruleset 2>/dev/null)
    rules=$(grep -cE '^\s+(ip|ip6|tcp|udp|ct|iif|iifname|meta|counter|jump|drop|accept|reject)' <<<"$out")
    if [[ $rules -gt 0 ]]; then FW_ACTIVE+="nftables "; emit INFO stack.firewall "nftables ruleset has $rules rule lines"
    else emit INFO stack.firewall "nftables ruleset empty or unreadable (root needed)"; fi
  fi
  if have iptables; then
    out=$(run_t iptables -S DOCKER-USER 2>/dev/null)
    if [[ -z $out ]]; then
      emit INFO stack.firewall "iptables: no DOCKER-USER chain (Docker absent, or not readable without root)"
    else
      rules=$(grep -E '^-A DOCKER-USER' <<<"$out" | grep -cvE '^-A DOCKER-USER -j RETURN$')
      if [[ $rules -gt 0 ]]; then DOCKER_USER_FILTERS=1; emit INFO stack.firewall "iptables DOCKER-USER has $rules filtering rule(s)"
      else emit WARN stack.firewall "iptables DOCKER-USER chain is empty: every port Docker publishes on 0.0.0.0 is open to the internet regardless of ufw"; fi
    fi
  fi
  [[ -z $FW_ACTIVE ]] && emit WARN stack.firewall "no active host firewall detected (ufw/firewalld/nftables); a cloud firewall may still exist: check the provider console"
}
ufw_allows_port() { # explicit "allow PORT from anywhere" in ufw's own rule files
  grep -qE "^### tuple ### allow (tcp|any) $1 0\.0\.0\.0/0 any 0\.0\.0\.0/0 in" "$(rp /etc/ufw/user.rules)" 2>/dev/null
}

check_db_ports() {
  local a p proc port lvl why
  [[ -z $LISTENERS ]] && return
  while IFS=$SEP read -r a p proc; do
    for port in $SMS_DB_PORTS; do
      [[ $p == "$port" ]] || continue
      is_loopback "$a" && continue
      why=""
      if [[ $proc == docker-proxy ]]; then
        if [[ $DOCKER_USER_FILTERS == 1 ]]; then lvl=WARN; why="published by Docker; DOCKER-USER has rules"
        else lvl=CRIT; why="published by Docker: ufw/firewalld do not filter it"; fi
      elif ufw_allows_port "$port"; then lvl=CRIT; why="ufw explicitly allows it from anywhere"
      elif [[ -n $FW_ACTIVE ]]; then lvl=WARN; why="a firewall is active (${FW_ACTIVE% }) but this script cannot prove it blocks the port"
      else lvl=CRIT; why="no host firewall detected"; fi
      emit "$lvl" stack.public_port "$a:$p ($proc) $(port_name "$p") listens beyond localhost: $why. Check from outside: nc -vz <server-ip> $p"
    done
  done <<<"$LISTENERS"
}
port_name() {
  case $1 in 3306) echo MySQL ;; 5432) echo PostgreSQL ;; 6379) echo Redis ;; 27017) echo MongoDB ;;
    9200) echo Elasticsearch ;; 11211) echo Memcached ;; 5984) echo CouchDB ;; 9000) echo "PHP-FPM/FastCGI (remote code execution if reachable)" ;; esac
}

check_php_short() {
  local g f base v n=0
  # Patterns are quoted so they are expanded under --root, never against this machine.
  for g in "/usr/bin/php*" "/usr/sbin/php-fpm*" "/usr/local/bin/php*" "/usr/local/sbin/php-fpm*" \
    "/opt/remi/php*/root/usr/bin/php" "/opt/remi/php*/root/usr/sbin/php-fpm" \
    "/opt/cpanel/ea-php*/root/usr/bin/php" "/opt/cpanel/ea-php*/root/usr/sbin/php-fpm" \
    "/opt/plesk/php/*/bin/php" "/opt/plesk/php/*/sbin/php-fpm" "/www/server/php/*/bin/php" "/www/server/php/*/sbin/php-fpm" \
    "/usr/local/lsws/lsphp*/bin/lsphp" "/usr/local/php*/bin/php" /usr/local/bin/frankenphp; do
    # shellcheck disable=SC2086  # unquoted on purpose: the pattern part is a glob; the root prefix stays quoted
    for f in "$SMS_ROOT"$g; do
      base=${f##*/}
      [[ $base =~ ^(php[0-9.]*|php-fpm[0-9.]*|lsphp[0-9]*|frankenphp)$ && -f $f && -x $f && ! -L $f ]] || continue
      if [[ $base == frankenphp ]]; then v=$(run_t "$f" version 2>/dev/null | head -n1)
      else v=$(run_t "$f" -v 2>/dev/null | head -n1); fi
      v=$(sed -nE 's/.*PHP v?([0-9][^ ]*)( \(([^)]*)\))?.*/\1 \3/p' <<<"$v")
      emit INFO stack.php "${f#"$SMS_ROOT"} ${v:-version unreadable}"
      n=$((n + 1))
    done
  done
  [[ $n -eq 0 ]] && emit INFO stack.php "no host PHP binary in the standard locations"
  [[ $n -gt 0 ]] && emit INFO stack.php "for patch status and ini values run php_runtimes.sh"
}

check_docker() {
  if ! have docker; then emit INFO stack.docker "docker not installed"; return; fi
  local out id name image proj ports n=0 projects=""
  
  if ! out=$(run_t docker ps --format $'{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Label "com.docker.compose.project"}}\t{{.Ports}}' 2>/dev/null); then
    emit SKIP stack.docker "docker present but 'docker ps' failed (daemon down, or run with sudo)"; return
  fi
  while IFS=$'\t' read -r id name image proj ports; do
    [[ -z $id ]] && continue
    n=$((n + 1))
    [[ -n $proj && " $projects " != *" $proj "* ]] && projects+="$proj "
    emit INFO stack.container "$name image=$image project=${proj:--} ports=${ports:--}"
    local port
    for port in $SMS_DB_PORTS; do
      if [[ $ports =~ (0\.0\.0\.0|\[::\]|:::):$port- ]]; then
        if [[ $DOCKER_USER_FILTERS == 1 ]]; then
          emit WARN stack.public_port "container $name publishes $(port_name "$port") port $port on all interfaces (DOCKER-USER has rules; verify from outside)"
        else
          emit CRIT stack.public_port "container $name publishes $(port_name "$port") port $port on all interfaces; Docker bypasses ufw. Bind it to 127.0.0.1 or drop the ports: entry. Check from outside: nc -vz <server-ip> $port"
        fi
      fi
    done
  done <<<"$out"
  emit INFO stack.docker "docker running: $n container(s); compose projects: $([[ -n $projects ]] && printf %s "${projects% }" || printf none)"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
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
  printf '# %s: what this server is (root=%s)\n' "$SMS_NAME" "${SMS_ROOT:-/}"
  [[ $EUID -ne 0 ]] && emit INFO stack.privileges "not running as root: socket owners and firewall rules may be hidden"
  check_os
  check_init
  check_virt
  check_panels
  check_webservers
  check_php_short
  check_firewall
  check_listeners
  check_db_ports
  if [[ $SMS_DOCKER == on || ($SMS_DOCKER == auto && -z $SMS_ROOT) ]]; then check_docker; fi
  summary
  exit 0
}

[[ -n "${SMS_TEST:-}" ]] || main "$@"
