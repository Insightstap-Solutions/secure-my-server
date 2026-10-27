# PHP on RHEL, AlmaLinux, Rocky and CentOS (AppStream or Remi)

Covers PHP from the OS AppStream (`kind=distro`) and from the Remi repository (`kind=remi`).

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), test config before reload, staging before production, and ask the human before any production restart.

Fixed upstream: **8.5.12, 8.4.27, 8.3.36, 8.2.35**. 8.1 and older: no official release.

## 1. How to recognise it

```bash
cat /etc/os-release
rpm -qa 'php*' | sort                     # AppStream or Remi "single version"
rpm -qa 'php[0-9][0-9]-php*' | sort       # Remi parallel installs (php83-php-fpm ...)
dnf module list php 2>/dev/null           # [e] = enabled stream
systemctl list-units --type=service '*php*fpm*'
```

| What you see | Kind | Config |
|---|---|---|
| `php-fpm` from `appstream` | distro | `/etc/php.ini`, `/etc/php.d/`, pools in `/etc/php-fpm.d/`, service `php-fpm` |
| `php-fpm` with `remi` in the release, stream `php:remi-8.x` | remi (single) | same paths as distro |
| `php83-php-fpm` | remi (parallel, "SCL") | binaries under `/opt/remi/php83/root/`; config under `/etc/opt/remi/php83/` (verify with `php83 --ini`); service `php83-php-fpm` |

## 2. Is it patched?

| Source | How to decide |
|---|---|
| **Remi** | Upstream versions. `8.3.36` or higher is fixed. |
| **AppStream** (RHEL and rebuilds) | Red Hat backports. The version stays old. **Look for the CVE id.** |

```bash
rpm -q --changelog php-fpm | grep -E 'CVE-2026-10961[89]'
rpm -q --changelog php83-php-fpm | grep -E 'CVE-2026-10961[89]'      # Remi parallel
dnf updateinfo list --cve CVE-2026-109618                            # pending fix? (verify on Alma/Rocky)
```

Red Hat's page: `https://access.redhat.com/security/cve/CVE-2026-109618`. Alma and Rocky publish their own errata.

**Is your stream still supported?** (Red Hat life cycle page)

| Release | PHP streams still supported |
|---|---|
| RHEL 8 | 7.4 (full life of RHEL 8), 8.2 (to May 2029). **7.2, 7.3, 8.0 are retired.** |
| RHEL 9 | 8.0 (full life), 8.2 and 8.3 (to May 2029). **8.1 retired May 2025.** |
| RHEL 10 | 8.3 (full life), 8.4 (to May 2029) |

A retired stream gets no fix. Switch to a supported stream (test the app first).

**CentOS 7 / EL7 and CentOS Stream 8 are end of life.** No free fixes. Plan a migration. Until then use section 4 and ask the human about paid extended support.

## 3. Patch it

```bash
dnf check-update 'php*'
dnf upgrade 'php*'                         # AppStream or Remi single
dnf upgrade 'php83-php*'                   # Remi parallel, per version
```

Switching to a newer stream (only after testing the app):

```bash
dnf module reset php
dnf module enable php:8.2                  # or php:remi-8.3 with Remi
dnf distro-sync 'php*'
```

Restart every PHP that serves the web (ask first on production):

```bash
systemctl restart php-fpm                  # or php83-php-fpm
systemctl restart httpd                    # if mod_php is loaded (httpd -M | grep php)
```

**Downtime:** about a second of 502 per restart. Staging first.

## 4. If you cannot patch today

This reduces exposure. It does not make the server safe.

**ini file** `/etc/php.d/99-php2shell.ini` (Remi parallel: `/etc/opt/remi/php83/php.d/`):

```ini
session.upload_progress.enabled = 0
post_max_size = 8M          ; 32M if the site takes uploads
upload_max_filesize = 6M    ; keep below post_max_size
memory_limit = -1           ; ONLY with a cgroup memory limit, see below
; PHP 8.5 only:
; fatal_error_backtraces = 0
```

**FPM pool:** in **each** file in `/etc/php-fpm.d/*.conf`, inside its `[name]` section:

```ini
php_admin_value[memory_limit] = -1
php_admin_flag[session.upload_progress.enabled] = off
php_admin_value[post_max_size] = 8M
php_admin_value[upload_max_filesize] = 6M
```

The stock `www.conf` already sets some `php_value[...]` lines. Check that nothing sets a finite `memory_limit` back: `grep -rn 'memory_limit\|upload_progress' /etc/php-fpm.d/`.

**Memory boundary:** `systemctl edit php-fpm`, add `[Service]` and `MemoryMax=2G`. Do **not** use `LimitAS=` or `LimitDATA=` (`systemctl show php-fpm -p LimitAS -p LimitDATA` should say `infinity`).

**Apply:** `php-fpm -t`, then `systemctl restart php-fpm`. Add web limits from `guides/web/`.

## 5. Verify

```bash
for p in $(pgrep -f 'php-fpm: master'); do ps -o pid=,lstart=,args= -p "$p"; ls -l "/proc/$p/exe"; done
rpm -q --last php-fpm                       # install time; the master must start after it
```

`(deleted)` after the exe path means the old binary still runs.

Read values from FPM with a one-off probe page with a random name. Delete it at once. Do not use `phpinfo()`, which can show secrets.

```bash
D=/var/www/html; N="probe-$(openssl rand -hex 12).php"
cat > "$D/$N" <<'PHP'
<?php header('Content-Type: text/plain'); echo PHP_VERSION, ' ', PHP_SAPI, "\n";
foreach (['memory_limit','post_max_size','upload_max_filesize','session.upload_progress.enabled','fatal_error_backtraces'] as $k)
  echo $k, ' = ', var_export(ini_get($k), true), "\n";
PHP
curl -s "https://<domain>/$N"; rm -f "$D/$N"
```

On AppStream, `PHP_VERSION` keeps the old number. The changelog check is the proof.

## 6. Traps on this stack

- **SELinux:** a new file in `/etc/php.d/` or the docroot may need the right label. `restorecon -v <file>` after copying.
- **Remi parallel config is not under `/etc/php.d/`.** Edit the right tree for each version.
- **The CLI may be a different version** from FPM (`php` vs `php83`). Check the FPM binary.
- **A retired module stream** shows no updates, which looks like "nothing to do". It is not.
- **httpd uses FPM by default since RHEL 8.** If `httpd -M` shows `php_module` / `php7_module`, someone enabled mod_php: highest risk.

## Sources

- https://www.php.net/ (21 and 23 Oct 2026 advisories)
- https://access.redhat.com/support/policy/updates/rhel-app-streams-life-cycle (PHP stream dates)
- https://access.redhat.com/security/security-updates/cve
- https://blog.remirepo.net/pages/English-FAQ (SCL packages under `/opt/remi`, module streams)
