#!/usr/bin/env bash
# php2shell_ioc_scan.sh - look through web server, PHP-FPM and container logs for signs of the
# PHP2Shell exploit (CVE-2026-109618 / CVE-2026-109619) since a date.
#
# READ-ONLY. Reads log files (plain, .1, .gz via zcat) and `docker logs`. Prints counts, first/last
# time, top client IPs and a few SANITISED sample lines (query strings removed, 300 chars max).
#
#   ssh host 'sudo bash -s -- --since 2026-10-15' < scripts/php2shell_ioc_scan.sh
#
# Output: LEVEL<TAB>CHECK<TAB>DETAIL lines, then SUMMARY. Exit 0 always; 2 on bad arguments.

SMS_NAME=php2shell_ioc_scan
SMS_ROOT=""
SMS_SINCE="2026-10-15"
SMS_SAMPLES=3
SMS_DOCKER="auto"
SMS_TIMEOUT=60
SMS_N_CRIT=0; SMS_N_WARN=0; SMS_N_INFO=0; SMS_N_OK=0; SMS_N_SKIP=0
SMS_EXTRA=()
SMS_FILES=()

usage() {
  cat <<'EOF'
php2shell_ioc_scan.sh [--since YYYY-MM-DD] [--samples N] [--root DIR] [--docker|--no-docker] [PATH...]

Scans logs for PHP2Shell indicators since a date (default 2026-10-15):
  fpm_child_crash      FPM "child N exited on signal 11 (SIGSEGV)" or signal 6 (SIGABRT)
  mem_exhausted_unknown  "Allowed memory size of N bytes exhausted ... in Unknown on line 0"
  multipart_no_boundary  JSON access logs (Caddy/Traefik) with multipart/form-data and no non-empty boundary=
  post_big_error       POST answered 502/499/400 with request size >= 1 MB (only where the log records request size)
  post_502_499         POST answered 502/499 in a common/combined access log (size not recorded; weak signal)
  upstream_reset       nginx "upstream prematurely closed" / "recv() failed (104"
Per indicator: count, first/last timestamp, top 10 client IPs, and up to --samples N sample lines.

Logs searched (plus any PATH given, file or directory): /var/log/nginx /var/log/apache2 /var/log/httpd
  /www/wwwlogs /usr/local/apache/domlogs /etc/apache2/logs/domlogs /var/www/vhosts/*/logs
  /usr/local/lsws/logs /var/log/php*fpm*.log /var/log/php-fpm /www/server/php/*/var/log
  /opt/cpanel/ea-php*/root/usr/var/log/php-fpm /opt/remi/php*/root/var/log/php-fpm
  and with --docker (default when docker is on PATH and no --root): `docker logs --since` of running
  containers whose name or image mentions php, fpm, nginx, caddy, httpd, apache or traefik.
Files last modified before --since (00:00 UTC) are skipped (a log not written since then cannot hold newer lines).

LIMITS: common/combined access logs do NOT record Content-Type or request size, so the strongest
signal (multipart without boundary, MB-sized POST) is invisible in them: "no hits" does NOT mean
"not attacked". Timestamps are compared by calendar day, ignoring time zones.

Options:
  --since DATE   YYYY-MM-DD (default 2026-10-15)
  --samples N    sample lines per indicator (default 3, 0 = none)
  --root DIR     prefix for every FILE path inspected (tests / mounted images)
  --docker / --no-docker
  --help         this text

READ-ONLY: reads logs only, never prints query strings, cookies or request bodies.
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

log_dirs() {
  cat <<'EOF'
/var/log/nginx
/var/log/apache2
/var/log/httpd
/www/wwwlogs
/usr/local/apache/domlogs
/etc/apache2/logs/domlogs
/var/www/vhosts/*/logs
/usr/local/lsws/logs
/var/log/php-fpm
/www/server/php/*/var/log
/opt/cpanel/ea-php*/root/usr/var/log/php-fpm
/opt/remi/php*/root/var/log/php-fpm
EOF
}

# Fills SMS_FILES (root-relative) with log files modified on/after --since. Runs in THIS shell.
find_logs() {
  local g d f
  local -A seen=()
  local -a dirs=() files=()
  while IFS= read -r g; do
    # shellcheck disable=SC2086  # unquoted on purpose: the pattern part is a glob; the root prefix stays quoted
    for d in "$SMS_ROOT"$g; do [[ -d $d ]] && dirs+=("$d"); done
  done < <(log_dirs)
  for f in "$(rp /var/log)"/php*fpm*.log*; do [[ -f $f ]] && files+=("$f"); done
  for f in ${SMS_EXTRA[@]+"${SMS_EXTRA[@]}"}; do
    f=$(rp "$f")
    if [[ -d $f ]]; then dirs+=("$f"); elif [[ -f $f ]]; then files+=("$f"); else emit SKIP ioc.input "${f#"$SMS_ROOT"}: not found"; fi
  done
  if [[ ${#dirs[@]} -gt 0 ]]; then
    while IFS= read -r -d '' f; do files+=("$f"); done < <(find "${dirs[@]}" -maxdepth 3 -type f -print0 2>/dev/null)
  fi
  local since_epoch mt
  since_epoch=$(ymd_epoch "$SMS_SINCE")
  for f in ${files[@]+"${files[@]}"}; do
    [[ -n ${seen[$f]+x} ]] && continue
    seen[$f]=1
    # a log not written since --since cannot hold newer lines (stat, not find -newermt: busybox lacks it)
    mt=$(stat -c %Y -- "$f" 2>/dev/null) || continue
    [[ $mt -ge $since_epoch ]] || continue
    SMS_FILES+=("${f#"$SMS_ROOT"}")
  done
}

# Stream every log with a marker line before each file, so ONE awk pass can scan and aggregate.
stream_logs() {
  local f
  for f in ${SMS_FILES[@]+"${SMS_FILES[@]}"}; do
    printf '\001SMSFILE\t%s\n' "$f"
    case $f in
      *.gz) zcat -- "$(rp "$f")" 2>/dev/null ;;
      *) cat -- "$(rp "$f")" 2>/dev/null ;;
    esac
  done
  if [[ $SMS_USE_DOCKER == 1 ]]; then
    local id name image
    while IFS=$'\t' read -r id name image; do
      [[ -z $id ]] && continue
      [[ "$name $image" =~ (php|fpm|nginx|caddy|httpd|apache|traefik) ]] || continue
      printf '\001SMSFILE\tdocker:%s\n' "$name"
      run_t docker logs --timestamps --since "$SMS_SINCE" "$id" 2>&1 </dev/null
    done < <(run_t docker ps --format $'{{.ID}}\t{{.Names}}\t{{.Image}}' 2>/dev/null)
  fi
}

# Cheap first pass so awk only sees candidate lines (and the file markers).
prefilter() {
  grep -aE $'^\001SMSFILE|exited on signal|Allowed memory size|upstream prematurely closed|recv\\(\\) failed \\(104|multipart/form-data|POST'
}

# The scanner. Prints finished LEVEL<TAB>CHECK<TAB>DETAIL lines (counts, times, IPs, samples).
# Timestamps understood: [27/Oct/2026:10:00:00 (nginx/apache access), 2026/10/27 10:00:00 (nginx error),
# [27-Oct-2026 10:00:00 (FPM/PHP), 2026-10-27T10:00:00 (ISO, JSON, docker --timestamps), "ts":1792.. (Caddy epoch).
scan_awk() {
  awk -v since="${SMS_SINCE//-/}000000" -v nsamp="$SMS_SAMPLES" '
  function civil(z,   era, doe, yoe, y, doy, mp, d, m) {   # days since epoch -> YYYYMMDD
    z += 719468; era = int((z >= 0 ? z : z - 146096) / 146097); doe = z - era * 146097
    yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
    y = yoe + era * 400; doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100)); mp = int((5 * doy + 2) / 153)
    d = doy - int((153 * mp + 2) / 5) + 1; m = mp + (mp < 10 ? 3 : -9); if (m <= 2) y++
    return sprintf("%04d%02d%02d", y, m, d)
  }
  function stamp(l,   t, s, e) {   # -> YYYYMMDDhhmmss or ""
    if (match(l, /[0-9][0-9]\/[A-Z][a-z][a-z]\/[0-9][0-9][0-9][0-9]:[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
      t = substr(l, RSTART, RLENGTH); return substr(t, 8, 4) mon[substr(t, 4, 3)] substr(t, 1, 2) substr(t, 13, 2) substr(t, 16, 2) substr(t, 19, 2) }
    if (match(l, /[0-9][0-9]-[A-Z][a-z][a-z]-[0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
      t = substr(l, RSTART, RLENGTH); return substr(t, 8, 4) mon[substr(t, 4, 3)] substr(t, 1, 2) substr(t, 13, 2) substr(t, 16, 2) substr(t, 19, 2) }
    if (match(l, /[0-9][0-9][0-9][0-9][-\/][0-9][0-9][-\/][0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
      t = substr(l, RSTART, RLENGTH); return substr(t, 1, 4) substr(t, 6, 2) substr(t, 9, 2) substr(t, 12, 2) substr(t, 15, 2) substr(t, 18, 2) }
    if (match(l, /"ts":[ ]*[0-9]+/)) {
      t = substr(l, RSTART, RLENGTH); sub(/"ts":[ ]*/, "", t); s = t + 0; e = int(s / 86400)
      return civil(e) sprintf("%02d%02d%02d", int((s % 86400) / 3600), int((s % 3600) / 60), s % 60) }
    return ""
  }
  function fmt(t) { return (t == "" ? "?" : substr(t, 1, 4) "-" substr(t, 5, 2) "-" substr(t, 7, 2) " " substr(t, 9, 2) ":" substr(t, 11, 2) ":" substr(t, 13, 2)) }
  function jfield(l, k,   r) {   # first string or number value of JSON key k
    if (match(l, "\"" k "\":[ ]*\"[^\"]*\"")) { r = substr(l, RSTART, RLENGTH); sub(/^"[^"]*":[ ]*"/, "", r); sub(/"$/, "", r); return r }
    if (match(l, "\"" k "\":[ ]*[0-9]+")) { r = substr(l, RSTART, RLENGTH); sub(/^"[^"]*":[ ]*/, "", r); return r }
    return ""
  }
  function client(l,   r) {
    if (substr(l, 1, 1) == "{") {
      r = jfield(l, "remote_ip"); if (r == "") r = jfield(l, "client_ip"); if (r == "") r = jfield(l, "ClientHost")
      if (r == "") r = jfield(l, "remote_addr"); if (r == "") r = jfield(l, "ClientAddr"); sub(/:[0-9]+$/, "", r); return r }
    if (match(l, /client: [0-9a-fA-F.:]+/)) return substr(l, RSTART + 8, RLENGTH - 8)
    if (match(l, /^[0-9][0-9.]*[0-9] /) || match(l, /^[0-9a-fA-F]*:[0-9a-fA-F:]+ /)) return substr(l, 1, RLENGTH - 1)
    if (match(l, /^[^ ]+ [0-9][0-9.]*[0-9] /)) { r = substr(l, 1, RLENGTH - 1); sub(/^[^ ]+ /, "", r); return r }   # vhost-prefixed
    return ""
  }
  function sanitize(l,   s, m, u, st, sz, ts) {
    if (substr(l, 1, 1) == "{") {   # never echo a JSON log line: it can carry Cookie/Authorization headers
      m = jfield(l, "method"); if (m == "") m = jfield(l, "RequestMethod")
      u = jfield(l, "uri"); if (u == "") u = jfield(l, "RequestPath")
      st = jfield(l, "status"); if (st == "") st = jfield(l, "DownstreamStatus")
      sz = reqsize(l); ts = stamp(l)
      s = "json: time=" fmt(ts) " ip=" client(l) " " m " " u " status=" st " request_bytes=" (sz < 0 ? "?" : sz)
    } else s = l
    gsub(/\?[^ "]*/, "", s)
    gsub(/([Cc]ookie|[Aa]uthorization|[Pp]assword|[Tt]oken|[Ss]ecret|[Kk]ey)[=:][^ ";,]*/, "[redacted]", s)
    gsub(/[[:cntrl:]]/, " ", s)
    return substr(s, 1, 300)
  }
  function reqsize(l,   r) {   # request size from JSON / key=value formats, -1 when not recorded
    r = jfield(l, "RequestContentSize"); if (r != "") return r + 0
    r = jfield(l, "request_length"); if (r != "") return r + 0
    if (match(l, /"Content-Length":[ ]*\[[ ]*"[0-9]+"/)) { r = substr(l, RSTART, RLENGTH); gsub(/[^0-9]/, "", r); return r + 0 }
    if (match(l, /(^| )request_length=[0-9]+/)) { r = substr(l, RSTART, RLENGTH); sub(/.*=/, "", r); return r + 0 }
    return -1
  }
  function has_boundary(l,   i, c) {   # a NON-EMPTY boundary= value is present
    while ((i = index(l, "boundary=")) > 0) {
      c = substr(l, i + 9, 1); if (c != "" && index("\"\\;, ]", c) == 0) return 1
      l = substr(l, i + 9) }
    return 0
  }
  function hit(ind, l, ts,   ip) {
    cnt[ind]++
    if (ts != "") { if (!(ind in first) || ts < first[ind]) first[ind] = ts; if (ts > last[ind]) last[ind] = ts } else undated[ind]++
    ip = client(l); if (ip != "") { ips[ind, ip]++; if (ipsn[ind, ip] == 0) { ipsn[ind, ip] = 1; iplist[ind] = iplist[ind] " " ip } }
    if (ns[ind] < nsamp) { ns[ind]++; samp[ind, ns[ind]] = src ": " sanitize(l) }
    srcs[ind, src] = 1
  }
  BEGIN { split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", mn, " "); for (i = 1; i <= 12; i++) mon[mn[i]] = sprintf("%02d", i)
          n = split("fpm_child_crash mem_exhausted_unknown multipart_no_boundary post_big_error post_502_499 upstream_reset", order, " ") }
  index($0, "\001SMSFILE\t") == 1 { src = substr($0, 10); files++; next }
  {
    l = $0; ts = stamp(l)
    if (ts != "" && ts < since) next
    if (l ~ /exited on signal (11|6)([^0-9]|$)/ || l ~ /exited on signal SIG(SEGV|ABRT)/) hit("fpm_child_crash", l, ts)
    if (l ~ /Allowed memory size of [0-9]+ bytes exhausted/ && l ~ /in Unknown on line 0/) hit("mem_exhausted_unknown", l, ts)
    if (l ~ /upstream prematurely closed/ || l ~ /recv\(\) failed \(104/) hit("upstream_reset", l, ts)
    if (substr(l, 1, 1) == "{") {
      if (index(l, "multipart/form-data") && !has_boundary(l)) hit("multipart_no_boundary", l, ts)
      m = jfield(l, "method"); if (m == "") m = jfield(l, "RequestMethod")
      st = jfield(l, "status"); if (st == "") st = jfield(l, "DownstreamStatus")
      if (m == "POST" && (st == "502" || st == "499" || st == "400") && reqsize(l) >= 1048576) hit("post_big_error", l, ts)
    } else if (l ~ /"POST [^"]*" (502|499|400) /) {
      sz = reqsize(l)
      if (sz >= 1048576) hit("post_big_error", l, ts)
      else if (sz < 0 && l ~ /"POST [^"]*" (502|499) /) hit("post_502_499", l, ts)
    }
  }
  END {
    level["fpm_child_crash"] = "WARN"; level["mem_exhausted_unknown"] = "CRIT"; level["multipart_no_boundary"] = "CRIT"
    level["post_big_error"] = "CRIT"; level["post_502_499"] = "INFO"; level["upstream_reset"] = "INFO"
    for (i = 1; i <= n; i++) {
      ind = order[i]
      if (!(ind in cnt)) { print "OK\tioc." ind "\t0 hits"; continue }
      top = ""; m = split(substr(iplist[ind], 2), cand, " ")
      for (k = 1; k <= 10 && k <= m; k++) {   # selection of the 10 busiest IPs (no asort in mawk)
        best = ""; bc = -1
        for (j = 1; j <= m; j++) if (!(cand[j] in used) && ips[ind, cand[j]] > bc) { best = cand[j]; bc = ips[ind, cand[j]] }
        if (best == "") break
        used[best] = 1; top = top (top == "" ? "" : ", ") best "(" bc ")"
      }
      for (j = 1; j <= m; j++) delete used[cand[j]]
      nsrc = 0; for (key in srcs) { split(key, kk, SUBSEP); if (kk[1] == ind) nsrc++ }
      printf "%s\tioc.%s\tcount=%d first=%s last=%s undated=%d sources=%d top_ips=%s\n", level[ind], ind, cnt[ind], fmt(first[ind]), fmt(last[ind]), undated[ind] + 0, nsrc, (top == "" ? "-" : top)
      for (k = 1; k <= ns[ind]; k++) printf "INFO\tioc.%s.sample\t%s\n", ind, samp[ind, k]
    }
    printf "INFO\tioc.scanned\t%d log source(s) read\n", files + 0
  }'
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --since)
        valid_ymd "${2:-}" || { echo "--since needs a date YYYY-MM-DD" >&2; return 2; }
        SMS_SINCE=$2; shift 2 ;;
      --samples) [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "--samples needs a number" >&2; return 2; }; SMS_SAMPLES=$2; shift 2 ;;
      --root) [[ $# -ge 2 ]] || { echo "--root needs a directory" >&2; return 2; }; SMS_ROOT=${2%/}; shift 2 ;;
      --docker) SMS_DOCKER=on; shift ;;
      --no-docker) SMS_DOCKER=off; shift ;;
      -h | --help) usage; exit 0 ;;
      --) shift; SMS_EXTRA+=("$@"); break ;;
      -*) echo "unknown argument: $1 (see --help)" >&2; return 2 ;;
      *) SMS_EXTRA+=("$1"); shift ;;
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
  SMS_USE_DOCKER=0
  if [[ $SMS_DOCKER == on || ($SMS_DOCKER == auto && -z $SMS_ROOT) ]]; then
    if have docker; then SMS_USE_DOCKER=1; elif [[ $SMS_DOCKER == on ]]; then emit SKIP ioc.docker "docker not on PATH"; fi
  fi
  printf '# %s: PHP2Shell indicators since %s (root=%s)\n' "$SMS_NAME" "$SMS_SINCE" "${SMS_ROOT:-/}"
  printf '# LIMIT: common/combined access logs record neither Content-Type nor request size. No hits != not attacked.\n'
  find_logs
  local f
  for f in ${SMS_FILES[@]+"${SMS_FILES[@]}"}; do emit INFO ioc.source "$f"; done
  if [[ ${#SMS_FILES[@]} -eq 0 && $SMS_USE_DOCKER == 0 ]]; then
    emit WARN ioc.source "no log file modified since $SMS_SINCE in the standard locations: pass log paths as arguments"
  fi
  local line lvl chk det
  while IFS= read -r line; do
    lvl=${line%%$'\t'*}; line=${line#*$'\t'}; chk=${line%%$'\t'*}; det=${line#*$'\t'}
    emit "$lvl" "$chk" "$det"
  done < <(stream_logs | prefilter | scan_awk)
  emit INFO ioc.limits "common/combined log formats do not record Content-Type or request size; absence of hits is not proof of absence. Correlate SIGSEGV times with access-log 502s"
  summary
  exit 0
}

[[ -n "${SMS_TEST:-}" ]] || main "$@"
