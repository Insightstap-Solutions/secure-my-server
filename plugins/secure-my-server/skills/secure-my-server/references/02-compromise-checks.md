# Phase 2: Compromise check (read-only)

Goal: find out whether anyone already got in, **before** changing anything that would destroy evidence.

## 0. Save evidence first
For every container you might restart or recreate later (start with the exposed ones), save these to a root-only folder:
```bash
sudo mkdir -p /root/incident-$(date +%Y%m%d) && sudo chmod 700 /root/incident-$(date +%Y%m%d)
docker logs --timestamps <c> > /root/incident-<date>/<c>.log 2>&1
docker inspect <c> > /root/incident-<date>/<c>.inspect.json
docker cp <c>:/data /root/incident-<date>/<c>_data      # Redis AOF/RDB etc.
cd /root/incident-<date> && find . -type f -exec sha256sum {} + > SHA256SUMS
```
**Do not print payload contents.** Classify them by pattern instead.

## 1. Exposed Redis
Use `docker exec <c> redis-cli` (with `-e REDISCLI_AUTH=...` if it has a password):
- **Password:** `PING` without auth. `NOAUTH` means it has one. Check how strong it is without printing it (length, dictionary word?).
- **Write-to-disk trick:** `CONFIG GET dir`, `CONFIG GET dbfilename`. Attackers point these at `/root/.ssh`, `/var/spool/cron` or `/etc`.
- **Rogue-master trick:** `INFO replication`, `CONFIG GET replicaof`. An unknown master means a module-load RCE attempt.
- `MODULE LIST`, `CLIENT LIST` (any public `addr`?).
- `INFO stats`: `acl_access_denied_auth` = failed logins.
- **Keys:** sample with `SCAN`, never `KEYS *` on prod, never print values. Attack keys look like `backup1..4`, `x`, `crackit`, `cron:*`.
- **Logs:**
  ```bash
  docker logs <c> 2>&1 | grep -E 'REPLICAOF|MASTER MODE|Connecting to MASTER|SECURITY ATTACK'
  ```
- **AOF:** count `cron:` SET/DEL entries, and the IPs inside (`grep -aoE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort | uniq -c`).
- **Could it run anything?** Check:
  - mounts (only `/data`?);
  - the user (uid 999?);
  - whether there is a `crond`;
  - `docker top <c>`, and the host `ps`, for miners (`kdevtmpfsi`, `kinsing`, `xmrig`).

## 2. Exposed Postgres / MySQL
- **Postgres:**
  - `SHOW hba_file` and its rules (`trust` for non-local = critical);
  - `\du` (unknown roles? unexpected superusers?), databases, schemas, extensions;
  - non-extension functions, triggers, event triggers, large objects, foreign servers;
  - `pg_stat_activity` client addresses;
  - **ransom notes and theft:** ordinary tables named like `readme`, `recover`, `warning`, `bitcoin`, `how_to`, `decrypt`, or a database that is suddenly empty. Search ordinary tables only (`relkind = 'r'`): Postgres's own view `pg_stat_recovery_prefetch` matches `recover`;
  - **a way to run commands:** untrusted languages (`select lanname from pg_language where not lanpltrusted and lanname not in ('internal','c')`, for example `plpython3u` or `plperlu`) in every database, not only `postgres`.
- **Logs:**
  - count `password authentication failed`, and the top usernames tried;
  - search for `COPY ... PROGRAM`, `lo_import`, `pg_read_file`, `CREATE ROLE`.
- **Say the limit out loud:** with `log_connections` off, a **successful** login leaves no trace. You can only report "no evidence found", never "clean".
- **App tables:** users and admins created or changed around suspicious dates, unknown email domains, privilege flags.
- **MySQL:** `select user,host from mysql.user`, plus the app's admin users. Look for ransom tables the same way (`select table_schema, table_name from information_schema.tables where table_name regexp 'readme|recover|warning|bitcoin|how_to|ransom|decrypt'`), and for unknown `'%'` users with `FILE` or `SUPER`.

## 3. Web apps (PHP, Python, Node)

Start with the scripts: `webshell_scan.sh --since <date>` and `persistence_check.sh --since <date>` cover most of this section; on a Docker host add `container_sweep.sh --since <date>` for what they cannot see inside containers and volumes. Then, by hand:
- **Code files git does not know:** in the web root and in upload, storage and cache folders, compare `find` with `git ls-files`. Each framework has some expected generated files (for example Laravel's compiled views). Anything else is a question for the user.
- **Admin users:** list them with `created_at`, and flag anything after the suspicious date.
- **SSH keys:** `authorized_keys` comments for each user. **Ask the user to confirm each one.**
- **Cron:** `crontab -l -u <each user>`, `/etc/cron*`, `/var/spool/cron*`, `systemctl list-timers --all`. Read every control-panel cron script too (each panel keeps its own; see its guide). Most are certificate renewal and backups.
- **systemd units changed since date X:**
  ```bash
  find /etc/systemd /lib/systemd/system -newermt <date> -type f
  dpkg --verify systemd
  ```
  On Ubuntu 24.04 `/lib` → `/usr/lib`, so `dpkg -S /lib/...` says "not owned". **That is a false positive**; check `/usr/lib/...` and the md5sums.
- **Processes and connections:** `ps -eo pid,user,lstart,cmd`; ESTABLISHED peers per process, on the host and in each container's network namespace.
- **tmp dirs:** `/tmp`, `/var/tmp`, `/dev/shm` on the host and in each container, plus `docker diff <c>` for added files (stopped containers too). `container_sweep.sh` does the `docker diff` part. A native PHP session file (`/tmp/sess_*`) in an app that keeps sessions in its framework or Redis is a leftover of the upload-progress exploit: count them and read their times, never paste their names (they are session ids).
- **Named volumes:** `docker diff` does not see them. An uploads volume with a PHP file, or a Redis `/data` volume with a `.so` or an `authorized_keys`, is an attack. `container_sweep.sh` lists them.

## 4. Request-parsing exploits (PHP2Shell and similar)
Run `php2shell_ioc_scan.sh --since <date>`. The indicators, and the honest limits of a log scan, are in the `php2shell-response` skill: `${CLAUDE_PLUGIN_ROOT}/skills/php2shell-response/references/advisory.md` ("What attacks look like") and `compromise-response.md`.

## 5. Suspicious files
Before you call a file a payload:
- `stat` it (owner, birth time) and `sha256sum` it;
- grep it for `eval|base64_decode|system(|exec(|shell_exec|$_POST`;
- read its head as text (`cut -c1-200 | cat -v`);
- check shell history.

It may be the team's own test fixture. That is still worth deleting if it holds a known password, but it is **not** an attacker's file. **Classify, then ask before deleting.**

## 6. Scanner noise vs attack
Requests like `/app/seed.php`, `/vendor/phpunit/.../eval-stdin.php`, `/.env` or `/wp-login.php` that got 404 or 405 are **scanners**. Report them briefly; don't escalate.

## Output of this phase
For each service: **clean / suspicious / compromised**, with the evidence (commands + outputs, values classified, not printed).

If **compromised**, stop and present it to the user before Phase 3.
