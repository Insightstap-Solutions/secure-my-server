#!/usr/bin/env bash
# php_runtimes.sh - find EVERY PHP on this server and say whether each is patched for PHP2Shell
# (CVE-2026-109618, CVE-2026-109619), plus the ini values that matter for the mitigation.
#
# READ-ONLY. It runs the PHP binaries it finds with -v / -i (or `frankenphp version`), queries
# dpkg/rpm, reads ini, pool and package changelog files, and (with --docker) runs read-only
# `docker exec` commands. It installs nothing, writes nothing and restarts nothing.
#
#   ssh host 'sudo bash -s -- --no-docker' < scripts/php_runtimes.sh
#
# Output: one finding per line, LEVEL<TAB>CHECK<TAB>DETAIL, then a SUMMARY line. Exit 0 always
# (findings are data); exit 2 for bad arguments.

SMS_NAME=php_runtimes

# --------------------------------------------------------------------------------------------
# THE FIXED-VERSION TABLE. Update it here and nowhere else.
# Source: https://www.php.net/archive/2026.php - checked 2026-10-27. Fix releases of 2026-10-21
# for CVE-2026-109618 (RCE via OOM corruption) and CVE-2026-109619 (RCE via stale global state).
SMS_FIXED_VERSIONS="8.2=8.2.35 8.3=8.3.36 8.4=8.4.27 8.5=8.5.12"
# 8.6 is in pre-release: releases before 8.6.0RC4 are affected.
SMS_PRERELEASE_BRANCH="8.6"
SMS_PRERELEASE_FIXED="8.6.0RC4"
# Branches at or below this have no official fix (end of life): vendor backports only.
SMS_EOL_MAX_BRANCH="8.1"
SMS_CVE="CVE-2026-109618"
SMS_CVE2="CVE-2026-109619"
# --------------------------------------------------------------------------------------------

SMS_ROOT=""
SMS_DOCKER="auto"
SMS_TIMEOUT=20
SMS_N_CRIT=0; SMS_N_WARN=0; SMS_N_INFO=0; SMS_N_OK=0; SMS_N_SKIP=0
declare -gA SMS_SEEN=()
SMS_FOUND=()
# Field separator for internal records: never a whitespace character, so empty fields survive `read`.
SEP=$'\037'

