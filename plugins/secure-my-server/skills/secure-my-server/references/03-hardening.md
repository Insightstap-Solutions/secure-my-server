# Phases 3 and 4: Hardening

Read `07-traps.md` first. Each section says which servers it applies to. For the exact commands on this server's panel, web server and firewall, use the guides in `${CLAUDE_PLUGIN_ROOT}/guides/`.

## §1 Close the doors: network

**Services installed on the host** (no Docker):
- MySQL/MariaDB: `bind-address = 127.0.0.1`.
- PostgreSQL: `listen_addresses = 'localhost'`, plus `pg_hba.conf` (no `trust` for anything but local sockets).
- Redis: `bind 127.0.0.1 -::1`, `protected-mode yes`, and a `requirepass`.
- Memcached: `-l 127.0.0.1`.
- PHP-FPM: listen on a unix socket or `127.0.0.1:9000`, never `0.0.0.0`.

Restart each one, then prove it from **outside**. If another server really needs the port, allow only that server's address in the firewall (`guides/firewall/*.md`). Never open the port to the world.

**Docker hosts:**
1. **In every compose file, bind databases, caches and app ports to loopback:** `"127.0.0.1:5432:5432"`. Before you change an app port, check three things:
   - nginx proxies it via `127.0.0.1`, not the public IP;
   - no frontend env or built JS calls `http://<public-ip>:<port>`;
   - containers reach DB and cache by **service name**, not the host IP or `host.docker.internal`.

   If something uses the port directly from outside, **stop and ask.**
2. **Recreate only the affected services**, with the **same project name, files and env file** the containers were created with (read the labels):
   ```bash
   docker compose -p <proj> --env-file <f> -f <file> up -d --no-deps --no-build --dry-run <svc...>   # look first
   docker compose -p <proj> --env-file <f> -f <file> up -d --no-deps --no-build <svc...>
   ```
   Never `down -v`. Save evidence first (Phase 2 §0).
3. **Add the DOCKER-USER belt:** `templates/firewall/docker-user.rules`, appended to `/etc/ufw/after.rules` and `after6.rules`. Dry-run it with `iptables-restore --test -n`, then `ufw reload`. Check that `iptables -S FORWARD | head -3` shows `-j DOCKER-USER` first.
4. Remove ufw `ALLOW` rules for ports that are now loopback-only.
5. **Verify from outside** (laptop or another host), on IPv4 and IPv6: `nmap -Pn -p <ports> <ip>`, or a TCP connect scan.

## §2 Default and weak passwords
- Replace `${VAR:-changeme}` style fallbacks with `${VAR:?VAR must be set}` (compose, entrypoints).
- **`:?` still lets the literal string `null` through.** Add a deploy pre-flight that refuses empty, `null`, short (<16), placeholder, or anything outside `[A-Za-z0-9_-]`.
- Strip plain-text passwords from tracked docs and scripts.
- Rotate the weak ones (`04-secrets.md`).

## §3 PHP (any SAPI)
- **Patch first.** `php_runtimes.sh` gives each runtime's STATUS. For the October 2026 PHP2Shell bugs, follow the `php2shell-response` skill, then come back here.
- **Read values from the web SAPI**, never `php -i` (that is the CLI, and often a different ini). For FPM, `php-fpm<ver> -i` plus the pool overrides; in Docker, `scripts/fpm_ini_probe.sh <container>`.
- **Targets:**
  - `display_errors=Off`, `display_startup_errors=Off`;
  - `log_errors=On`;
  - `expose_php=Off`;
  - `session.upload_progress.enabled=Off` (grep the app first to confirm it is unused).
- **How:** put `templates/php/zz-hardening.ini` in the conf.d (scan) directory of **every** web PHP, named so it loads last. The guide for each `kind` says where that directory is. On a panel, use the panel's own place for PHP settings, or it will overwrite yours.
- **Pin values for FPM** in the pool with `php_admin_flag[...]`, so `ini_set()`, `.user.ini` and per-site panel settings cannot undo them.
- **Docker images:** add the build guard from `templates/php/Dockerfile.snippet`. The build then **fails** if a value is still on or PHP is older than the fix.
- **Do not blindly use `php.ini-production`.** It changes `max_input_time`, `variables_order`, `zend.exception_ignore_args` and more. Set only what you mean.
- **mod_php:** if you can, move the site to PHP-FPM (`guides/web/apache.md`). mod_php runs PHP inside every Apache process, and php.net rated it the highest risk for PHP2Shell.
- **FPM pool sizing** (`templates/php/zz-pool.conf`):
  1. Measure per-worker memory from `/proc/<pid>/smaps_rollup`.
  2. Measure host RAM: `free -m`, plus `docker stats --no-stream` if Docker. Every app shares the box.
  3. Worst case `Σ pools (max_children × memory_limit)` should fit in RAM. The realistic case is `max_children × measured worker size`.
  4. Check that the database's `max_connections` covers all workers.
  5. Add `pm.max_requests` to bound leaks.

