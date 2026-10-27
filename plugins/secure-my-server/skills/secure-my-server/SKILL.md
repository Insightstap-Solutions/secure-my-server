---
name: secure-my-server
description: Audit and harden a Linux server that runs web applications - PHP (FPM, mod_php, LiteSpeed), Python, Node or anything in Docker - behind nginx, Apache, Caddy, LiteSpeed or a control panel such as cPanel, Plesk, aaPanel or DirectAdmin. Detects how this particular server is built, checks whether someone already broke in, closes exposed database and cache ports (including Docker ports that bypass the firewall), hardens PHP and the web server, finds and rotates secrets without printing them, makes the next deploy safe, and ends with an independent re-check, asking for approval before any production or destructive step. Use this skill whenever the user wants to secure, audit, harden, lock down or "check the safety of" a server or VPS, mentions a new CVE in PHP, nginx, Redis or a database, suspects an attack or an open port, asks whether a server is safe, or wants passwords and API keys rotated after an incident - even if they never say "audit" or "harden".
argument-hint: "[ssh-host]"
---

# Secure my server

You are helping someone make a server safe **without breaking it**. Every server is built differently, so you **detect first and assume nothing**: the same job is done with different commands on a cPanel box, a Docker host and a plain Ubuntu server.

Host named by the user (may be empty): `$ARGUMENTS`

**Only the PHP2Shell problem?** If the user only wants the October 2026 PHP vulnerabilities (CVE-2026-109618/109619) found and patched, use this plugin's `php2shell-response` skill instead: it is shorter and focused. This skill is the full pass. The work is part detective (did anyone get in?), part locksmith (close the doors, change the keys) and part careful operator (production stays up).

The steps come from a real incident. Every rule here exists because skipping it caused a problem once. When a rule looks fussy, read the "why": it is usually one line, and it is usually about real downtime or a real leak.

## Before you touch anything: ask once

Ask these in **one** short round (multiple choice where you can):

1. **SSH target**, and does `sudo -n true` work?
2. **Ownership:** which apps or projects on the box are ours to change, and which are hands-off (report only)?
3. **Production:** for each app, which environment is prod, and how does it deploy (CI, script, manual rsync)?
4. **Approvals:** default is "ask before every prod step". Confirm.
5. **Accepted risks:** anything they want left as it is (for example SSH password login, an open control panel).
6. **Accounts:** who owns each third-party account (Stripe, OpenAI, Anthropic, Appwrite and so on), us or the client?

Write the answers down. You will need them for every approval and in the final report.

## Golden rules

These protect the user from the most expensive mistakes. Follow them even when they slow you down.

1. **Never print a secret.** Not in output, reports, commits or PR bodies.
   - Compare values by fingerprint (`printf %s "$v" | sha256sum | cut -c1-8`).
   - Pass passwords to CLIs through env vars (`REDISCLI_AUTH`, `PGPASSWORD`, `MYSQL_PWD`) or stdin, never argv.
   - Generate new values straight into the file.
   - If one leaks into your output, say so and add it to the rotation list.
2. **Evidence before change.** Recreating a container erases its `docker logs`. Before touching anything suspicious, save its logs, its `docker inspect` output and its data files, with checksums, to a root-only directory.
3. **Ask first** before:
   - any production deploy, restart or recreate;
   - changes to a project that isn't ours;
   - deleting files;
   - firewall or SSH changes;
   - rewriting git history.
   If the permission system blocks an action, tell the user and get a fresh, explicit yes. Never route around a block, and never run yourself what a subagent was denied.
4. **Back up every file before editing it** (`cp -p f f.bak-<timestamp>-<reason>`).
5. **Check claims yourself.** Re-run the key command before you repeat a subagent's alarming finding to the user.
6. **Assume someone else may be working on the box.** Check for a running `docker compose` for the same project, and check the env file's md5 just before you write it.
7. **Order of rollout: test → staging → production.** Production only with the user's OK.

## The 8 phases

Do them in order. Each one has a reference file. **Read the file when you reach that phase**, not all of them up front.

| # | Phase | Goal | Read |
|---|---|---|---|
| 1 | Inventory (read-only) | How this server is built, what is public, where the secrets are, how prod deploys | `references/01-inventory.md` |
| 2 | Compromise check (read-only) | Did anyone already get in? Collect evidence | `references/02-compromise-checks.md` |
| 3 | Close open doors | DB, cache and app ports on loopback, DOCKER-USER rule, no default passwords | `references/03-hardening.md` §1–2 |
| 4 | Harden the apps | PHP-FPM, debug off, edge limits, logs that survive, Docker host | `references/03-hardening.md` §3–7 |
| 5 | Secrets | Inventory without printing, find shared keys, rotate ours, list the owner's, scan git | `references/04-secrets.md` |
| 6 | Deploy safety | The next deploy must not undo fixes or delete live-only code | `references/05-deploy-safety.md` |
| 7 | Independent check | A fresh agent, given only the problems and a checklist | `references/06-verification.md` |
| 8 | Write it down | Final table, simple-English docs, client message and key email | `references/08-communication.md` |

