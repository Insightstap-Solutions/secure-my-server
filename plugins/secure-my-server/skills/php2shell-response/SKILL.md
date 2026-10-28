---
name: php2shell-response
description: Find, patch and clean up the October 2026 "PHP2Shell" PHP vulnerabilities (CVE-2026-109618 and CVE-2026-109619, unauthenticated remote code execution) on one or many Linux servers, whatever the setup - plain Ubuntu/Debian or RHEL packages, Docker images, cPanel, Plesk, aaPanel, DirectAdmin, CyberPanel/LiteSpeed or hand-built PHP. Detects every PHP runtime on each box, decides whether each one is really patched (including distro backports whose version number does not change), checks the logs and files for signs the server was already attacked, applies the right patch or a temporary mitigation for that stack, and proves the result. Use this whenever the user mentions PHP2Shell, CVE-2026-109618, CVE-2026-109619, CVE-2026-115560, "the new PHP RCE", patching PHP on their servers, checking whether a PHP server was hacked through a request-parsing bug, or asks "are my PHP servers safe" - even if they do not name the CVE.
argument-hint: "[ssh-host ...]"
---

# PHP2Shell response

You are helping someone close a critical, actively exploited PHP hole on servers that are **all set up differently**. The work is: find every PHP, decide honestly whether each is patched, look for signs it was already used, patch, and prove it. Production must stay up, and nothing destructive happens without a yes.

Hosts named by the user (may be empty): `$ARGUMENTS`

## The facts (checked on php.net, 27 Oct 2026)

| | |
|---|---|
| Bugs | CVE-2026-109618 (RCE via OOM corruption), CVE-2026-109619 (RCE via stale global state). Unauthenticated, CVSS 4.0 9.2. |
| Fixed in | **8.5.12, 8.4.27, 8.3.36, 8.2.35** (21 Oct 2026) |
| 8.1 and older | No official release. Only a distro/LTS vendor backport, a source backport, or an upgrade. |
| At risk | PHP-FPM, **Apache mod_php (highest risk)**, php-cgi, FrankenPHP, LiteSpeed |
| Keep anyway | `session.upload_progress.enabled=0` until the next regular PHP bugfix release (23 Oct advisory, CVE-2026-115560) |

Details, mitigations and sources: `${CLAUDE_SKILL_DIR}/references/advisory.md`. **Before you rely on this table, check php.net for a newer advisory** (`https://www.php.net/archive/2026.php`). If there is one, tell the user what changed and follow php.net.

## Ask once, up front

In one short round:
1. **Which servers?** SSH aliases or `user@host`. Does `sudo -n true` work on each?
2. **Which are production?** And is there a staging copy of each to try the patch on first?
3. **Approvals:** default is "ask before every production restart and every change". Confirm.
4. **Hands-off:** anything on these boxes that is not theirs to change (report only)?

In this skill's reference files, `scripts/`, `templates/` and `guides/` are folders at the plugin root, `${CLAUDE_PLUGIN_ROOT}`; `references/` is in `${CLAUDE_SKILL_DIR}`.

## The workflow

Do the steps in order **per server**. For more than two servers, read `${CLAUDE_SKILL_DIR}/references/fleet.md` first: it runs the read-only steps for all servers in parallel and keeps one table for the whole fleet.

Scripts live in `${CLAUDE_PLUGIN_ROOT}/scripts/`. Each one is read-only, never prints secrets or file contents, and is run over ssh on stdin, for example:
`ssh <host> 'sudo -n bash -s -- --since 2026-10-15' < "${CLAUDE_PLUGIN_ROOT}/scripts/php_runtimes.sh"`
Never put a script containing `$` inside single quotes on the ssh command line: the variables would expand on this machine.

### 1. Know the box (read-only)
Run `detect_stack.sh`, then `php_runtimes.sh`. Write down, for every PHP runtime: where it is, `kind`, SAPI, version, STATUS, and the `session.upload_progress.enabled` value.