## §4 Framework config
- `APP_DEBUG=false` (Laravel) and `DEBUG=False` (Python) on every **internet-reachable** env, dev included. Debug pages leak code, paths and queries, and scanners collect them.
- **Python/FastAPI:** read what `DEBUG`/`APP_ENV` actually change, test in a throwaway container from the same image and env, then switch.
- Put API docs (`/docs`, `/openapi.json`) behind auth in production.
- **Applying env changes in Laravel (in Docker):**
  - **Non-DB value:** write the env file **in place**, run `php artisan config:cache`, then reload FPM with `php -r 'posix_kill(1, SIGUSR2);'`. opcache never re-reads the cached config.
  - **DB or connection value:** **recreate** the container (trap T3).
  - **Never `config:clear` / `optimize:clear`** where FPM cannot read the env file (trap T4).

## §5 Edge web server: limits and filters (every server with a public site)
**Measure first:**
- CDN or not (real client IPs in the logs?);
- peak requests per second per IP for signed-in users (an office behind one NAT puts many users on one IP);
- the biggest real request body per route;
- which routes take uploads;
- which webhook senders exist (payments, stores, mail providers).

**Then apply** the equivalent of the templates on the **live** web server. Exact syntax and where the files go are in `guides/web/<nginx|apache|caddy|litespeed>.md`; the nginx version is `templates/nginx/0.request_limits.conf` + `server-limits.inc`. What to set:
- header, body and send timeouts (they apply per read, so slow big uploads still work);
- a small default body size (2m), raised **only** on real upload routes;
- per-IP request and connection limits, with **separate buckets** for the app, static files and webhooks, and generous bursts. Webhook senders must never be throttled into failures;
- **400 for multipart with an empty or missing boundary.**

**Panels regenerate their own web-server files.** Put your rules where that panel's guide says they survive. Back up every file, test the config, then reload with the **live** binary (trap T1). Roll out on the least important site first.

**Prove it from outside:**
- a normal page burst gets all 200s;
- an aggressive burst gets some 429s;
- a big upload to a real upload route is **not** refused by the edge;
- a 20 MB POST to `/` gets 413;
- an empty boundary gets 400;
- a valid multipart POST reaches the app.

## §6 Inner proxy (Caddy) and logs (only if Caddy is used)
Use `templates/caddy/Caddyfile.snippet`:
- `header { defer; -X-Powered-By }`. Without `defer` it may not apply to fastcgi responses.
- `trusted_proxies static private_ranges` + `client_ip_headers X-Forwarded-For`, so the app sees **real client IPs**. Otherwise every per-IP rate limiter in the app is one shared bucket. **Tell the user**: it is a behaviour change.
- An access log to a **file on a named volume**, with roll settings, plus a global stdout logger. A second `log` block inside a site is silently dropped.
- 404 for FPM status and ping paths from outside.
- Never touch the lines forcing `X-Forwarded-Proto https` / `env HTTPS on`.
- **Prove** logs survive: count the log lines, `docker restart` the web container, send a request, count again.

## §7 Docker daemon and host
- **Docker: third-party registry mirror:** set `"registry-mirrors": []` **explicitly** (removing the key keeps the old value), run `systemctl reload docker` (no container restarts), then check `docker info | grep -A2 'Registry Mirrors'`.
- **Quick tunnels:** read the owners' notes, then `systemctl disable --now <unit>` (reversible) and check the old URL returns 530.
- **Docker: stop signals:** compare `docker inspect -f '{{.Config.StopSignal}}'` with PID 1's `SigIgn`/`SigCgt` in `/proc/<pid>/status`. php-fpm images use `SIGQUIT`, and a bash entrypoint ignores it (trap T2). Fix with `stop_signal: SIGTERM` + an early trap.
- **SSH and the control panel:** password/root login and a world-open panel are risks the user **may accept**. Record the decision; don't push.
- **Certificates:** check the expiry on every site. If a panel's renewal fails, read its log (trap T13).
- **OS updates:** is the OS still supported? Are security updates applied automatically (`unattended-upgrades`, `dnf-automatic`)? An end-of-life OS is a finding of its own.
