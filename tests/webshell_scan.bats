#!/usr/bin/env bats
# Fixture "web shells" are inert text files: nothing here is ever executed.

setup() { load helpers; }
run_ws() { run bash "$SCRIPTS/webshell_scan.sh" --root "$ROOT" "$@"; }
file_line() { grep -E $'\twebshell.file\tpath='"$1"' ' <<<"$output" | head -n1; }

@test "planted web shell in uploads is CRIT with path, hash and rule names" {
  setup_sandbox webroot
  run_ws --since 2099-01-01
  [ "$status" -eq 0 ]
  line=$(file_line /var/www/site/public/wp-content/uploads/2026/10/cache.php)
  [[ $line == CRIT* && $line == *"rules=php_in_upload_dir,eval_decode"* && $line =~ sha256=[0-9a-f]{64} ]]
  [[ $line == *"size="* && $line == *"mtime="* && $line == *"ctime="* && $line == *"owner="* ]]
  line=$(file_line /var/www/site/public/wp-content/uploads/2026/10/x.phtml)
  [[ $line == CRIT* && $line == *"input_as_function"* ]]
}

@test "file contents and planted secrets are never printed" {
  setup_sandbox webroot
  run_ws --since 2000-01-01
  ! grep -q FAKE_SECRET_DO_NOT_PRINT <<<"$output"
  ! grep -q 'base64_decode' <<<"$output"
  ! grep -q 'auto_prepend_file' <<<"$output"
  ! grep -q 'x-httpd-php' <<<"$output"
}

@test "benign vendor eval is INFO when old, WARN when changed since --since" {
  setup_sandbox webroot
  run_ws --since 2099-01-01
  [[ $(file_line /var/www/site/vendor/acme/packer/src/Packer.php) == INFO*"rules=eval_decode" ]]
  run_ws --since 2000-01-01
  [[ $(file_line /var/www/site/vendor/acme/packer/src/Packer.php) == WARN*"rules=eval_decode" ]]
  [ -n "$(line_matching $'^INFO\twebshell.vendor_recent\t/var/www: 2 PHP file')" ]
}

@test "image with PHP inside, PHP handler in .htaccess and auto_prepend in .user.ini" {
  setup_sandbox webroot
  run_ws --since 2099-01-01
  [[ $(file_line /var/www/site/public/images/logo.png) == CRIT*"rules=image_with_php" ]]
  [ -z "$(file_line /var/www/site/public/images/ok.png)" ]
  [[ $(file_line /var/www/site/public/.htaccess) == CRIT*"htaccess_php_handler"* ]]
  [[ $(file_line /var/www/site/public/.user.ini) == WARN*"user_ini_prepend"* ]]
}

@test "recent files: mtime/ctime since the date; Laravel compiled views are not upload-dir hits" {
  setup_sandbox webroot
  run_ws --since 2000-01-01
  [[ $(file_line /var/www/site/public/index.php) == WARN*"rules=recent_php" ]]
  [[ $(file_line /var/www/site/storage/framework/views/9f1c3e5a7b2d4c6e8f0a1b3c5d7e9f1a3b5c7d9e.php) == *"rules=recent_php" ]]
  run_ws --since 2099-01-01
  [ -z "$(file_line /var/www/site/public/index.php)" ]
  [ -z "$(file_line /var/www/site/storage/framework/views/9f1c3e5a7b2d4c6e8f0a1b3c5d7e9f1a3b5c7d9e.php)" ]
}

@test "--max-recent caps the plain recent_php list" {
  setup_sandbox webroot
  run_ws --since 2000-01-01 --max-recent 0
  [ -z "$(file_line /var/www/site/public/index.php)" ]
  [ -n "$(line_matching $'^INFO\twebshell.recent_more\t/var/www: 2 more files')" ]
}

@test "temp dirs: ELF and scripts are reported, session files are not" {
  setup_sandbox webroot
  run_ws --since 2099-01-01
  [ -n "$(line_matching $'^WARN\twebshell.tmp_elf\tpath=/tmp/.x/kworkerd ')" ]
  [ -n "$(line_matching $'^WARN\twebshell.tmp_script\tpath=/tmp/.x/run.sh ')" ]
  ! grep -q sess_abc123 <<<"$output"
  run_ws --since 2099-01-01 --no-tmp
  ! grep -q 'webshell.tmp_' <<<"$output"
}

@test "files over 5 MB are skipped for patterns and reported" {
  setup_sandbox webroot
  "$HEAD" -c 6000000 /dev/zero >"$ROOT/var/www/site/public/huge.php"
  run_ws --since 2099-01-01
  [ -n "$(line_matching $'^SKIP\twebshell.too_big\t/var/www/site/public/huge.php size=6000000')" ]
}

@test "web roots given as arguments; nested default roots are scanned once" {
  setup_sandbox webroot
  mkdir -p "$ROOT/srv/app/public"
  printf '<?php /* test fixture */ system($_REQUEST["c"]); ?>\n' >"$ROOT/srv/app/public/x.php"
  run_ws --since 2099-01-01 /var/www/site/public
  [ -n "$(line_matching $'^INFO\twebshell.root\t/srv$')" ]
  [ "$(grep -c $'\twebshell.root\t' <<<"$output")" -eq 2 ]
  [[ $(file_line /srv/app/public/x.php) == WARN*"rules=exec_input" ]]
}
