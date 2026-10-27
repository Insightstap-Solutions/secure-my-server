# PHP on aaPanel

Covers PHP that aaPanel installs under `/www/server/php/XY/` (`kind=aapanel`). aaPanel compiles PHP itself; it is not a distro package.

**aaPanel owns this PHP.** Do not `apt`/`dnf` install another PHP to "fix" it. Use the panel, or files the panel does not regenerate.

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), test config before reload, staging before production, and ask the human before any production restart.

Fixed upstream: **8.5.12, 8.4.27, 8.3.36, 8.2.35**. 8.1 and older: no official release.

## 1. How to recognise it

```bash
ls /www/server/php/                       # 74 80 81 82 83 ... one folder per version
for v in /www/server/php/*/; do echo "$v: $(${v}bin/php -v | head -1)"; done
ls /etc/init.d/ | grep php-fpm            # php-fpm-83 and so on
```

| Path (for 8.3, folder `83`) | What |
|---|---|
| `/www/server/php/83/sbin/php-fpm` | FPM binary |
| `/www/server/php/83/etc/php.ini` | ini for FPM |
| `/www/server/php/83/etc/php-fpm.conf` | FPM config **and** the pool (`[www]`) in one file |
| `/etc/init.d/php-fpm-83` | service script |

Which site uses which version: the site's nginx vhost (`/www/server/panel/vhost/nginx/<site>.conf`) includes `enable-php-83.conf`.

## 2. Is it patched?

```bash
/www/server/php/83/sbin/php-fpm -v
```

aaPanel builds upstream source, so the version number is the answer: `8.3.36` or higher is fixed. For 7.4/8.0/8.1 there is no fixed upstream release; only a rebuild from the backport branch would fix it (see `source-built.md`), and the panel does not do that for you.

## 3. Patch it

1. **Panel:** App Store › PHP-8.3 › Setting, and use its update / version option. It re-compiles PHP, which takes a while and loads the CPU (verify on your system that it offers the fixed version).
2. **If the panel does not offer the fixed version yet,** do not hand-build into `/www/server/php/83/`. Use section 4 now, and either wait for aaPanel or move sites to another fixed version that the panel offers (8.4 or 8.3, after testing).
3. **Before you start:** copy the folder for rollback: `cp -a /www/server/php/83 /www/server/php/83.bak-$(date +%Y%m%d)`. Note the extensions you have (`/www/server/php/83/bin/php -m`); check they are back afterwards.
4. **Restart** (ask first on production): `/etc/init.d/php-fpm-83 restart`.

**Downtime:** sites on that version return 502 while FPM restarts. During a re-compile the old FPM normally keeps serving, but plan a quiet window.

## 4. If you cannot patch today

This reduces exposure. It does not make the server safe.

**ini:** add to the end of `/www/server/php/83/etc/php.ini` (or use the panel's PHP › Setting › config file editor, which edits the same file):

```ini
session.upload_progress.enabled = 0
post_max_size = 8M          ; 32M if the site takes uploads
upload_max_filesize = 6M    ; keep below post_max_size
; PHP 8.5 only:
; fatal_error_backtraces = 0
```

Remove any earlier line that sets the same key: the last one wins, and the panel's "upload limit" box rewrites `post_max_size`/`upload_max_filesize` in place.

**Pool:** at the end of the `[www]` section in `/www/server/php/83/etc/php-fpm.conf`:

```ini
php_admin_flag[session.upload_progress.enabled] = off
php_admin_value[post_max_size] = 8M
php_admin_value[upload_max_filesize] = 6M
```

`memory_limit = -1` (as `php_admin_value`) only with a cgroup memory limit on this FPM, which the init script does not give you. Without one, leave `memory_limit` alone.

**Apply:**

```bash
/www/server/php/83/sbin/php-fpm -t -y /www/server/php/83/etc/php-fpm.conf
/etc/init.d/php-fpm-83 restart
```

Request limits go in aaPanel's nginx: see `guides/web/nginx.md` and the two-nginx trap below.

## 5. Verify

- The FPM master started after the change, and runs the right binary:
  `for p in $(pgrep -f 'php-fpm: master'); do ps -o pid=,lstart=,args= -p "$p"; ls -l /proc/$p/exe; done`
- Per site: a one-off probe page with a random name in the site root, deleted at once (same probe as `debian-ubuntu.md`, section 5). Do not use `phpinfo()`.
- `/www/server/php/83/bin/php -i` shows the CLI only. aaPanel's CLI may read a different ini file than FPM (verify on your system with `php --ini` and the probe).

## 6. Traps on this stack

- **Two nginx binaries.** aaPanel's nginx is `/www/server/nginx/sbin/nginx`. A distro nginx may also be installed. A bare `nginx -t` tests the wrong one. Always use the full path and `-c /www/server/nginx/conf/nginx.conf`. After a reboot, check who owns :80/:443 (`ss -ltnp | grep -E ':(80|443) '`).
- **The panel rewrites `php-fpm.conf`** when you change "Performance tuning" for that PHP. Re-check your pool lines after any panel change.
- **phpMyAdmin from aaPanel** runs on one of these PHP versions too. Patch that version.
- **A re-compile can drop extensions** you added by hand (ionCube, Redis ...). Check `php -m` before and after.
- **Several versions in use.** Each site's `enable-php-XY.conf` decides. Patch every version a site uses.

## Sources

- https://www.php.net/ (21 and 23 Oct 2026 advisories)
- https://www.aapanel.com/docs/ (panel documentation)
- https://azdigi.com/en/blog/aapanel/change-the-php-version-on-aapanel (multiple versions under `/www/server/php`; third-party)
