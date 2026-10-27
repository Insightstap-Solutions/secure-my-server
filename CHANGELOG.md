# Changelog

All notable changes are listed here. Versions follow [Semantic Versioning](https://semver.org/).
Claude Code only offers an update when `version` in `.claude-plugin/plugin.json` changes, so every release bumps it.

## [0.2.0] - 2026-10-27

First public release.

### Added
- `php2shell-response` skill: find every PHP runtime on one or many servers, decide whether each is really patched against CVE-2026-109618/109619 (including distro backports), look for signs of attack, mitigate, patch per stack, and prove it.
- `server-verifier` agent: an independent, read-only re-check that is given the problems, never the fixer's conclusions.
- Read-only detectors: `detect_stack.sh`, `php_runtimes.sh`, `php2shell_ioc_scan.sh`, `webshell_scan.sh`, `persistence_check.sh`. One finding per line, never print secrets or file contents.
- Per-stack guides (`guides/`): PHP on Docker, Debian/Ubuntu, RHEL family, Alpine, cPanel, Plesk, aaPanel, DirectAdmin, CyberPanel/OpenLiteSpeed, FrankenPHP and source builds; nginx, Apache, Caddy, LiteSpeed, CDN/WAF; ufw, firewalld, nftables/iptables and Docker.
- Tests (bats) with fixture servers, shellcheck, repository checks, and CI.

### Changed
- `secure-my-server` skill now detects the server's setup first and reads only the matching guides, instead of assuming Docker + aaPanel + Laravel.
- Scripts and templates moved to the plugin root (`scripts/`, `templates/`) so both skills share them.

## [0.1.0] - 2026-10-27

Private draft: the `secure-my-server` skill written from one real incident.
