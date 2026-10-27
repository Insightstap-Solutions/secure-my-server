# Phase 1: Inventory (read-only)

Goal: know **how this server is built**, everything that runs, what the internet can reach, where the secrets are, and how each app reaches production. Change nothing in this phase.

## 0. Let the detectors go first
```bash
ssh <host> 'sudo -n bash -s' < "${CLAUDE_PLUGIN_ROOT}/scripts/detect_stack.sh"
ssh <host> 'sudo -n bash -s' < "${CLAUDE_PLUGIN_ROOT}/scripts/php_runtimes.sh"    # if any PHP
```
Write down:
- the OS and version (End of life? Then say so: no more security updates);
- the **control panel**, if any;
- the **live** web server (the process that really owns :80/:443);
- every PHP runtime (`kind`, SAPI, version, STATUS);
- Docker or not;
- the firewall tool;
- every public listener.

Then open the matching guides from `${CLAUDE_PLUGIN_ROOT}/guides/README.md`. Everything below is the part that is the same on every server.

If `sudo -n` fails, run without sudo, say which checks could not run, and ask the user for access rather than guessing.

## 1. What the internet can reach
```bash
sudo ss -ltnup                                 # 0.0.0.0 / [::] = reachable unless a firewall says otherwise
ip -br addr                                    # is there a public IPv6? People forget it.
```
- **List every public listener, for every project,** even ones you will not change. The user decides.
- **Databases and caches** (3306, 5432, 6379, 27017, 9200, 11211) and **PHP-FPM** (9000) should never be public.
- **The detector cannot prove reachability.** A firewall, a cloud security group or the provider's network may block a port. Check from **outside** (another machine): `nc -zvw3 <ip> <port>` or `nmap -Pn -p <ports> <ip>`, on IPv4 and IPv6.

**Docker hosts:**
- A published port (`-p 5432:5432`) goes through `nat PREROUTING` and `FORWARD`. It **never reaches ufw's or firewalld's INPUT rules**, so `ufw deny 5432` does nothing for it (`guides/firewall/docker.md`).
- Read where each container came from:
  ```bash
  docker ps -a --format '{{.Names}}\t{{.Ports}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}'
  ```

## 2. Web servers and sites
- **More than one copy of a web server** (a panel's nginx and the distro's): write down which one is live. A bare `nginx -t` may test the other one (trap T1).
- **For each site, note:**
  - the domain;
  - the document root, or the upstream it proxies to (loopback or public?);
  - the body size limit;
  - the certificate expiry:
    ```bash
    echo | openssl s_client -connect <domain>:443 -servername <domain> 2>/dev/null | openssl x509 -noout -dates
    ```
- **Look for other paths in:**
  - tunnels (`cloudflared`, `ngrok`), other proxies;
  - the panel's own port;
  - phpMyAdmin/Adminer pages;
  - old sites still answering on the IP.

## 3. Env files and secret copies
```bash
sudo find /home /root /opt /srv /var/www /www/wwwroot -maxdepth 6 \
  \( -name '.env' -o -name '.env.*' -o -name '*.env' -o -name 'wp-config.php' -o -name 'settings.py' -o -name 'config.php' \) \
  -type f 2>/dev/null | grep -vE 'node_modules|/vendor/'
```
Sort the results into:
- **live** files (the ones the apps or containers actually use);
- **backups** (`*.bak*`, `*.old`, `*.predeploy*`);
- **examples**;
- **old checkouts** and copies.

Backups and old copies are **secret copies too**. List them for Phase 5.

Check for a UTF-8 BOM with `head -c3 f | od -An -tx1` (it shows `ef bb bf`). It breaks `docker compose --env-file` and hides the first key from `grep '^KEY='` (trap T16).

## 4. Runtimes
- **PHP:** `php_runtimes.sh` reads versions and settings from the **web** SAPI. `php -v` on the command line can be a different PHP from the one serving the site (trap T26).
- **Others:** note the Node, Python, Java and database versions too, and whether each is still supported.

## 5. How each app reaches production
**Read every deploy script:**
- `/usr/local/bin/*deploy*`, `deploy*.sh`;
- `.github/workflows/*`, `.gitlab-ci.yml`, Makefiles;
- panel "git deploy" hooks.

For each one, record:
- the source (branch or folder);
- the copy method (`rsync --delete`? with which excludes?);
- the build or restart command;
- the reload command (which web-server binary?);
- whether it overwrites config or env files.

You need this in Phase 6.

## 6. Other people and recent changes
- **Running deploys:** `ps -eo etime,cmd | grep -E 'docker[ -]compose|deploy|rsync'`.
- **Who else is logged in:** `who`, `last -n 20`.
- **Recent restarts:** `docker ps --format '{{.Names}}\t{{.Status}}'`, `systemctl list-units --state=activating,failed`.

If someone else is mid-deploy, wait or coordinate.

## Output of this phase
- A table of projects → environments → runtime (kind, version) → public ports → config/env files → deploy method.
- The list of anything surprising, for the user.
