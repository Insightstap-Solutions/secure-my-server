# Worked example (anonymised)

One Ubuntu VPS with a control panel (which brought its own nginx) and Docker. It ran:
- **App A:** a Laravel application (prod, staging, dev), with PHP-FPM behind Caddy behind nginx, MySQL and Redis;
- **App B:** a Python API (prod, staging, dev), with Postgres and Redis, and a JavaScript frontend;
- **App C:** a small PHP website (staging).

This is one server's story. Yours will be built differently; the phases stay the same.

## What happened
- The PHP2Shell bugs (CVE-2026-109618/109619) were made public on 21 Oct 2026. App A's prod ran the vulnerable PHP for about 6 days afterwards.
- **One real exploit attempt:** 1 MB, then 8 MB multipart POSTs with an empty `boundary=`. One FPM worker crashed (502). No break-in was found, but the old container's history was gone, so every key was treated as possibly exposed.
- **The bigger finding was App B:** Postgres and Redis were published on `0.0.0.0` with the password `changeme`, and Docker bypassed ufw. Redis was **really abused**:
  - a rogue-master (REPLICAOF) attempt;
  - cron payloads written over 10 days.
  Nothing ran: only `/data` was mounted, and there was no crond in the container. A Postgres login could not be ruled out, because successful logins were not logged.

## What we found (by phase)
| Phase | Found |
|---|---|
| Inventory | Two nginx installs; a quick tunnel publishing App B's API past nginx; a third-party Docker registry mirror; 40 old env backups |
| Compromise | The Redis abuse above; ~240k failed Postgres logins (none for the real user); scanner noise only on App A |
| Hardening | PHP `display_errors`, `expose_php` and `session.upload_progress` all On; `pm.max_children=5`; no edge limits; proxy logs lost on recreate; dev with `APP_DEBUG=true` (scanners had collected debug pages) |
| Secrets | Prod and staging sharing APP_KEY and DB passwords; one AI key used by both apps in 5 places; App A's Redis with no password; App B's JWT key shared by all envs; live AI and storage keys committed in App B's repo (docs and a chat log) |
| Deploy safety | App B's deploy (`rsync --delete`) would re-open the ports, wipe the bind-mounted folders, and **delete a live-only feature** (live matched no branch); its web deploy reloaded the wrong nginx; App A's queue ignored SIGQUIT |

## What we did
- **App A:** PHP patched + hardening ini + build guard; pool 20/6/6 from measured memory; Caddy log volume + real client IPs; edge limits on 4 sites; dev debug off; APP_KEYs rotated with a grace period; MySQL and Redis passwords; `stop_signal` fix.
- **App B:** evidence saved; loopback binds; DOCKER-USER rule; every password rotated; per-env JWT keys; prod debug off; DB reviewed (clean); repo redacted; live code snapshotted into a deploy branch; deploy scripts fixed; dev certificate renewed.
- **Host:** tunnel disabled, mirror removed, 35 old backups deleted.
- **App C:** hardening ini + build guard.
- **Left by the owner's choice:** SSH password login, the panel open to the world, QA admin accounts on dev and staging.

## What went wrong during the fix (so you don't repeat it)
- **11 minutes of prod downtime** from the queue stop-signal problem (T2), triggered by a combined recreate.
- **About 5 minutes of staging crash-loop** from restarting instead of recreating after a DB password change (T3).
- A backup clean-up filter nearly deleted the same day's backups (T7).
- A drift check said "no difference" because `rsync -n` had no `-i` (T9).

## Time
About one working day with 3–4 parallel agents, plus waiting for approvals and for the client's keys.
