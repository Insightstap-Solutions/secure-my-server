# Secure My Server (plugin)

A Claude Code plugin that finds and fixes security problems on Linux servers, safely, and proves the fixes work. Its main job today is the October 2026 "PHP2Shell" PHP vulnerabilities (CVE-2026-109618 and CVE-2026-109619). It detects how each server is built first (distro PHP, Docker, cPanel, Plesk, aaPanel, DirectAdmin, LiteSpeed, hand-built), then follows the steps for that setup.

## What is inside

| | Name | What it does |
|---|---|---|
| Skill | `php2shell-response` | Finds every PHP on one or many servers, decides honestly whether each is patched (distro backports included), looks for signs of attack, patches or mitigates per setup, and proves it. |
| Skill | `secure-my-server` | The full pass: inventory, break-in check, open ports, PHP and web-server hardening, secret rotation, deploy safety, independent re-check. |
| Agent | `server-verifier` | A read-only second check that is given the problems, never the fixer's conclusions. |
| Folder | `scripts/` | Read-only detectors, run on your servers over your own SSH. They never print secrets or file contents. |
| Folder | `guides/`, `templates/` | Steps and config files for each kind of server. |

## How it handles your data

Nothing is sent anywhere by the plugin. Claude runs the scripts on servers you name, over your own SSH connection. Some scripts read configuration and env files **on those servers** to check them, and report only key names, classes and fingerprints, never values. Claude asks before any change, restart or deletion. Full details: [PRIVACY.md](PRIVACY.md).

## Use

Ask in your own words, for example: "Check my servers web1 and web2 for PHP2Shell and patch them. web2 is production." Or run `/secure-my-server:php2shell-response web1 web2`.

Use it only on servers you own or are allowed to administer. Source, tests and documentation: https://github.com/ankitraj20616/secure-my-server