Paths in the table are relative to `${CLAUDE_SKILL_DIR}`.

**Stack-specific steps live in guides, not here.** After Phase 1 you know the panel, the web server, the PHP kinds and the firewall. Read only the matching files from `${CLAUDE_PLUGIN_ROOT}/guides/` (`guides/README.md` is the map). **The panel owns its software**: on a cPanel or Plesk box, follow that panel's guide, never the generic distro one, or the panel will overwrite your change.

**Always read `references/07-traps.md` before Phase 3.** It lists the mistakes that caused real outages: restart vs recreate, ignored stop signals, inode-breaking edits, two nginx binaries, and more. It is the most valuable file in this skill.

### If you find a real break-in in Phase 2

**Stop.** Show the evidence to the user and wait. They may want to preserve the box as it is for forensics before you change anything. Containment of an actively exposed service (binding a port to loopback, rotating a password the attacker has) is usually the right first move. Propose it; don't just do it.

## Working with subagents

For a box with several projects, split the work by **domain**, so no two agents edit the same files:
- one agent for the app runtime (repo changes, image, deploy to test and staging);
- one for each other project's exposed services;
- one that owns **all** front-proxy (nginx) files;
- an **independent verifier** at the end.

Give each agent:
- the goal and what is already ruled out;
- the exact paths;
- the traps from `07-traps.md`;
- the approval gates;
- "never print secrets";
- "report commands and outputs".

Tell each agent what the others own. Tell the verifier about planned restarts, so it re-checks instead of reporting a transient failure. Details are in `references/06-verification.md`.

In this skill's reference files, `scripts/`, `templates/` and `guides/` are folders at the plugin root, `${CLAUDE_PLUGIN_ROOT}`; `references/` is in `${CLAUDE_SKILL_DIR}`.

## Templates and scripts
- `${CLAUDE_PLUGIN_ROOT}/templates/` holds ready config files: PHP hardening ini and Docker build guard, FPM pool, Caddy snippet, nginx limits, DOCKER-USER rules, compose patterns. Adapt names, paths and ports to this server; keep the structure.
- `${CLAUDE_PLUGIN_ROOT}/scripts/` holds helpers. The detectors are **read-only** and **never print secret values or file contents**. Each prints one finding per line, `LEVEL<TAB>CHECK<TAB>DETAIL`, and `--help` says what it reads.
  - `detect_stack.sh`: OS, control panel, live web server, firewall, Docker, public listeners.
  - `php_runtimes.sh`: every PHP on the box, its kind, SAPI, version, patch status and key settings.
  - `php2shell_ioc_scan.sh`, `webshell_scan.sh`, `persistence_check.sh`: signs of an attack (Phase 2).
  - `fpm_ini_probe.sh`: read PHP values from a running FPM in a container, not the CLI.
  - `env_inventory.sh`: list secret keys per env file, with their class and a shared-value group.
  - `drift_check.sh`: is the live code really in git?
  - `build_needles.sh` + `secret_scan_repo.sh`: find real secret values inside a git repo. The needle file is secret: `umask 077`, delete it afterwards.
  - `rotate_mysql_laravel.sh`, `rotate_laravel_app_key.sh`: rotation recipes for Laravel apps. They change things: read them, adapt them, and run them only with the user's yes.

Run a script on the server by piping it over ssh on stdin, for example:
`ssh host 'sudo -n bash -s -- --since 2026-10-15' < "${CLAUDE_PLUGIN_ROOT}/scripts/detect_stack.sh"`
Never put a script containing `$` inside single quotes on the ssh command line; the variables expand on your machine. Subagents do not see `${CLAUDE_PLUGIN_ROOT}`: give them the absolute path.

## The independent check
Phase 7 hands the final check to this plugin's **`server-verifier`** agent. Give it the hosts and the list of problems only, never your conclusions.

## Final report (always this shape)

```
# Server security report: <host>, <date>

## Summary
<3–5 plain sentences: safe now? what is left? what does the user need to do?>

## Findings and fixes
| # | Problem | What changed | Where (file / path) | Proof (command → output) | Still open |

## Secrets
- Rotated by us: …
- Owner must reissue: …   (client email ready: yes/no)
- Found in git: …

## Accepted risks (user's decision)
- …

## Follow-ups with dates
- <date>: remove APP_PREVIOUS_KEYS …
- <date>: delete today's backups …
```

Then offer the simple-English documents and the client messages from `references/08-communication.md`.
