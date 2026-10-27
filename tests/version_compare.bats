#!/usr/bin/env bats
# Unit tests for the version logic in php_runtimes.sh (sourced, main not run).

setup() {
  load helpers
  SMS_TEST=1 source "$SCRIPTS/php_runtimes.sh"
}

@test "upstream part strips distro suffixes and epochs, keeps pre-release tags" {
  [ "$(php_upstream 8.4.27)" = 8.4.27 ]
  [ "$(php_upstream 8.3.6-0ubuntu0.24.04.5)" = 8.3.6 ]
  [ "$(php_upstream 8.2.29-1~deb12u1)" = 8.2.29 ]
  [ "$(php_upstream 2:8.2.29-1~deb12u1)" = 8.2.29 ]
  [ "$(php_upstream 8.2.13-1.module+el9.4.0+20000+5e1b3cd1)" = 8.2.13 ]
  [ "$(php_upstream 8.3.0-1+ubuntu22.04.1+deb.sury.org+1)" = 8.3.0 ]
  [ "$(php_upstream 8.6.0RC3)" = 8.6.0RC3 ]
  [ "$(php_upstream 8.6.0-dev)" = 8.6.0-dev ]
}

@test "branch is major.minor" {
  [ "$(php_branch 8.3.6-0ubuntu0.24.04.5)" = 8.3 ]
  [ "$(php_branch 8.6.0RC3)" = 8.6 ]
  [ "$(php_branch 7.4.33)" = 7.4 ]
}

@test "vercmp: equal, less, greater" {
  [ "$(php_vercmp 8.4.27 8.4.27)" = 0 ]
  [ "$(php_vercmp 8.4.26 8.4.27)" = -1 ]
  [ "$(php_vercmp 8.4.28 8.4.27)" = 1 ]
}

@test "vercmp: numeric, not lexical" {
  [ "$(php_vercmp 8.3.9 8.3.36)" = -1 ]
  [ "$(php_vercmp 8.10.0 8.9.0)" = 1 ]
  [ "$(php_vercmp 8.2.100 8.2.35)" = 1 ]
}

@test "vercmp: distro string compares by its upstream part" {
  [ "$(php_vercmp 8.3.6-0ubuntu0.24.04.5 8.3.36)" = -1 ]
  [ "$(php_vercmp 8.3.36-1+deb.sury.org+1 8.3.36)" = 0 ]
}

@test "vercmp: pre-releases order dev < alpha < beta < RC < final" {
  [ "$(php_vercmp 8.6.0RC3 8.6.0RC4)" = -1 ]
  [ "$(php_vercmp 8.6.0RC4 8.6.0RC4)" = 0 ]
  [ "$(php_vercmp 8.6.0RC10 8.6.0RC4)" = 1 ]
  [ "$(php_vercmp 8.6.0RC4 8.6.0)" = -1 ]
  [ "$(php_vercmp 8.6.0beta2 8.6.0RC1)" = -1 ]
  [ "$(php_vercmp 8.6.0alpha1 8.6.0beta1)" = -1 ]
  [ "$(php_vercmp 8.6.0-dev 8.6.0alpha1)" = -1 ]
}

@test "fixed table is in one place and covers 8.2 to 8.5" {
  [ "$(fixed_for_branch 8.2)" = 8.2.35 ]
  [ "$(fixed_for_branch 8.3)" = 8.3.36 ]
  [ "$(fixed_for_branch 8.4)" = 8.4.27 ]
  [ "$(fixed_for_branch 8.5)" = 8.5.12 ]
  run fixed_for_branch 8.1
  [ "$status" -ne 0 ]
  [ "$(grep -c '^SMS_FIXED_VERSIONS=' "$SCRIPTS/php_runtimes.sh")" = 1 ]
  grep -q 'https://www.php.net/archive/2026.php' "$SCRIPTS/php_runtimes.sh"
}

st() { php_status "$@" | cut -f1; }

@test "status: upstream kinds" {
  [ "$(st aapanel 8.4.26 n/a)" = VULNERABLE ]
  [ "$(st aapanel 8.4.27 n/a)" = PATCHED ]
  [ "$(st cpanel-ea 8.2.35 n/a)" = PATCHED ]
  [ "$(st sury 8.3.36-1+deb.sury.org+1 n/a)" = PATCHED ]
  [ "$(st remi 8.5.11 n/a)" = VULNERABLE ]
  [ "$(st source 8.5.12 n/a)" = PATCHED ]
}

@test "status: EOL for 8.1 and older without a vendor fix" {
  [ "$(st cpanel-ea 8.1.33 n/a)" = EOL ]
  [ "$(st aapanel 7.4.33 n/a)" = EOL ]
  [ "$(st distro 8.1.2-1ubuntu2.20 no)" = EOL ]
  [ "$(st distro 8.1.2-1ubuntu2.20 yes)" = PATCHED_VENDOR ]
}

@test "status: distro packages are judged by the changelog, not the version string" {
  [ "$(st distro 8.3.6-0ubuntu0.24.04.6 yes)" = PATCHED_VENDOR ]
  [ "$(st distro 8.3.6-0ubuntu0.24.04.5 no)" = VULNERABLE ]
  [ "$(st distro 8.3.6-0ubuntu0.24.04.5 unknown)" = VENDOR_CHECK ]
  [ "$(st distro 8.4.27-1 unknown)" = PATCHED ]
}

@test "status: docker image with a distro suffix needs a vendor check" {
  [ "$(st docker 8.2.29-1~deb12u1 unknown)" = VENDOR_CHECK ]
  [ "$(st docker 8.2.34 n/a)" = VULNERABLE ]
}

@test "status: 8.6 pre-releases and unknowns" {
  [ "$(st source 8.6.0RC3 n/a)" = PRERELEASE ]
  [ "$(st source 8.6.0RC4 n/a)" = PRERELEASE ]
  php_status source 8.6.0RC3 n/a | grep -q AFFECTED
  php_status source 8.6.0RC4 n/a | grep -q 'contains the fix'
  [ "$(st source 8.6.1 n/a)" = PATCHED ]
  [ "$(st source 8.7.0 n/a)" = UNKNOWN ]
  [ "$(st source unknown n/a)" = UNKNOWN ]
}