usage() {
  cat <<'EOF'
php_runtimes.sh [--root DIR] [--docker|--no-docker] [--timeout SEC] [--help]

Finds every PHP on this server and reports, per runtime:
  where, kind (distro/sury/remi/cpanel-ea/plesk/aapanel/lsphp/directadmin/docker/source/unknown),
  SAPI, version, owning package + package version, and a STATUS for PHP2Shell
  (CVE-2026-109618 / CVE-2026-109619):
    PATCHED         upstream version >= the fix for its branch
    PATCHED_VENDOR  distro package whose changelog mentions CVE-2026-109618
    VULNERABLE      older than the fix (or distro changelog read and it does not mention the CVE)
    VENDOR_CHECK    distro package, changelog not found/unreadable: check it as the line says
    EOL             8.1 or older, no vendor fix found
    PRERELEASE      8.6 pre-release (before 8.6.0RC4 is affected)
    UNKNOWN         version could not be read
  and the effective session.upload_progress.enabled, display_errors, expose_php, post_max_size,
  memory_limit (and fatal_error_backtraces on 8.5). FPM: `php-fpm -i` plus pool overrides
  (php_admin_value/php_admin_flag/php_value/php_flag). mod_php: its php.ini. CLI: `php -i`.

Looks in: /usr/bin/php*, /usr/sbin/php-fpm*, /usr/local/{bin,sbin}, /opt/remi, /opt/cpanel/ea-php*,
  /opt/plesk/php, /www/server/php (aaPanel), /usr/local/lsws/lsphp*, /usr/local/php* (DirectAdmin),
  /usr/local/bin/frankenphp, Apache libphp*.so/mod_php*.so, running php-fpm/lsphp/php-cgi processes,
  and (--docker, default when docker exists) every running container with PHP inside.

Options:
  --root DIR     prefix applied to every FILE path inspected (for tests / mounted images).
                 Commands (dpkg, rpm, docker, apachectl) are still looked up on PATH.
  --docker       inspect running containers (default if `docker` is on PATH and no --root)
  --no-docker    do not touch docker
  --timeout SEC  per-command timeout when `timeout` exists (default 20)
  --help         this text

READ-ONLY: runs found PHP binaries with -v/-i only, reads files, never writes, installs or restarts.
Output: LEVEL<TAB>CHECK<TAB>DETAIL lines (LEVEL = CRIT WARN INFO OK SKIP), '#' headers, SUMMARY last.
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

# Normalise a root-relative path (handles . and ..).
normpath() {
  printf '%s\n' "$1" | awk -F/ '{ n = 0
    for (i = 1; i <= NF; i++) { if ($i == "" || $i == ".") continue
      if ($i == "..") { if (n > 0) n--; continue } s[++n] = $i }
    out = ""; for (i = 1; i <= n; i++) out = out "/" s[i]; print (out == "" ? "/" : out) }'
}
# Follow symlinks of a root-relative path INSIDE the root (absolute targets are re-rooted).
resolve() {
  local p=$1 t i=0
  while [[ -L "$(rp "$p")" && $i -lt 40 ]]; do
    t=$(readlink -- "$(rp "$p")") || break
    if [[ $t == /* ]]; then p=$t; else p="${p%/*}/$t"; fi
    i=$((i + 1))
  done
  normpath "$p"
}

# ---------- versions ----------
# Upstream part of a version string: drop epoch and distro suffix, keep RC/alpha/beta/dev.
#   8.3.6-0ubuntu0.24.04.5 -> 8.3.6    8.6.0RC3 -> 8.6.0RC3    2:8.2.29-1~deb12u1 -> 8.2.29
php_upstream() {
  printf '%s\n' "$1" | sed -E 's/^[0-9]+://; s/^([0-9]+\.[0-9]+(\.[0-9]+)?(-?(alpha|beta|RC|rc|dev)[0-9]*)?).*/\1/'
}
php_branch() { php_upstream "$1" | sed -nE 's/^([0-9]+\.[0-9]+).*/\1/p'; }
php_is_prerelease() { [[ "$(php_upstream "$1")" =~ (alpha|beta|RC|rc|dev) ]]; }
# Compare two PHP versions; prints -1, 0 or 1. dev < alpha < beta < RC < final; numeric parts compared as numbers.
php_vercmp() {
  awk -v a="$(php_upstream "$1")" -v b="$(php_upstream "$2")" '
    function parse(v, r,   num, rest, k, parts) {
      match(v, /^[0-9]+(\.[0-9]+)*/); num = substr(v, 1, RLENGTH); rest = tolower(substr(v, RLENGTH + 1))
      sub(/^[-.]/, "", rest); k = split(num, parts, ".")
      r[1] = parts[1] + 0; r[2] = (k >= 2 ? parts[2] + 0 : 0); r[3] = (k >= 3 ? parts[3] + 0 : 0)
      if (rest == "") r[4] = 4
      else if (rest ~ /^dev/) r[4] = 0
      else if (rest ~ /^(alpha|a)/) r[4] = 1
      else if (rest ~ /^(beta|b)/) r[4] = 2
      else if (rest ~ /^rc/) r[4] = 3
      else r[4] = 4
      gsub(/[^0-9]/, "", rest); r[5] = rest + 0
    }
    BEGIN { parse(a, x); parse(b, y)
      for (i = 1; i <= 5; i++) { if (x[i] < y[i]) { print -1; exit } if (x[i] > y[i]) { print 1; exit } }
      print 0 }'
}
fixed_for_branch() {
  local kv
  for kv in $SMS_FIXED_VERSIONS; do [[ ${kv%%=*} == "$1" ]] && { printf '%s' "${kv#*=}"; return 0; }; done
  return 1
}
# Does the version string carry a distro-backport suffix (version string NOT meaningful)?
vendor_suffix() {
  [[ $1 == *deb.sury.org* ]] && return 1
  [[ $1 =~ (ubuntu|~deb|deb[0-9]|\+deb|\.el[0-9]|module\+el|amzn|\.fc[0-9]|\.sles|suse) ]]
}

# status KIND VERSION CHANGELOG(yes|no|unknown|n/a) -> prints STATUS<TAB>NOTE
php_status() {
  local kind=$1 ver=$2 cl=$3 up br fix c
  up=$(php_upstream "$ver"); br=$(php_branch "$ver")
  if [[ -z $br ]]; then printf 'UNKNOWN\tversion not readable'; return; fi
  if [[ $br == "$SMS_PRERELEASE_BRANCH" ]]; then
    if php_is_prerelease "$ver"; then
      if [[ $(php_vercmp "$up" "$SMS_PRERELEASE_FIXED") -lt 0 ]]; then
        printf 'PRERELEASE\tpre-release before %s: AFFECTED; never run pre-releases in production' "$SMS_PRERELEASE_FIXED"
      else
        printf 'PRERELEASE\tpre-release at/after %s (contains the fix) but not for production' "$SMS_PRERELEASE_FIXED"
      fi
    else
      printf 'PATCHED\t%s final release' "$br"
    fi
    return
  fi
  if [[ $(php_vercmp "$br" "$SMS_PRERELEASE_BRANCH") -gt 0 ]]; then
    printf 'UNKNOWN\tbranch %s is newer than the fix table in this script; check php.net' "$br"; return
  fi
  local distro=0
  [[ $kind == distro ]] && distro=1
  [[ $kind == docker ]] && vendor_suffix "$ver" && distro=1
  [[ $kind == unknown || $kind == source ]] && vendor_suffix "$ver" && distro=1
  if [[ $distro == 1 ]]; then
    if [[ $cl == yes ]]; then printf 'PATCHED_VENDOR\tvendor changelog mentions %s' "$SMS_CVE"; return; fi
    if fix=$(fixed_for_branch "$br") && [[ $(php_vercmp "$up" "$fix") -ge 0 ]]; then
      printf 'PATCHED\tupstream %s >= %s' "$up" "$fix"; return
    fi
    if [[ $cl == no ]]; then
      if [[ $(php_vercmp "$br" "$SMS_EOL_MAX_BRANCH") -le 0 ]]; then
        printf 'EOL\t%s is end of life and the vendor changelog does not mention %s' "$br" "$SMS_CVE"
      else
        printf 'VULNERABLE\tvendor changelog read; it does not mention %s (update the package, then re-check)' "$SMS_CVE"
      fi
      return
    fi
    printf 'VENDOR_CHECK\tdistro build: the version string is not meaningful; changelog not readable here. Check: apt changelog PKG | grep %s  /  rpm -q --changelog PKG | grep %s' "$SMS_CVE" "$SMS_CVE"
    return
  fi
  if [[ $(php_vercmp "$br" "$SMS_EOL_MAX_BRANCH") -le 0 ]]; then
    printf 'EOL\t%s has no official fix; use a vendor/LTS backport or upgrade to a supported branch' "$br"; return
  fi
  if ! fix=$(fixed_for_branch "$br"); then printf 'UNKNOWN\tbranch %s is not in the fix table' "$br"; return; fi
  c=$(php_vercmp "$up" "$fix")
  if [[ $c -ge 0 ]]; then printf 'PATCHED\t%s >= %s' "$up" "$fix"
  else printf 'VULNERABLE\t%s < %s (fixed release for %s)' "$up" "$fix" "$br"; fi
}
status_level() {
  case $1 in
    PATCHED | PATCHED_VENDOR) echo OK ;;
    VULNERABLE | EOL) echo CRIT ;;
    *) echo WARN ;;
  esac
}

