# PHP on cPanel & WHM (EasyApache 4)

Covers EasyApache 4 PHP (`ea-php74` … `ea-php85`, `kind=cpanel-ea`) and, at the end of each section, CloudLinux `alt-php`.

**cPanel owns this PHP.** Do not install distro PHP or edit generated pool files by hand. Use WHM, the package manager for `ea-php*`, and cPanel's YAML files.

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), test config before reload, staging before production, and ask the human before any production restart.

Fixed upstream: **8.5.12, 8.4.27, 8.3.36, 8.2.35**. 8.1 and older: no official release; cPanel and CloudLinux may ship backports.

## 1. How to recognise it

```bash
ls -d /opt/cpanel/ea-php*/root            # one per installed version
/usr/local/cpanel/bin/rebuild_phpconf --current   # handler per version (dso, cgi, fpm, lsapi ...)
whmapi1 php_get_vhost_versions | grep -E 'vhost|version|php_fpm' | head -40
ls -d /opt/alt/php*/ 2>/dev/null          # CloudLinux alt-php
```

| Path | What |
|---|---|
| `/opt/cpanel/ea-php83/root/etc/php.ini`, `php.d/` | ini for that version |
| `/opt/cpanel/ea-php83/root/etc/php-fpm.d/<domain>.conf` | **generated** per-domain pools. Do not edit. |
| `/var/cpanel/ApachePHPFPM/system_pool_defaults.yaml` | pool defaults for all domains (optional file) |
| `/var/cpanel/userdata/<user>/<domain>.php-fpm.yaml` | per-domain pool settings |

Handler `dso` means mod_php (via `ea-phpXY-php` in Apache): **highest risk**.

## 2. Is it patched?

```bash
for b in /opt/cpanel/ea-php*/root/usr/bin/php; do echo "$b: $($b -v | head -1)"; done
rpm -q --changelog ea-php83-php-cli | grep -E 'CVE-2026-10961[89]'   # do this for every installed ea-phpXY
```

- cPanel's own builds of 8.2–8.5 move to the fixed upstream versions.
- **CloudLinux rebuilds** of `ea-php*` and all `alt-php*` may keep the old version number. **The CVE line in the changelog is the proof.** An empty result means not fixed.
- `ea-php74/80/81`: only a changelog line proves a backport.
- cPanel's **own** PHP (the one the panel itself runs on) is updated by cPanel's own update, not by `ea-php*` (verify on your system against cPanel's advisory).

## 3. Patch it

```bash
dnf upgrade 'ea-php*'          # yum on older systems; on Ubuntu cPanel: apt-get install --only-upgrade <ea-php packages>
dnf upgrade 'alt-php*'         # CloudLinux only
/scripts/upcp                  # updates cPanel itself (and its own PHP); ask first, it takes a while
```

Or in WHM: **Software › EasyApache 4** and apply the updates.

Then restart PHP and Apache (ask first on production):

```bash
/usr/local/cpanel/scripts/restartsrv_apache_php_fpm
/usr/local/cpanel/scripts/restartsrv_httpd
```

With LiteSpeed in front, also restart its detached PHP processes (see `cyberpanel-openlitespeed.md`, section 3).

**Downtime:** short 502/503 bursts while FPM pools restart. Do staging or a low-traffic window first.

## 4. If you cannot patch today

This reduces exposure. It does not make the server safe.

**Global ini** for each version: WHM › **MultiPHP INI Editor** (editor mode), or a file you add in `/opt/cpanel/ea-php83/root/etc/php.d/` (verify on your system that cPanel does not overwrite it):

```ini
session.upload_progress.enabled = 0
post_max_size = 8M          ; 32M if sites take uploads
upload_max_filesize = 6M    ; keep below post_max_size
```

**FPM pools, for every domain:** `/var/cpanel/ApachePHPFPM/system_pool_defaults.yaml`, in cPanel's documented key format:

```yaml
---
php_admin_value_memory_limit: { name: 'php_admin_value[memory_limit]', value: -1 }
php_admin_value_session_upload_progress_enabled: { name: 'php_admin_value[session.upload_progress.enabled]', value: 0 }
```

cPanel's docs say dots and brackets in the key become underscores; the `name` is the real directive. The second line follows that pattern but is not copied from cPanel's docs, so check it appears in the generated `.conf` (verify on your system). Use `0`, not `off`: YAML may read a bare `off` as a boolean. Then rebuild and restart:

```bash
/usr/local/cpanel/scripts/php_fpm_config --rebuild
/usr/local/cpanel/scripts/restartsrv_apache_php_fpm
```

**Only set `memory_limit=-1` with a memory boundary** (cgroup limit; on CloudLinux, LVE limits). Never with RLIMIT_AS / RLIMIT_DATA style limits.

**Then check the generated pools** for finite overrides:
`grep -n 'memory_limit\|upload_progress' /opt/cpanel/ea-php*/root/etc/php-fpm.d/*.conf`

**mod_php (dso):** best fix is moving domains to PHP-FPM in WHM › MultiPHP Manager. Ask first: `php_value` lines in `.htaccess` will stop working.

## 5. Verify

- Every `ea-phpXY` FPM master started after the update:
  `for p in $(pgrep -f 'php-fpm: master'); do ps -o pid=,lstart=,args= -p "$p"; ls -l /proc/$p/exe; done` (`(deleted)` = old binary).
- Per site: a one-off probe page with a random name in the domain's docroot, owned by the site user, deleted at once. Print `PHP_VERSION` and the four ini values (same probe as `debian-ubuntu.md`, section 5). Do not use `phpinfo()`.

## 6. Traps on this stack

- **cPanel's per-domain MultiPHP INI Editor writes `.user.ini`** for FPM sites. `.user.ini` cannot carry the upload-progress fix, and it can put a finite `memory_limit` back. The pool `php_admin_*` wins.
- **Editing a domain's pool in MultiPHP Manager** stops system defaults applying to that domain. Check those domains' YAML.
- **Hand edits to `php-fpm.d/*.conf` vanish** on the next rebuild.
- **Many versions, many handlers.** One server can run 8.1 as dso and 8.3 as FPM. Patch every installed `ea-php`.
- **CloudLinux PHP Selector** sites run `alt-php`, not `ea-php`. Check both.

## Sources

- https://www.php.net/ (21 and 23 Oct 2026 advisories)
- https://docs.cpanel.net/knowledge-base/php-fpm/php-fpm-code-and-filesystem-layout-for-easyapache-4/
- https://docs.cpanel.net/knowledge-base/web-services/how-to-manage-your-php.ini-directives-with-php-fpm/
- https://docs.cpanel.net/knowledge-base/php-fpm/configuration-values-of-php-fpm
