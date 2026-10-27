# Many servers at once

When the user has more than two servers, run the **read-only** steps (1 and 2) for all of them in parallel, then patch them one by one.

## 1. One subagent per server, read-only
Start one subagent per server (or per group of 3–4 small servers), all in the same message, so they run together. Each brief:

> Read-only check of `<ssh-host>` for the PHP2Shell vulnerabilities (CVE-2026-109618/109619). Change nothing on the server: no installs, restarts, edits or deletions. Never print secrets or file contents.
> Run these scripts over ssh on stdin, from `<absolute path of the plugin's scripts folder>`, as `ssh <host> 'sudo -n bash -s -- <args>' < <script>`:
> `detect_stack.sh`, `php_runtimes.sh`, `php2shell_ioc_scan.sh --since <date>`, `webshell_scan.sh --since <date>`, `persistence_check.sh --since <date>`.
> If `sudo -n` fails, run them without sudo and say which checks could not run.
> Report: (a) every PHP runtime as `path | kind | SAPI | version | STATUS | upload_progress`; (b) the control panel and the live web server; (c) every CRIT/WARN finding with its evidence line; (d) your verdict: no signs found / suspicious / compromised, and what you could not check.

Give the subagent the **absolute** scripts path; it does not see `${CLAUDE_PLUGIN_ROOT}`.

## 2. One table for the fleet
Merge the reports:

| Server | Prod? | Panel / web server | PHP runtimes (kind, version → STATUS) | Upload progress | Signs of attack | Next step |
|---|---|---|---|---|---|---|

Re-check yourself any server a subagent calls "compromised" before you tell the user.

## 3. Patch in risk order
1. Compromised servers: contain first (`compromise-response.md`), not "just patch".
2. Internet-facing production running `VULNERABLE` or `EOL` mod_php or FPM.
3. Other production.
4. Staging, dev, internal.

Group servers that share a stack (all cPanel, all Docker…), and patch the first one of each group with the user watching. Then ask whether to continue the rest of that group the same way.

## 4. Verify the fleet
Hand the final check to the `server-verifier` agent, one per server, or one for the whole list for small fleets. Give it the problems only, not your conclusions.
