#!/usr/bin/env bash
# webshell_scan.sh - look for web shells and dropped files in web roots and temp directories.
#
# READ-ONLY. Lists files and greps them for suspicious patterns. It prints path, size, mtime, ctime,
# owner, sha256 and rule names - NEVER file contents. It deletes, moves and quarantines nothing.
#
#   ssh host 'sudo bash -s -- --since 2026-10-15' < scripts/webshell_scan.sh
#   ssh host 'sudo bash -s -- --since 2026-10-15 /srv/app/public' < scripts/webshell_scan.sh
#
# Output: LEVEL<TAB>CHECK<TAB>DETAIL lines, then SUMMARY. Exit 0 always; 2 on bad arguments.

SMS_NAME=webshell_scan
SMS_ROOT=""
SMS_SINCE="2026-10-15"
SMS_MAX_BYTES=$((5 * 1024 * 1024))
SMS_MAX_RECENT=200
SMS_N_CRIT=0; SMS_N_WARN=0; SMS_N_INFO=0; SMS_N_OK=0; SMS_N_SKIP=0
SMS_EXTRA=()
declare -gA F_RULES=() F_LEVEL=() F_META=()

usage() {
  cat <<'EOF'
webshell_scan.sh [--since YYYY-MM-DD] [--root DIR] [--max-recent N] [--no-tmp] [WEBROOT...]

Web roots: /var/www /www/wwwroot /home/*/public_html /home/*/domains/*/public_html
  /var/www/vhosts/*/httpdocs /usr/share/nginx/html /srv, plus any WEBROOT given.
Rules (per file, combined on one line):
  recent_php            .php .phtml .phar .php5 .php7 .inc with mtime OR ctime >= --since
  recent_htaccess / recent_user_ini   .htaccess / .user.ini changed since --since
  php_in_upload_dir     PHP file under uploads/storage/cache/tmp/images/media/files
                        (Laravel compiled views and bootstrap/cache are not counted)
  image_with_php        jpg/jpeg/png/gif/ico/svg/webp/bmp containing "<?php"
  eval_decode eval_input create_function_input preg_replace_e exec_input input_as_function
                        eval/assert/create_function/preg_replace /e or system/passthru/shell_exec/
                        proc_open/popen fed by base64_decode/gzinflate/str_rot13/superglobals
  long_base64           a base64 run of 500+ characters
  user_ini_prepend      auto_prepend_file / auto_append_file in .user.ini or .htaccess
  htaccess_php_handler  .htaccess making image/text extensions run as PHP
Hits under vendor/ or node_modules/ are INFO unless the file changed since --since (frameworks
use eval legitimately). Files over 5 MB are not pattern-scanned and are reported as SKIP.
Also /tmp /var/tmp /dev/shm (unless --no-tmp): PHP files, ELF binaries and #! scripts.

Options:
  --since DATE     YYYY-MM-DD (default 2026-10-15)
  --root DIR       prefix for every path inspected (tests / mounted images)
  --max-recent N   per web root, print at most N files whose ONLY rule is recent_php (default 200)
  --no-tmp         skip /tmp /var/tmp /dev/shm
  --help           this text

READ-ONLY: reads and hashes files, never prints their contents, never changes or deletes them.
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
lvl_rank() { case $1 in CRIT) echo 4 ;; WARN) echo 3 ;; INFO) echo 2 ;; *) echo 1 ;; esac; }
fmt_epoch() { date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$1"; }

# Suspicious-content rules: NAME<TAB>extended regex (matched case-insensitively, per line).
pattern_rules() {
  # shellcheck disable=SC2016  # a literal "$_POST" etc. for grep, not a shell expansion
  local sg='\$_(POST|GET|REQUEST|COOKIE|SERVER|FILES)'
  local dec='(base64_decode|gzinflate|gzuncompress|gzdecode|str_rot13|strrev|rawurldecode|hex2bin|convert_uudecode)'
  printf '%s\t%s\n' \
    eval_decode "(eval|assert)[[:space:]]*\\([[:space:]]*@?[[:space:]]*${dec}[[:space:]]*\\(" \
    eval_input "(eval|assert)[[:space:]]*\\([[:space:]]*@?[[:space:]]*(stripslashes[[:space:]]*\\([[:space:]]*)?$sg" \
    create_function_input "create_function[[:space:]]*\\([^;]*($dec|$sg)" \
    preg_replace_e "preg_replace[[:space:]]*\\([[:space:]]*['\"]([/#~|@!]).*[/#~|@!][a-zA-Z]*e[a-zA-Z]*['\"][[:space:]]*,[^;]*($dec|$sg)" \
    exec_input "(system|passthru|shell_exec|exec|proc_open|popen|pcntl_exec)[[:space:]]*\\([[:space:]]*@?[[:space:]]*(stripslashes[[:space:]]*\\([[:space:]]*)?$sg" \
    input_as_function "${sg}[[:space:]]*\\[[^]]*\\][[:space:]]*\\(" \
    long_base64 "[A-Za-z0-9+/]{500,}={0,2}"
}

# Default web roots that exist, minus any root nested inside another one.
web_roots() {
  local g d r o keep
  local -a all=() out=()
  for g in /var/www /www/wwwroot "/home/*/public_html" "/home/*/domains/*/public_html" \
    "/var/www/vhosts/*/httpdocs" /usr/share/nginx/html /srv; do
    # shellcheck disable=SC2086  # unquoted on purpose: the pattern part is a glob; the root prefix stays quoted
    for d in "$SMS_ROOT"$g; do [[ -d $d && ! -L $d ]] && all+=("${d#"$SMS_ROOT"}"); done
  done
  for d in ${SMS_EXTRA[@]+"${SMS_EXTRA[@]}"}; do
    if [[ -d $(rp "$d") ]]; then all+=("${d%/}"); else emit SKIP webshell.input "$d: not a directory"; fi
  done
  for r in ${all[@]+"${all[@]}"}; do
    keep=1
    for o in "${all[@]}"; do [[ $r != "$o" && $r == "$o"/* ]] && keep=0; done
    for o in ${out[@]+"${out[@]}"}; do [[ $r == "$o" ]] && keep=0; done
    [[ $keep == 1 ]] && out+=("$r")
  done
  [[ ${#out[@]} -gt 0 ]] && printf '%s\n' "${out[@]}"
}

add_rule() { # PATH RULE LEVEL META
  local p=$1 rule=$2 lvl=$3
  if [[ -z ${F_RULES[$p]+x} ]]; then F_RULES[$p]=$rule; F_LEVEL[$p]=$lvl; F_META[$p]=$4
  else
    [[ ",${F_RULES[$p]}," == *",$rule,"* ]] || F_RULES[$p]+=",$rule"
    [[ $(lvl_rank "$lvl") -gt $(lvl_rank "${F_LEVEL[$p]}") ]] && F_LEVEL[$p]=$lvl
  fi
}

# Scan one web root. Fills F_* in THIS shell.
scan_root() {
  local root=$1 abs since_epoch line kind p rest meta mt ct sz rule re f
  abs=$(rp "$root")
  since_epoch=$2
  local -a scan=() imgs=()
  local -A meta_of=() recent=()
  # mtime|ctime|size|owner|path for candidate files. stat -c works on GNU and busybox.
  while IFS= read -r line; do
    mt=${line%%|*}; rest=${line#*|}; ct=${rest%%|*}; rest=${rest#*|}; sz=${rest%%|*}; rest=${rest#*|}
    meta=${rest%%|*}; p=${rest#*|}; p=${p#"$SMS_ROOT"}
    [[ $mt =~ ^[0-9]+$ ]] || continue
    meta_of[$p]="$sz|$mt|$ct|$meta"
    kind=other
    case ${p,,} in
      *.php | *.phtml | *.phar | *.php5 | *.php7 | *.inc) kind=php ;;
      *.jpg | *.jpeg | *.png | *.gif | *.ico | *.svg | *.webp | *.bmp) kind=img ;;
      */.htaccess) kind=htaccess ;;
      */.user.ini) kind=userini ;;
    esac
    local is_recent=0 vend=0 rel=${p#"$root"}
    [[ $mt -ge $since_epoch || $ct -ge $since_epoch ]] && is_recent=1 && recent[$p]=1
    [[ $rel == */vendor/* || $rel == */node_modules/* ]] && vend=1
    case $kind in
      php)
        if [[ $is_recent == 1 ]]; then
          if [[ $vend == 1 ]]; then VENDOR_RECENT=$((VENDOR_RECENT + 1)); else add_rule "$p" recent_php WARN "${meta_of[$p]}"; fi
        fi
        if [[ ${rel,,} =~ /(uploads?|storage|cache|tmp|temp|images?|img|media|files)/ && $vend == 0 ]] &&
          ! [[ $rel =~ /storage/framework/views/[^/]+\.php$ || $rel =~ /bootstrap/cache/[^/]+\.php$ || $rel =~ /var/cache/ ]]; then
          add_rule "$p" php_in_upload_dir WARN "${meta_of[$p]}"
        fi
        if [[ $sz -gt $SMS_MAX_BYTES ]]; then emit SKIP webshell.too_big "$p size=$sz: larger than 5 MB, not pattern-scanned"
        else scan+=("$p"); fi ;;
      img) [[ $sz -le $SMS_MAX_BYTES ]] && imgs+=("$p") ;;
      htaccess | userini)
        [[ $is_recent == 1 ]] && add_rule "$p" "recent_${kind/userini/user_ini}" WARN "${meta_of[$p]}"
        scan+=("$p") ;;
    esac
  done < <(find "$abs" -type f \( -iname '*.php' -o -iname '*.phtml' -o -iname '*.phar' -o -iname '*.php5' \
    -o -iname '*.php7' -o -iname '*.inc' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' \
    -o -iname '*.ico' -o -iname '*.svg' -o -iname '*.webp' -o -iname '*.bmp' -o -name .htaccess -o -name .user.ini \) \
    -print0 2>/dev/null | xargs -0 -r stat -c '%Y|%Z|%s|%U:%G|%n' 2>/dev/null)

  # Images that contain PHP code.
  if [[ ${#imgs[@]} -gt 0 ]]; then
    while IFS= read -r f; do
      f=${f#"$SMS_ROOT"}; add_rule "$f" image_with_php CRIT "${meta_of[$f]}"
    done < <(for f in "${imgs[@]}"; do printf '%s%s\0' "$SMS_ROOT" "$f"; done | xargs -0 -r grep -l -a -F '<?php' 2>/dev/null)
  fi
  [[ ${#scan[@]} -eq 0 ]] && return
  local -a scan_abs=()
  for f in "${scan[@]}"; do scan_abs+=("$SMS_ROOT$f"); done
  while IFS=$'\t' read -r rule re; do
    while IFS= read -r f; do
      f=${f#"$SMS_ROOT"}
      local rel=${f#"$root"} lvl=WARN
      if [[ ($rel == */vendor/* || $rel == */node_modules/*) && -z ${recent[$f]+x} ]]; then lvl=INFO; fi
      add_rule "$f" "$rule" "$lvl" "${meta_of[$f]}"
    done < <(printf '%s\0' "${scan_abs[@]}" | xargs -0 -r grep -l -a -i -E -- "$re" 2>/dev/null)
  done < <(pattern_rules)
  while IFS= read -r f; do
    f=${f#"$SMS_ROOT"}; add_rule "$f" user_ini_prepend WARN "${meta_of[$f]}"
  done < <(printf '%s\0' "${scan_abs[@]}" | xargs -0 -r grep -l -a -i -E '^[[:space:]]*(php_value[[:space:]]+)?auto_(prepend|append)_file' 2>/dev/null |
    grep -E '/(\.htaccess|\.user\.ini)$')
  while IFS= read -r f; do
    f=${f#"$SMS_ROOT"}; add_rule "$f" htaccess_php_handler CRIT "${meta_of[$f]}"
  done < <(printf '%s\0' "${scan_abs[@]}" | xargs -0 -r grep -l -a -i -E '(AddType|AddHandler|SetHandler)[^#]*php[^#]*\.(jpe?g|png|gif|ico|txt|svg|webp|bmp)' 2>/dev/null |
    grep -E '/\.htaccess$')
}

# Escalate combinations, then print one line per file.
report_files() {
  local root=$1 p sz mt ct own sha lvl rules only_recent=0 shown=0
  local -a paths=()
  for p in "${!F_RULES[@]}"; do [[ $p == "$root"/* ]] && paths+=("$p"); done
  [[ ${#paths[@]} -eq 0 ]] && return
  mapfile -t paths < <(printf '%s\n' "${paths[@]}" | sort)
  for p in "${paths[@]}"; do
    rules=${F_RULES[$p]}; lvl=${F_LEVEL[$p]}
    # a code-execution pattern in a file that is ALSO new or in an upload dir is the classic drop
    if [[ $lvl == WARN && $rules =~ (eval_|exec_input|input_as_function|create_function_input|preg_replace_e) &&
      $rules =~ (recent_php|php_in_upload_dir) ]]; then lvl=CRIT; fi
    if [[ $rules == recent_php ]]; then
      only_recent=$((only_recent + 1))
      [[ $only_recent -gt $SMS_MAX_RECENT ]] && continue
    fi
    IFS='|' read -r sz mt ct own <<<"${F_META[$p]}"
    sha=$(sha256sum -- "$SMS_ROOT$p" 2>/dev/null | cut -d' ' -f1)
    emit "$lvl" webshell.file "path=$p size=${sz:-?} mtime=$(fmt_epoch "${mt:-0}") ctime=$(fmt_epoch "${ct:-0}") owner=${own:-?} sha256=${sha:-unreadable} rules=$rules"
    shown=$((shown + 1))
  done
  if [[ $only_recent -gt $SMS_MAX_RECENT ]]; then
    emit INFO webshell.recent_more "$root: $((only_recent - SMS_MAX_RECENT)) more files whose only rule is recent_php not listed (a deploy?). Raise --max-recent to see them"
  fi
}

scan_tmp() {
  local since_epoch=$1 d f p m lvl rule mt ct sz own line rest
  for d in /tmp /var/tmp /dev/shm; do
    [[ -d $(rp "$d") ]] || continue
    while IFS= read -r line; do
      mt=${line%%|*}; rest=${line#*|}; ct=${rest%%|*}; rest=${rest#*|}; sz=${rest%%|*}; rest=${rest#*|}
      own=${rest%%|*}; f=${rest#*|}; p=${f#"$SMS_ROOT"}
      [[ $mt =~ ^[0-9]+$ ]] || continue
      rule=""; m=""
      { IFS= read -r -n 4 -d '' m <"$f"; } 2>/dev/null
      case ${p,,} in *.php | *.phtml | *.phar | *.php5 | *.php7) rule=tmp_php ;; esac
      if [[ $m == $'\x7f'ELF ]]; then rule=tmp_elf
      elif [[ -z $rule && $m == '#!'* ]]; then rule=tmp_script
      elif [[ -z $rule && $m == '<?ph' ]]; then rule=tmp_php; fi
      [[ -z $rule ]] && continue
      lvl=WARN
      [[ $rule == tmp_elf && $p == /dev/shm/* ]] && lvl=CRIT
      [[ $rule != tmp_script && ($mt -ge $since_epoch || $ct -ge $since_epoch) ]] && lvl=CRIT
      emit "$lvl" "webshell.$rule" "path=$p size=$sz mtime=$(fmt_epoch "$mt") ctime=$(fmt_epoch "$ct") owner=$own sha256=$(sha256sum -- "$f" 2>/dev/null | cut -d' ' -f1)"
    done < <(find "$(rp "$d")" -maxdepth 4 -type f -print0 2>/dev/null | xargs -0 -r stat -c '%Y|%Z|%s|%U:%G|%n' 2>/dev/null)
  done
}

parse_args() {
  SMS_TMP=1
  while [[ $# -gt 0 ]]; do
    case $1 in
      --since)
        valid_ymd "${2:-}" || { echo "--since needs a date YYYY-MM-DD" >&2; return 2; }
        SMS_SINCE=$2; shift 2 ;;
      --root) [[ $# -ge 2 ]] || { echo "--root needs a directory" >&2; return 2; }; SMS_ROOT=${2%/}; shift 2 ;;
      --max-recent) [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "--max-recent needs a number" >&2; return 2; }; SMS_MAX_RECENT=$2; shift 2 ;;
      --no-tmp) SMS_TMP=0; shift ;;
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
  local since_epoch r n=0
  since_epoch=$(ymd_epoch "$SMS_SINCE")
  printf '# %s: web shells and dropped files, changed since %s (root=%s). Paths and hashes only, never contents.\n' \
    "$SMS_NAME" "$SMS_SINCE" "${SMS_ROOT:-/}"
  while IFS= read -r r; do
    [[ -z $r ]] && continue
    n=$((n + 1)); VENDOR_RECENT=0
    emit INFO webshell.root "$r"
    scan_root "$r" "$since_epoch"
    report_files "$r"
    [[ $VENDOR_RECENT -gt 0 ]] && emit INFO webshell.vendor_recent "$r: $VENDOR_RECENT PHP file(s) under vendor/ or node_modules/ changed since $SMS_SINCE (normal after composer install; their pattern hits are WARN)"
  done < <(web_roots)
  [[ $n -eq 0 ]] && emit WARN webshell.root "no web root found; pass the document root(s) as arguments"
  [[ $SMS_TMP == 1 ]] && scan_tmp "$since_epoch"
  [[ $SMS_N_CRIT -eq 0 && $SMS_N_WARN -eq 0 ]] && emit OK webshell.result "no suspicious file found by these rules (a clean result does not prove a clean server)"
  summary
  exit 0
}

[[ -n "${SMS_TEST:-}" ]] || main "$@"
