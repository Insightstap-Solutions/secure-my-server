# PHP on Plesk

Covers PHP versions shipped by Plesk (`plesk-php74` … `plesk-php85`, installed under `/opt/plesk/php/X.Y/`, `kind=plesk`).

**Plesk owns this PHP.** Change settings through Plesk (server-wide, service plan or domain). Hand edits to generated pool files are lost.

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), test config before reload, staging before production, and ask the human before any production restart.

Fixed upstream: **8.5.12, 8.4.27, 8.3.36, 8.2.35**. 8.1 and older: no official release; Plesk may ship backports.

## 1. How to recognise it

```bash
ls -d /opt/plesk/php/*/
plesk bin php_handler --list                   # every handler: id, version, type
systemctl list-units --type=service 'plesk-php*'
```

| Path | What |
|---|---|
| `/opt/plesk/php/8.3/bin/php` | CLI for that version |
| `/opt/plesk/php/8.3/etc/php.ini` | server-wide ini for that version |
| `/opt/plesk/php/8.3/etc/php-fpm.d/<domain>.conf` | **generated** per-domain pool. Do not edit. |

Handler types you may see: *FPM application* (served by nginx or Apache), *FastCGI application*, and *Apache module* (mod_php: **highest risk**). A handler marked *OS vendor* uses the distro's PHP: patch that one with `debian-ubuntu.md` or `rhel-family.md`, and nothing else.

## 2. Is it patched?

```bash
for b in /opt/plesk/php/*/bin/php; do echo "$b: $($b -v | head -1)"; done
```

- 8.2–8.5: `8.3.36` (and so on) or higher is fixed.
- **7.4, 8.0, 8.1 keep their old version number** after a backport. Check the package changelog for the CVE id: `rpm -q --changelog plesk-php81 | grep CVE-2026-10961` on RPM systems; on Debian/Ubuntu look in `/usr/share/doc/plesk-php81*/` (verify on your system). No CVE line means not proven fixed.
- **The panel's own PHP engine (`sw-engine`) is separate.** Updating site PHP does not fix it. Plesk updates fix it. Check your Plesk version against Plesk's advisory (verify on your system).

## 3. Patch it

GUI: **Tools & Settings › Updates** (Plesk Installer), then update the installed PHP components and Plesk itself.

CLI (verify on your system first with `plesk installer --help`):

```bash
plesk installer --select-release-current --show-components     # what is installed
plesk installer --select-release-current --upgrade-installed-components
```

Then restart each PHP-FPM service and the web server (ask first on production):

```bash
systemctl restart plesk-php83-fpm        # one per version in use (names from section 1)
systemctl restart apache2                # or httpd; needed for "Apache module" handlers
```

**Downtime:** short 502s per FPM restart. Staging or a quiet window first.

## 4. If you cannot patch today

This reduces exposure. It does not make the server safe.

**Server-wide**, for each version: **Tools & Settings › PHP Settings › (version) › php.ini**, or edit `/opt/plesk/php/8.3/etc/php.ini` directly:

```ini
session.upload_progress.enabled = 0
post_max_size = 8M          ; 32M if sites take uploads
upload_max_filesize = 6M    ; keep below post_max_size
; PHP 8.5 only:
; fatal_error_backtraces = 0
```

**Domain settings override `php.ini`.** So:

1. Check the generated pools for overrides:
   `grep -rn 'memory_limit\|post_max_size\|upload_progress' /opt/plesk/php/*/etc/php-fpm.d/`
2. Fix them where Plesk stores them: **Service Plans › (plan) › PHP Settings**, then **Update & Sync**, or per domain in **PHP Settings**. Admins also have an **Additional configuration directives** field there.

**`memory_limit = -1`:** only with a cgroup memory limit on the PHP services (for example systemd `MemoryMax=` via `systemctl edit plesk-php83-fpm` (verify on your system)). Never with RLIMIT_AS / RLIMIT_DATA limits. Without a boundary, leave `memory_limit` as it is and rely on patching.

**Apply:** restart each `plesk-phpXY-fpm` and the web server, as in section 3. Add web limits (`guides/web/nginx.md`, `apache.md`): Plesk has its own "Additional nginx directives" per domain for that.

**Apache module handler:** move those domains to an *FPM application* handler. Ask first: `.htaccess` `php_value` lines then stop working.

## 5. Verify

- FPM masters started after the update; `(deleted)` means old code still runs:
  `for p in $(pgrep -f 'php-fpm: master'); do ps -o pid=,lstart=,args= -p "$p"; ls -l /proc/$p/exe; done`
- Per site: a one-off probe page with a random name in the domain's docroot (owned by the domain's system user), deleted at once. Print `PHP_VERSION` and the ini values (same probe as `debian-ubuntu.md`, section 5). Do not use `phpinfo()`.
- Plesk shows each handler's version under **Tools & Settings › PHP Settings**.

## 6. Traps on this stack

- **Per-domain and plan settings win** over the server `php.ini`. A global fix can be undone on exactly the sites that matter.
- **`plesk repair web`** regenerates config for every site. It is heavy; do not run it as a casual "apply".
- **Several handlers per version** (FPM by nginx, FPM by Apache, FastCGI). Check each one sites actually use.
- **OS vendor handlers** follow the distro, not Plesk. Do not "fix" them through Plesk.
- **`sw-engine`** is not covered by site PHP updates.

## Sources

- https://www.php.net/ (21 and 23 Oct 2026 advisories)
- https://support.plesk.com/hc/en-us/articles/12377519572887-How-to-customize-PHP-settings-in-Plesk (php.ini path, per-domain overrides, additional directives)
- https://support.plesk.com/hc/en-us/articles/12377588327063-How-to-apply-PHP-FPM-pool-settings-for-all-domains-in-Plesk (service plans, Update & Sync)
- https://support.plesk.com/hc/en-us/articles/12377523222679 (`plesk installer --select-release-current --show-components`)
- https://docs.plesk.com/en-US/obsidian/cli-linux/ (`php_handler` utility)
