#!/usr/bin/env bats
# php_runtimes.sh against fake roots. PHP binaries in the fixtures are tiny sh shims.

setup() { load helpers; }
run_pr() { run bash "$SCRIPTS/php_runtimes.sh" --root "$ROOT" "$@"; }

@test "ubuntu: distro php8.3 whose changelog mentions the CVE is PATCHED_VENDOR" {
  setup_sandbox ubuntu dpkg-query
  run_pr --no-docker
  [ "$status" -eq 0 ]
  line=$(line_matching $'^OK\tphp.runtime\twhere=/usr/sbin/php-fpm8.3 ')
  [[ $line == *"kind=distro"* && $line == *"sapi=fpm"* && $line == *"pkg=php8.3-fpm 8.3.6-0ubuntu0.24.04.6"* && $line == *"status=PATCHED_VENDOR"* ]]
  [ -n "$(line_matching 'where=/usr/bin/php8.3 .*status=PATCHED_VENDOR')" ]
}

@test "ubuntu: /usr/bin/php symlink is not reported twice" {
  setup_sandbox ubuntu dpkg-query
  run_pr --no-docker
  [ "$(grep -c $'\tphp.runtime\twhere=/usr/bin/php8.3 ' <<<"$output")" -eq 1 ]
  ! grep -q 'where=/usr/bin/php ' <<<"$output"
  ! grep -q 'where=/etc/alternatives' <<<"$output"
}

@test "ubuntu: distro package without a readable changelog is VENDOR_CHECK with instructions" {
  setup_sandbox ubuntu dpkg-query
  run_pr --no-docker
  line=$(line_matching 'where=/usr/bin/php8.1 ')
  [[ $line == WARN* && $line == *"status=VENDOR_CHECK"* && $line == *"apt changelog"* ]]
}

@test "ubuntu: FPM pool overrides are read; the worst pool decides" {
  setup_sandbox ubuntu dpkg-query
  run_pr --no-docker
  line=$(line_matching $'php.upload_progress\t/usr/sbin/php-fpm8.3 ')
  # www turns it off with php_admin_flag, shop inherits On from php.ini: still enabled somewhere
  [[ $line == WARN* && $line == *"www=off(php_admin_flag"* && $line == *"shop=On(ini)"* ]]
  line=$(line_matching $'php.memory_limit\t/usr/sbin/php-fpm8.3 ')
  [[ $line == *"shop=512M(php_admin_value"* ]]
}

@test "ubuntu: mod_php is found, loaded, packaged and read from its own php.ini" {
  setup_sandbox ubuntu dpkg-query
  run_pr --no-docker
  line=$(line_matching 'where=/usr/lib/apache2/modules/libphp8.3.so')
  [[ $line == OK* && $line == *"loaded=yes"* && $line == *"status=PATCHED_VENDOR"* ]]
  line=$(line_matching $'php.upload_progress\t/usr/lib/apache2/modules/libphp8.3.so')
  [[ $line == OK* && $line == *"99-hardening.ini"* ]]
}

@test "ubuntu: a replaced binary and a PHP-like binary in /tmp are reported, the latter never executed" {
  setup_sandbox ubuntu dpkg-query
  run_pr --no-docker
  [ -n "$(line_matching $'^WARN\tphp.process\tpid 1234 .*REPLACED on disk')" ]
  [ -n "$(line_matching $'^WARN\tphp.process\tpid 2222 .*unexpected location /tmp/.x/php-fpm: not executed')" ]
}

@test "ubuntu: pool env secrets are never printed" {
  setup_sandbox ubuntu dpkg-query
  run_pr --no-docker
  ! grep -q FAKE_SECRET_DO_NOT_PRINT <<<"$output"
}

@test "aapanel: /www/server/php/84 at 8.4.26 is VULNERABLE, 7.4 is EOL, FPM upload progress on is CRIT" {
  setup_sandbox aapanel
  run_pr
  [ -n "$(line_matching $'^CRIT\tphp.runtime\twhere=/www/server/php/84/sbin/php-fpm kind=aapanel sapi=fpm version=8.4.26 .*status=VULNERABLE')" ]
  [ -n "$(line_matching $'^CRIT\tphp.runtime\twhere=/www/server/php/74/bin/php kind=aapanel .*status=EOL')" ]
  [ -n "$(line_matching $'^CRIT\tphp.upload_progress\t/www/server/php/84/sbin/php-fpm \\(fpm\\)')" ]
  # CLI upload progress is informational only
  [ -n "$(line_matching $'^INFO\tphp.upload_progress\t/www/server/php/84/bin/php \\(cli\\)')" ]
}