- **One box often has several PHPs** (a panel's PHP 7.4, 8.1 and 8.3 side by side, plus a Docker app). Every one that serves web requests counts.
- Then open **only** the guide for each `kind` you found: `${CLAUDE_PLUGIN_ROOT}/guides/README.md` maps `kind` → guide. **The panel owns its PHP**: on a cPanel box follow the cPanel guide, never the generic Debian one.

How to read STATUS:
| STATUS | Meaning | Do |
|---|---|---|
| `PATCHED` | upstream version ≥ the fix for its branch | Verify the RUNNING process (step 5); old workers may still be up |
| `PATCHED_VENDOR` | distro package changelog names CVE-2026-109618 | Same as above |
| `VULNERABLE` | older than the fix | Patch (step 4); mitigate first (step 3) if it cannot happen today |
| `VENDOR_CHECK` | distro package; changelog not readable | Check the vendor's security tracker before deciding. **Never compare a distro version number with php.net's.** |
| `EOL` | 8.1 or older, no vendor fix found | Mitigate now; plan an upgrade or a supported backport. Tell the user plainly. |
| `PRERELEASE` | 8.6 RC | Move to RC4 or later, or off pre-releases in production |
| `UNKNOWN` | the script could not tell | Find out by hand; do not guess "safe" |

### 2. Was it already used? (read-only, before you change anything)
Patching closes the door; it does not remove anyone who already came in. Read `${CLAUDE_SKILL_DIR}/references/compromise-response.md`, then run on every server with a runtime that was ever vulnerable since 21 Oct:
- `php2shell_ioc_scan.sh --since <date the box became exposed>`: exploit-shaped requests, FPM crashes;
- `webshell_scan.sh --since <same date>`: new or planted PHP files;
- `persistence_check.sh --since <same date>`: cron, keys, users, services, odd processes and connections;
- on a Docker host, `container_sweep.sh --since <same date>`: files added inside containers, `/tmp/sess_*` session files (the upload-progress exploit leaves them), scripts in volumes. Run it before you recreate anything.

**Save evidence before any restart or recreate** (logs of containers you will replace, with checksums, in a root-only folder). A recreated container loses its `docker logs`.

Judge each server: **no signs found / suspicious / compromised**. Say the limits honestly: a normal access log does not record the Content-Type, so "no hits" is not proof. If **compromised**: stop, show the evidence, and follow the "If it was compromised" section of that file. Do not quietly patch over it.

### 3. Stop the bleeding (only if the patch cannot go on today)
From `advisory.md` → "If you cannot patch today", and the stack's guide for **where** each setting goes so it applies before request parsing (php.ini or the pool/server config, never `ini_set()` or `.user.ini`). At the edge, the stack's `guides/web/*.md` shows a rule that rejects `multipart/form-data` with an empty or missing boundary (400), and request size limits. These **reduce** exposure; say clearly they do not make the server safe.

### 4. Patch
Follow the stack's guide. Every time:
1. Back up each config file you touch (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`).
2. Staging (or the least important site) first, then production **only after the user says yes**.
3. Restart **every** worker of that PHP: FPM pools, Apache for mod_php, `lsphp` processes, the containers (Docker: rebuild with `--pull`, then **recreate**, never just restart).
4. Add `session.upload_progress.enabled=0` everywhere (`${CLAUDE_PLUGIN_ROOT}/templates/php/zz-hardening.ini` shows the full file), unless the application really uses upload progress (grep first).
5. For Docker images, add the build guard from `${CLAUDE_PLUGIN_ROOT}/templates/php/Dockerfile.snippet`, so an old PHP can never be built again.

### 5. Prove it
Read `${CLAUDE_SKILL_DIR}/references/verify.md`. In short:
- re-run `php_runtimes.sh`: every runtime `PATCHED`/`PATCHED_VENDOR`, upload progress off;
- the **running** worker's version, not just the package on disk (a worker started before the update is still the old PHP);
- the site still works (home page, login, an upload if the site has one);
- the edge tests, if you added edge rules.

For production, or more than one server, hand the final check to the plugin's **`server-verifier`** agent: give it the hosts and the list of problems only, never your conclusions.

### 6. Report and next steps
Use this shape:
```
# PHP2Shell response: <date>

## Summary
<3–5 plain sentences: which servers are patched, any sign of attack, what is left>

## Servers
| Server | PHP runtime (kind, SAPI) | Before | After | Upload progress | Signs of attack | Proof |

## Signs of attack
<per server: none found / suspicious / compromised, with evidence and the limits of the check>

## Still open (owner, date)
- e.g. EOL PHP 7.4 on <server>: mitigated only; upgrade planned for <date>
- keep session.upload_progress off until the next PHP bugfix release
```
Then offer:
- **secret rotation**, if anything was suspicious or the old logs were gone: a server that ran vulnerable PHP for days, with no logs to prove otherwise, should be treated as possibly exposed;
- the **full hardening pass** (the `secure-my-server` skill in this plugin): open database ports, debug pages, missing limits, deploy safety.

## Rules that are never optional
- **Never print a secret** or the contents of a suspicious file. Describe it by path, size, date and hash.
- **Ask before:** any production restart or deploy, deleting any file (even an obvious web shell: it is evidence), firewall or SSH changes, and anything on a hands-off project.
- **If the permission system blocks a command,** tell the user and get a fresh yes. Never find another route around it.
- **Check alarming findings yourself** before you repeat them: run the key command again.
- **Someone else may be working on the box:** look for running deploys (`ps -eo etime,cmd | grep -E 'deploy|compose'`) before restarting anything.