# ---------- packages ----------
# pkg_of PATH -> "name<TAB>version" or nothing
pkg_of() {
  local p=$1 out name ver alt
  alt=""
  case $p in /lib/* | /lib64/* | /bin/* | /sbin/*) alt="/usr$p" ;; /usr/lib/* | /usr/lib64/* | /usr/bin/* | /usr/sbin/*) alt="${p#/usr}" ;; esac
  if have dpkg-query; then
    for q in "$p" $alt; do
      out=$(dpkg-query -S "$q" 2>/dev/null | grep -v '^diversion' | head -n1)
      [[ -n $out ]] && break
    done
    if [[ -n $out ]]; then
      name=${out%%:*}; name=${name%%,*}; name=${name// /}
      ver=$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null)
      printf '%s\t%s' "$name" "$ver"; return 0
    fi
  fi
  if have rpm; then
    out=$(rpm -qf --qf '%{NAME}\t%{VERSION}-%{RELEASE}\n' "$p" 2>/dev/null | head -n1)
    if [[ -n $out && $out != *"not owned"* && $out == *$'\t'* ]]; then printf '%s' "$out"; return 0; fi
  fi
  return 1
}
# changelog_state PKG BRANCH -> yes | no | unknown
changelog_state() {
  local pkg=$1 br=$2 d f out
  if have dpkg-query && [[ -n $pkg ]]; then
    for d in "$pkg" "php$br-common" "php$br-cli" "php$br-fpm" "libapache2-mod-php$br"; do
      f=$(rp "/usr/share/doc/$d/changelog.Debian.gz")
      if [[ -r $f ]]; then
        if zcat -- "$f" 2>/dev/null | grep -qE "$SMS_CVE"; then echo yes; else echo no; fi
        return
      fi
    done
  fi
  if have rpm && [[ -n $pkg ]]; then
    out=$(rpm -q --changelog "$pkg" 2>/dev/null)
    if [[ -n $out ]]; then
      if grep -qE "$SMS_CVE" <<<"$out"; then echo yes; else echo no; fi
      return
    fi
  fi
  echo unknown
}

# ---------- kinds ----------
kind_of() { # PATH PKGNAME PKGVER VERSION
  local p=$1 pn=$2 pv=$3 v=$4
  case $p in
    /www/server/php/*) echo aapanel; return ;;
    /opt/cpanel/ea-php*) echo cpanel-ea; return ;;
    /opt/plesk/php/*) echo plesk; return ;;
    /opt/remi/php*) echo remi; return ;;
    /usr/local/lsws/*) echo lsphp; return ;;
    /usr/local/php[0-9]*) echo directadmin; return ;;   # DirectAdmin CustomBuild secondary versions
  esac
  if [[ $pv == *deb.sury.org* || $v == *deb.sury.org* ]]; then echo sury; return; fi
  if [[ $pv == *remi* ]]; then echo remi; return; fi
  if [[ $pn == ea-php* ]]; then echo cpanel-ea; return; fi
  if [[ $pn == plesk-php* ]]; then echo plesk; return; fi
  if [[ $pn == lsphp* ]]; then echo lsphp; return; fi
  if [[ -n $pn ]]; then echo distro; return; fi
  case $p in /usr/local/*) echo source; return ;; esac
  echo unknown
}

# Known PHP install locations (root-relative globs). Processes outside these are never executed.
php_globs() {
  cat <<'EOF'
/usr/bin/php*
/usr/sbin/php-fpm*
/usr/local/bin/php*
/usr/local/sbin/php-fpm*
/opt/remi/php*/root/usr/bin/php*
/opt/remi/php*/root/usr/sbin/php-fpm*
/opt/cpanel/ea-php*/root/usr/bin/php*
/opt/cpanel/ea-php*/root/usr/sbin/php-fpm*
/opt/plesk/php/*/bin/php*
/opt/plesk/php/*/sbin/php-fpm*
/www/server/php/*/bin/php*
/www/server/php/*/sbin/php-fpm*
/usr/local/lsws/lsphp*/bin/lsphp
/usr/local/lsws/lsphp*/bin/php*
/usr/local/php*/bin/php*
/usr/local/php*/sbin/php-fpm*
/usr/local/bin/frankenphp
EOF
}
is_php_name() {
  [[ $1 =~ ^(php[0-9.]*|php-fpm[0-9.]*|php-cgi[0-9.]*|lsphp[0-9]*|frankenphp)$ ]]
}
in_known_location() {
  local p=$1 g
  while IFS= read -r g; do
    # shellcheck disable=SC2053  # $g is a glob pattern on purpose
    [[ $p == $g ]] && return 0
  done < <(php_globs)
  return 1
}

