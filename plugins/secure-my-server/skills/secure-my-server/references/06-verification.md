# Phase 7: Independent verification (and agent orchestration)

## Why a separate agent
The agent that fixed something tends to confirm its own work. A verifier given **only the problems and a checklist**, and none of the fixers' conclusions, actually checks.

## Verifier brief (copy and fill in)
> You are an independent verifier. Read-only: do not change any config, file, container, user or firewall. The exceptions are throwaway test files you create and remove, and `docker restart` of web containers on non-production envs only. Never print secrets. No restarts on production.
>
> **Access:** `ssh <host>`. Sites: <list>. Containers: <names>.
>
> **The problems that were supposed to be fixed:** <numbered list, problems only>.
>
> **Checklist:**
> 1. From OUTSIDE: ports <list> are unreachable on IPv4 and IPv6. Run a top-1000 TCP scan and list every open port.
> 2. `curl -sI` on each site shows no `X-Powered-By`. 404, 405 and error bodies contain no stack traces, file paths or debug text. Dev shows no debug page.
> 3. Every PHP runtime on the box: version and hardened values **read through FPM** (temp file in `/tmp`, deleted, and proven gone). Pool settings, judged against RAM.
> 4. Proxy logs survive a `docker restart` (non-prod only; inspect prod).
> 5. Limits: oversized POST → 413 at nginx, empty boundary → 400, burst → 429. A real upload still works (test env; delete what you create).
> 6. A fresh compromise sweep: PHP files in storage/public, new admins, `authorized_keys` comments, cron/timers, processes, outbound connections, and exploit-shaped requests in the logs since <date>.
>
> **Report:** a table of check → PASS/FAIL/PARTIAL → evidence (command + output). Severity for each FAIL. Everything you created and removed. Anything suspicious you noticed.

Tell the verifier about **planned restarts** during its run, so it re-checks instead of reporting a transient failure.

## Orchestration pattern for fixers
Split by **domain**, so no two agents edit the same files:

| Agent | Owns | Stops before |
|---|---|---|
| A: app runtime | repo + image (PHP, pool, proxy, logs); works in a git **worktree** | production deploy |
| B: other projects' exposed services | inventory, abuse check, evidence, loopback binds | that project's production |
| C: edge proxy | **all** nginx files | nothing destructive; prod edits only with the user's prior OK |
| D: verifier | read-only | — |

**Each brief contains:**
- the goal;
- what is already ruled out;
- exact paths;
- the traps (`07-traps.md`);
- the approval gates;
- "never print secrets";
- "report commands and outputs";
- what the **other** agents own.

**Parallel test runs** need their own database, and still collide on shared fake-storage folders. Only the final clean run counts.

**When an agent reports something alarming** (for example "Redis compromised"), re-check the key evidence yourself before telling the user.

**When an agent is blocked by the permission system:** do not do it yourself. Explain to the user and get a fresh yes.