@test "cpanel: ea-php82 8.2.35 is PATCHED, its cPanel pool turns upload progress off, ea-php81 is EOL" {
  setup_sandbox cpanel rpm
  run_pr
  [ -n "$(line_matching $'^OK\tphp.runtime\twhere=/opt/cpanel/ea-php82/root/usr/sbin/php-fpm kind=cpanel-ea .*pkg=ea-php82-php-fpm .*status=PATCHED')" ]
  [ -n "$(line_matching $'^OK\tphp.upload_progress\t/opt/cpanel/ea-php82/root/usr/sbin/php-fpm .*example_com=0\\(php_admin_value')" ]
  [ -n "$(line_matching 'where=/opt/cpanel/ea-php81/root/usr/bin/php kind=cpanel-ea .*status=EOL')" ]
}

@test "rhel: rpm changelog with the CVE gives PATCHED_VENDOR" {
  setup_sandbox rhel rpm
  SMS_RPM_CHANGELOG=patched run_pr
  [ -n "$(line_matching $'^OK\tphp.runtime\twhere=/usr/sbin/php-fpm kind=distro .*status=PATCHED_VENDOR')" ]
}

@test "rhel: rpm changelog without the CVE gives VULNERABLE" {
  setup_sandbox rhel rpm
  SMS_RPM_CHANGELOG=old run_pr
  [ -n "$(line_matching $'^CRIT\tphp.runtime\twhere=/usr/sbin/php-fpm kind=distro .*status=VULNERABLE \\(vendor changelog read')" ]
}

@test "rhel: no changelog at all gives VENDOR_CHECK" {
  setup_sandbox rhel rpm
  SMS_RPM_CHANGELOG=none run_pr
  [ -n "$(line_matching 'where=/usr/sbin/php-fpm kind=distro .*status=VENDOR_CHECK')" ]
}

@test "misc: 8.6.0RC3 is PRERELEASE, 8.5.11 is VULNERABLE with 8.5-only backtraces check, unreadable is UNKNOWN" {
  setup_sandbox misc
  run_pr
  [ -n "$(line_matching $'^WARN\tphp.runtime\twhere=/usr/local/bin/php kind=source sapi=cli version=8.6.0RC3 .*status=PRERELEASE')" ]
  [ -n "$(line_matching $'^CRIT\tphp.runtime\twhere=/usr/local/sbin/php-fpm .*version=8.5.11 .*status=VULNERABLE')" ]
  [ -n "$(line_matching $'^WARN\tphp.display_errors\t/usr/local/sbin/php-fpm')" ]
  [ -n "$(line_matching $'^WARN\tphp.fatal_error_backtraces\t/usr/local/sbin/php-fpm')" ]
  [ -n "$(line_matching $'^WARN\tphp.runtime\twhere=/usr/local/php83/bin/php kind=directadmin .*status=UNKNOWN')" ]
}

@test "docker: PHP inside running containers, via docker exec" {
  setup_sandbox dockerhost docker
  run_pr --docker
  [ -n "$(line_matching $'^CRIT\tphp.runtime\twhere=docker:shop-app:/usr/local/sbin/php-fpm image=php:8.3-fpm-alpine kind=docker sapi=fpm version=8.3.30 status=VULNERABLE')" ]
  [ -n "$(line_matching $'^OK\tphp.runtime\twhere=docker:shop-api:/usr/local/bin/php .*version=8.4.27 status=PATCHED')" ]
  ! grep -q 'shop-mysql' <<<"$output"
  ! grep -q FAKE_SECRET_DO_NOT_PRINT <<<"$output"
}

@test "summary counts match the finding lines" {
  setup_sandbox aapanel
  run_pr
  crit=$(grep -c $'^CRIT\t' <<<"$output"); info=$(grep -c $'^INFO\t' <<<"$output")
  [[ ${lines[-1]} == *"CRIT=$crit "* && ${lines[-1]} == *"INFO=$info "* ]]
}