# ---------- ini ----------
SMS_KEYS="session.upload_progress.enabled display_errors expose_php post_max_size memory_limit"
# Value of KEY from phpinfo text (CLI text or HTML) on stdin.
info_value() {
  sed -E 's#<tr><td class="e">([^<]*)</td><td class="v">(<i>)?([^<]*)(</i>)?</td>.*#\1 => \3#' |
    awk -F' => ' -v k="$1" '{ gsub(/^[ \t]+|[ \t]+$/, "", $1) } $1 == k { v = $2; gsub(/^[ \t]+|[ \t]+$/, "", v); print v; f = 1; exit } END { if (!f) exit 1 }'
}
# Value of KEY from ini files (last one wins); prints "value<TAB>file".
ini_files_value() {
  local key=$1; shift
  local f v out=""
  for f in "$@"; do
    [[ -r $(rp "$f") ]] || continue
    v=$(awk -v k="$key" '{ line = $0; sub(/^[ \t]+/, "", line)
          if (substr(line, 1, 1) == ";" || substr(line, 1, 1) == "#") next
          i = index(line, "="); if (i == 0) next
          name = substr(line, 1, i - 1); gsub(/[ \t]+$/, "", name); if (name != k) next
          val = substr(line, i + 1); sub(/[ \t]*;.*$/, "", val); gsub(/^[ \t"]+|[ \t"]+$/, "", val); last = val; found = 1 }
        END { if (found) print last; else exit 1 }' "$(rp "$f")") && out="$v"$'\t'"$f"
  done
  [[ -n $out ]] && printf '%s' "$out"
}
php_default() {
  case $1 in
    session.upload_progress.enabled) echo On ;; display_errors) echo 1 ;; expose_php) echo On ;;
    post_max_size) echo 8M ;; memory_limit) echo 128M ;; fatal_error_backtraces) echo On ;;
  esac
}
truthy() { local v=${1,,}; [[ $v == on || $v == 1 || $v == true || $v == yes || $v == stdout || $v == stderr ]]; }
to_bytes() {
  local v=${1// /} n u
  n=${v%%[!0-9]*}; u=${v#"$n"}; [[ -z $n ]] && { echo 0; return; }
  case ${u,,} in k) echo $((n * 1024)) ;; m) echo $((n * 1024 * 1024)) ;; g) echo $((n * 1024 * 1024 * 1024)) ;; *) echo "$n" ;; esac
}
# Pool overrides of KEY. Reads FPM conf text on stdin, where each file starts with a "[@file PATH]"
# marker line. Prints one "pool SEP value SEP directive SEP file" per pool section (value empty = no override).
pool_overrides() {
  awk -v k="$1" '
    /^\[@file / { f = $0; sub(/^\[@file /, "", f); sub(/\]$/, "", f); next }
    /^[ \t]*\[[^]]+\][ \t]*$/ { s = $0; gsub(/[][ \t]/, "", s); if (s != "global") { pool = s; pf[pool] = f; order[++np] = pool } next }
    { line = $0; sub(/^[ \t]+/, "", line)
      if (pool != "" && match(line, /^php(_admin)?_(value|flag)\[[^]]+\][ \t]*=/)) {
        d = substr(line, 1, index(line, "[") - 1); n = substr(line, index(line, "[") + 1); n = substr(n, 1, index(n, "]") - 1)
        if (n == k) { v = substr(line, index(line, "=") + 1); sub(/[ \t]*;.*$/, "", v); gsub(/^[ \t"]+|[ \t"]+$/, "", v)
          val[pool] = v; dir[pool] = d } } }
    END { for (i = 1; i <= np; i++) { p = order[i]; if (seen[p]++) continue
            print p "\037" (p in val ? val[p] : "") "\037" (p in dir ? dir[p] : "") "\037" pf[p] } }'
}
# Concatenate root-relative conf files with "[@file PATH]" markers (input for pool_overrides).
conf_stream() {
  local f
  for f in "$@"; do [[ -r $(rp "$f") ]] && { printf '[@file %s]\n' "$f"; cat -- "$(rp "$f")"; printf '\n'; }; done
}
# FPM config files for a binary: php-fpm.conf files, their include= globs, plus per-kind pool dirs.
fpm_conf_files() {
  local bin=$1 kind=$2 br=$3 prefix nodot inc g f
  nodot=${br//./}
  prefix=${bin%/*}; prefix=${prefix%/*}
  local -a cands=()
  case $kind in
    distro | sury) cands+=("/etc/php/$br/fpm/php-fpm.conf" "/etc/php-fpm.conf") ;;
    remi) cands+=("/etc/opt/remi/php$nodot/php-fpm.conf") ;;
  esac
  # "$prefix/etc" covers aaPanel, Plesk, DirectAdmin and source builds; "${prefix%/usr}/etc" covers
  # cPanel EA4 (/opt/cpanel/ea-phpXY/root/etc) and similar /root/usr layouts.
  cands+=("$prefix/etc/php-fpm.conf" "${prefix%/usr}/etc/php-fpm.conf" "/usr/local/etc/php-fpm.conf")
  local -a out=()
  for f in "${cands[@]}"; do
    [[ -r $(rp "$f") ]] || continue
    out+=("$f")
    while IFS= read -r inc; do
      [[ -z $inc ]] && continue
      [[ $inc == /* ]] || inc="${f%/*}/$inc"
      inc=${inc//\$prefix/$prefix}
      # shellcheck disable=SC2086  # unquoted on purpose: the pattern part is a glob; the root prefix stays quoted
      for g in "$SMS_ROOT"$inc; do [[ -f $g ]] && out+=("${g#"$SMS_ROOT"}"); done
    done < <(sed -nE 's/^[ \t]*include[ \t]*=[ \t]*"?([^";]+)"?.*/\1/p' "$(rp "$f")")
  done
  # Pool dirs that may not be reached through include= (UNVERIFIED for Plesk/DirectAdmin layouts).
  for g in "$(rp "/etc/php/$br/fpm/pool.d")"/*.conf "$(rp /etc/php-fpm.d)"/*.conf \
    "$(rp "/etc/opt/remi/php$nodot/php-fpm.d")"/*.conf "$(rp "$prefix/etc/php-fpm.d")"/*.conf \
    "$(rp "${prefix%/usr}/etc/php-fpm.d")"/*.conf \
    "$(rp /usr/local/etc/php-fpm.d)"/*.conf; do
    [[ -f $g ]] && out+=("${g#"$SMS_ROOT"}")
  done
  [[ ${#out[@]} -gt 0 ]] && printf '%s\n' "${out[@]}" | awk '!seen[$0]++'
}
# ini files for mod_php (Debian layout, then RHEL layout). Order = PHP's own scan order.
modphp_ini_files() {
  local br=$1 g
  if [[ -r $(rp "/etc/php/$br/apache2/php.ini") ]]; then
    echo "/etc/php/$br/apache2/php.ini"
    for g in "$(rp "/etc/php/$br/apache2/conf.d")"/*.ini; do [[ -f $g ]] && echo "${g#"$SMS_ROOT"}"; done
    return
  fi
  if [[ -r $(rp /etc/php.ini) ]]; then
    echo /etc/php.ini
    for g in "$(rp /etc/php.d)"/*.ini; do [[ -f $g ]] && echo "${g#"$SMS_ROOT"}"; done
  fi
}

# report_ini LABEL SAPI STATUS BRANCH  (reads "key SEP value SEP source" lines on stdin)
report_ini() {
  local where=$1 sapi=$2 status=$3 br=$4 key val src lvl web=1
  [[ $sapi == cli ]] && web=0
  while IFS=$SEP read -r key val src; do
    case $key in
      session.upload_progress.enabled)
        if truthy "$val"; then
          if [[ $web == 0 ]]; then lvl=INFO
          elif [[ $status == PATCHED || $status == PATCHED_VENDOR ]]; then lvl=WARN
          else lvl=CRIT; fi
          emit "$lvl" php.upload_progress "$where: session.upload_progress.enabled=$val ($src). Set it to 0 in php.ini or the pool (php_admin_flag), NOT ini_set/.user.ini, and restart every worker; keep it off until the next bugfix release (23 Oct advisory, CVE-2026-115560)"
        else
          emit OK php.upload_progress "$where: session.upload_progress.enabled=$val ($src)"
        fi ;;
      display_errors)
        if truthy "$val" && [[ $web == 1 ]]; then emit WARN php.display_errors "$where: display_errors=$val ($src): errors are shown to visitors"
        else emit INFO php.display_errors "$where: display_errors=$val ($src)"; fi ;;
      expose_php)
        if truthy "$val" && [[ $web == 1 ]]; then emit INFO php.expose_php "$where: expose_php=$val ($src): X-Powered-By reveals the PHP version"
        else emit INFO php.expose_php "$where: expose_php=$val ($src)"; fi ;;
      post_max_size)
        if [[ $web == 1 && $(to_bytes "$val") -gt $((64 * 1024 * 1024)) ]]; then
          emit INFO php.post_max_size "$where: post_max_size=$val ($src): large; a low limit reduces exposure until patched"
        else emit INFO php.post_max_size "$where: post_max_size=$val ($src)"; fi ;;
      memory_limit) emit INFO php.memory_limit "$where: memory_limit=$val ($src)" ;;
      fatal_error_backtraces)
        if truthy "$val" && [[ $web == 1 && $status != PATCHED && $status != PATCHED_VENDOR ]]; then
          emit WARN php.fatal_error_backtraces "$where: fatal_error_backtraces=$val ($src): set to 0 until patched"
        else emit INFO php.fatal_error_backtraces "$where: fatal_error_backtraces=$val ($src)"; fi ;;
    esac
  done
}
keys_for_branch() { if [[ $1 == 8.5 ]]; then echo "$SMS_KEYS fatal_error_backtraces"; else echo "$SMS_KEYS"; fi; }

# Effective ini values for an FPM runtime: `<fpm> -i` (it loads the FPM ini dir) + pool overrides.
# For on/off keys the WORST pool decides (any pool left enabled counts as enabled).
fpm_values() { # INFO_TEXT BRANCH CONF_STREAM
  local info=$1 br=$2 confs=$3 key base pool pv pd pf vals eff any_on all_off
  for key in $(keys_for_branch "$br"); do
    base=$(info_value "$key" <<<"$info") || base="$(php_default "$key")"
    vals=""; any_on=0; all_off=1
    while IFS=$SEP read -r pool pv pd pf; do
      [[ -z $pool ]] && continue
      if [[ -n $pv ]]; then vals+="${vals:+, }$pool=$pv($pd in $pf)"; else vals+="${vals:+, }$pool=$base(ini)"; fi
      if truthy "${pv:-$base}"; then any_on=1; all_off=0; fi
    done < <(pool_overrides "$key" <<<"$confs")
    if [[ -z $vals ]]; then
      printf '%s\037%s\037%s\n' "$key" "$base" "php-fpm -i; no pool config found"
      continue
    fi
    eff=$base
    case $key in
      session.upload_progress.enabled | display_errors | expose_php | fatal_error_backtraces)
        if [[ $any_on == 1 ]]; then eff=On; elif [[ $all_off == 1 ]]; then eff=Off; fi ;;
    esac
    printf '%s\037%s\037%s\n' "$key" "$eff" "php-fpm -i ini=$base; pools: $vals"
  done
}
info_values() { # INFO_TEXT BR LABEL
  local info=$1 br=$2 label=$3 key v
  for key in $(keys_for_branch "$br"); do
    if v=$(info_value "$key" <<<"$info"); then printf '%s\037%s\037%s\n' "$key" "$v" "$label"
    else printf '%s\037%s\037%s\n' "$key" "$(php_default "$key")" "$label; not shown, PHP default"; fi
  done
}
file_values() { # BR FILES...
  local br=$1; shift
  local key r
  for key in $(keys_for_branch "$br"); do
    if r=$(ini_files_value "$key" "$@"); then printf '%s\037%s\037%s\n' "$key" "${r%%$'\t'*}" "ini ${r#*$'\t'}"
    else printf '%s\037%s\037%s\n' "$key" "$(php_default "$key")" "PHP default, not set in ini"; fi
  done
}

# ---------- host runtimes ----------
version_line() { # ABS_PATH BASENAME
  if [[ $2 == frankenphp ]]; then
    # UNVERIFIED: `frankenphp version` prints "FrankenPHP vX PHP 8.x.y Caddy vZ".
    run_t "$1" version 2>/dev/null | head -n1
  else
    run_t "$1" -v 2>/dev/null | head -n1
  fi
}
parse_version() { sed -nE 's/.*PHP[ /]v?([0-9]+\.[0-9]+[^ )]*).*/\1/p' <<<"$1" | head -n1; }
parse_sapi() {
  local s
  s=$(sed -nE 's/^PHP [^ ]+ \(([^)]+)\).*/\1/p' <<<"$1" | head -n1)
  case $s in fpm-fcgi) echo fpm ;; cgi-fcgi) echo cgi ;; litespeed) echo litespeed ;; cli) echo cli ;; "") echo "?" ;; *) echo "$s" ;; esac
}

report_host_runtime() { # ROOT_RELATIVE_PATH
  local p=$1 abs base vline ver sapi pkg pn="" pv="" kind br cl st note lvl info files
  abs=$(rp "$p"); base=${p##*/}
  vline=$(version_line "$abs" "$base")
  ver=$(parse_version "$vline"); sapi=$(parse_sapi "$vline")
  [[ $base == frankenphp ]] && sapi=frankenphp
  if pkg=$(pkg_of "$p"); then pn=${pkg%%$'\t'*}; pv=${pkg#*$'\t'}; fi
  kind=$(kind_of "$p" "$pn" "$pv" "$ver")
  br=$(php_branch "${ver:-x}")
  cl=n/a
  if [[ $kind == distro ]]; then cl=$(changelog_state "$pn" "$br"); fi
  [[ -z $ver && -n $pv && $kind == distro ]] && ver=$pv
  IFS=$'\t' read -r st note < <(php_status "$kind" "${ver:-unknown}" "$cl")
  lvl=$(status_level "$st")
  emit "$lvl" php.runtime "where=$p kind=$kind sapi=$sapi version=${ver:-?} pkg=${pn:--}${pv:+ $pv} status=$st ($note)"
  [[ -z $ver ]] && return
  case $sapi in
    fpm)
      info=$(run_t "$abs" -i 2>/dev/null)
      mapfile -t files < <(fpm_conf_files "$p" "$kind" "$br")
      report_ini "$p (fpm)" fpm "$st" "$br" < <(fpm_values "$info" "$br" "$(conf_stream ${files[@]+"${files[@]}"})") ;;
    cli | litespeed | cgi)
      # UNVERIFIED for lsphp: assumed to accept -i like php-cgi (php-cgi -i prints HTML; info_value reads both).
      info=$(run_t "$abs" -i 2>/dev/null)
      report_ini "$p ($sapi)" "$sapi" "$st" "$br" < <(info_values "$info" "$br" "$base -i ($sapi)") ;;
    frankenphp)
      emit INFO php.ini "$p: FrankenPHP: read ini values with a phpinfo() page or the Caddyfile php_ini directives" ;;
  esac
}
# Fills SMS_FOUND (and SMS_SEEN) in THIS shell: never call it inside $( ) or a pipe.
discover_host() {
  local g f r base
  while IFS= read -r g; do
    # shellcheck disable=SC2086  # unquoted on purpose: the pattern part is a glob; the root prefix stays quoted
    for f in "$SMS_ROOT"$g; do
      [[ -f $f && -x $f ]] || continue
      base=${f##*/}
      is_php_name "$base" || continue
      r=$(resolve "${f#"$SMS_ROOT"}")
      [[ -n ${SMS_SEEN[$r]+x} ]] && continue
      SMS_SEEN[$r]=1
      SMS_FOUND+=("$r")
    done
  done < <(php_globs)
}

check_processes() {
  local d pid exe comm r deleted base
  for d in "$(rp /proc)"/[0-9]*; do
    [[ -d $d ]] || continue
    pid=${d##*/}
    comm=$(cat "$d/comm" 2>/dev/null)
    exe=$(readlink "$d/exe" 2>/dev/null) || exe=""
    base=${exe##*/}; base=${base% (deleted)}
    [[ $comm =~ ^(php|lsphp|frankenphp) || $base =~ ^(php|lsphp|frankenphp) ]] || continue
    [[ -z $exe ]] && { emit SKIP php.process "pid $pid ($comm): cannot read /proc/$pid/exe (run as root)"; continue; }
    deleted=0
    if [[ $exe == *" (deleted)" ]]; then deleted=1; exe=${exe% (deleted)}; fi
    if [[ $deleted == 1 ]]; then
      emit WARN php.process "pid $pid ($comm) runs $exe which was REPLACED on disk: the package was updated but this process still runs the old binary. Restart the service."
    fi
    if ! in_known_location "$exe"; then
      emit WARN php.process "pid $pid ($comm) runs PHP-like binary from an unexpected location $exe: not executed; investigate"
      continue
    fi
    r=$(resolve "$exe")
    if [[ -z ${SMS_SEEN[$r]+x} && -x $(rp "$r") ]]; then
      SMS_SEEN[$r]=1
      emit INFO php.process "pid $pid ($comm) runs $r (not found by path scan; reported below)"
      report_host_runtime "$r"
    fi
  done
}

apache_loaded_modules() {
  local mout=""
  if have apachectl; then mout=$(run_t apachectl -M 2>/dev/null)
  elif have apache2ctl; then mout=$(run_t apache2ctl -M 2>/dev/null)
  elif have httpd; then mout=$(run_t httpd -M 2>/dev/null); fi
  printf '%s' "$mout"
}
check_modphp() {
  local g f p base pkg pn pv kind ver br cl st note lvl loaded mods conf hint
  local -a found=()
  for g in /usr/lib/apache2/modules /usr/lib64/httpd/modules /usr/lib/httpd/modules /etc/httpd/modules \
    /usr/local/apache/modules /usr/local/apache2/modules /etc/apache2/modules /www/server/apache/modules; do
    # UNVERIFIED: /etc/apache2/modules (cPanel EA4) and /www/server/apache/modules (aaPanel Apache).
    for f in "$(rp "$g")"/libphp*.so "$(rp "$g")"/mod_php*.so; do [[ -f $f ]] && found+=("${f#"$SMS_ROOT"}"); done
  done
  [[ ${#found[@]} -eq 0 ]] && return
  mods=$(apache_loaded_modules)
  for p in "${found[@]}"; do
    p=$(resolve "$p"); [[ -n ${SMS_SEEN[$p]+x} ]] && continue; SMS_SEEN[$p]=1
    base=${p##*/}
    loaded="unknown (no apachectl/httpd; check LoadModule)"
    if [[ -n $mods ]]; then
      if grep -qE 'php[0-9_]*_module' <<<"$mods"; then loaded="yes (a php module is loaded)"; else loaded=no; fi
    else
      for conf in "$(rp /etc/apache2/mods-enabled)"/*.load "$(rp /etc/httpd/conf.modules.d)"/*.conf \
        "$(rp /etc/httpd/conf/httpd.conf)" "$(rp /usr/local/apache/conf/httpd.conf)" \
        "$(rp /etc/apache2/conf.modules.d)"/*.conf "$(rp /www/server/apache/conf/httpd.conf)"; do
        [[ -f $conf ]] || continue
        if grep -qE "^[[:space:]]*LoadModule[[:space:]]+php[^[:space:]]*[[:space:]]+[^[:space:]]*$base" "$conf"; then
          loaded="yes (LoadModule in ${conf#"$SMS_ROOT"})"; break
        fi
      done
    fi
    pn=""; pv=""
    if pkg=$(pkg_of "$p"); then pn=${pkg%%$'\t'*}; pv=${pkg#*$'\t'}; fi
    ver=$(php_upstream "$pv")
    hint=$(sed -nE 's/^(libphp|mod_php)([0-9]+(\.[0-9]+)?)\.so$/\2/p' <<<"$base")
    kind=$(kind_of "$p" "$pn" "$pv" "$pv")
    br=$(php_branch "${ver:-x}")
    cl=n/a; [[ $kind == distro ]] && cl=$(changelog_state "$pn" "$br")
    IFS=$'\t' read -r st note < <(php_status "$kind" "${pv:-unknown}" "$cl")
    [[ -z $pv ]] && note="version unknown (module not packaged; branch hint ${hint:-none}); check phpinfo() through Apache"
    lvl=$(status_level "$st")
    emit "$lvl" php.runtime "where=$p kind=$kind sapi=apache2handler (mod_php: highest risk) loaded=$loaded version=${ver:-?} pkg=${pn:--}${pv:+ $pv} status=$st ($note)"
    if [[ -n $br ]]; then
      local -a inis=()
      mapfile -t inis < <(modphp_ini_files "$br")
      if [[ ${#inis[@]} -gt 0 ]]; then
        report_ini "$p (mod_php)" apache2handler "$st" "$br" < <(file_values "$br" "${inis[@]}")
      else
        emit SKIP php.ini "$p: mod_php php.ini not found in the Debian/RHEL locations; check phpinfo() through Apache"
      fi
    fi
  done
}

# ---------- docker ----------
check_docker() {
  local id name image bins b vline ver sapi st note lvl cl info confs
  if ! have docker; then emit SKIP php.docker "docker not on PATH"; return; fi
  local ps
  if ! ps=$(run_t docker ps --format $'{{.ID}}\t{{.Names}}\t{{.Image}}' 2>/dev/null); then
    emit SKIP php.docker "docker ps failed (daemon down or no permission: run with sudo)"; return
  fi
  [[ -z $ps ]] && { emit INFO php.docker "no running containers"; return; }
  while IFS=$'\t' read -r id name image; do
    [[ -z $id ]] && continue
    # shellcheck disable=SC2016  # this snippet runs inside the container's own shell
    bins=$(run_t docker exec "$id" sh -c 'for b in php-fpm php frankenphp lsphp; do command -v "$b"; done; ls /usr/sbin/php-fpm[0-9]* 2>/dev/null' </dev/null 2>/dev/null | awk '!seen[$0]++')
    [[ -z $bins ]] && continue
    while IFS= read -r b; do
      [[ -z $b ]] && continue
      if [[ ${b##*/} == frankenphp ]]; then
        vline=$(run_t docker exec "$id" "$b" version </dev/null 2>/dev/null | head -n1)
      else
        vline=$(run_t docker exec "$id" "$b" -v </dev/null 2>/dev/null | head -n1)
      fi
      ver=$(parse_version "$vline"); sapi=$(parse_sapi "$vline")
      [[ ${b##*/} == frankenphp ]] && sapi=frankenphp
      cl=n/a
      if vendor_suffix "${ver:-x}"; then
        # shellcheck disable=SC2016  # this snippet runs inside the container's own shell
        cl=$(run_t docker exec "$id" sh -c 'for f in /usr/share/doc/php*-common/changelog.Debian.gz; do [ -r "$f" ] && zcat "$f"; done 2>/dev/null | grep -c '"$SMS_CVE"'' </dev/null 2>/dev/null)
        if [[ -z $cl ]]; then cl=unknown; elif [[ $cl -gt 0 ]]; then cl=yes; else cl=no; fi
      fi
      IFS=$'\t' read -r st note < <(php_status docker "${ver:-unknown}" "$cl")
      lvl=$(status_level "$st")
      emit "$lvl" php.runtime "where=docker:$name:$b image=$image kind=docker sapi=$sapi version=${ver:-?} status=$st ($note)"
      [[ -z $ver ]] && continue
      local br; br=$(php_branch "$ver")
      if [[ $sapi == fpm ]]; then
        info=$(run_t docker exec "$id" "$b" -i </dev/null 2>/dev/null)
        # Pool files are read inside the container; only the five directives are extracted below.
        # shellcheck disable=SC2016  # this snippet runs inside the container's own shell
        confs=$(run_t docker exec "$id" sh -c 'for f in /usr/local/etc/php-fpm.conf /usr/local/etc/php-fpm.d/*.conf /etc/php/*/fpm/pool.d/*.conf /etc/php*/php-fpm.d/*.conf /etc/php-fpm.d/*.conf; do [ -r "$f" ] && { echo "[@file $f]"; cat "$f"; echo; }; done' </dev/null 2>/dev/null)
        report_ini "docker:$name:$b (fpm)" fpm "$st" "$br" < <(fpm_values "$info" "$br" "$confs")
      elif [[ $sapi == cli ]]; then
        info=$(run_t docker exec "$id" "$b" -i </dev/null 2>/dev/null)
        report_ini "docker:$name:$b (cli)" cli "$st" "$br" < <(info_values "$info" "$br" "php -i (cli)")
      fi
    done <<<"$bins"
  done <<<"$ps"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --root) [[ $# -ge 2 ]] || { echo "--root needs a directory" >&2; return 2; }; SMS_ROOT=${2%/}; shift 2 ;;
      --docker) SMS_DOCKER=on; shift ;;
      --no-docker) SMS_DOCKER=off; shift ;;
      --timeout) [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "--timeout needs seconds" >&2; return 2; }; SMS_TIMEOUT=$2; shift 2 ;;
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
  printf '# %s: every PHP on this host and its PHP2Shell status (%s, %s)\n' "$SMS_NAME" "$SMS_CVE" "$SMS_CVE2"
  printf '# fixed releases: %s (2026-10-21). <= %s: EOL. %s: pre-releases before %s affected\n' \
    "$SMS_FIXED_VERSIONS" "$SMS_EOL_MAX_BRANCH" "$SMS_PRERELEASE_BRANCH" "$SMS_PRERELEASE_FIXED"
  printf '# root=%s docker=%s\n' "${SMS_ROOT:-/}" "$SMS_DOCKER"
  [[ $EUID -ne 0 ]] && emit INFO php.privileges "not running as root: some files, pools and /proc entries may be unreadable"
  local p n=0
  discover_host
  for p in ${SMS_FOUND[@]+"${SMS_FOUND[@]}"}; do
    n=$((n + 1)); report_host_runtime "$p"
  done
  check_processes
  check_modphp
  [[ $n -eq 0 ]] && emit INFO php.runtime "no PHP binary in the standard host locations"
  if [[ $SMS_DOCKER == on || ($SMS_DOCKER == auto && -z $SMS_ROOT) ]] && { [[ $SMS_DOCKER == on ]] || have docker; }; then
    check_docker
  fi
  summary
  exit 0
}

[[ -n "${SMS_TEST:-}" ]] || main "$@"
