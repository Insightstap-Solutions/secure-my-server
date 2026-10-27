# PHP on DirectAdmin (CustomBuild)

Covers PHP that DirectAdmin's CustomBuild compiles into `/usr/local/phpXY/` (`kind=directadmin`). Up to four versions run side by side, in "slots" `php1` … `php4`.

**DirectAdmin owns this PHP.** Use CustomBuild (`da build …`) and its custom folders. Hand edits to generated files are lost.

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), test config before reload, staging before production, and ask the human before any production restart.

Fixed upstream: **8.5.12, 8.4.27, 8.3.36, 8.2.35**. 8.1 and older: no official release; CustomBuild may add backport patches.

## 1. How to recognise it

```bash
grep -E '^php[1-4]_(release|mode)=' /usr/local/directadmin/custombuild/options.conf
ls -d /usr/local/php[0-9]*/
systemctl list-units --type=service 'php-fpm*'
```

| Path (for 8.3) | What |
|---|---|
| `/usr/local/php83/bin/php` | CLI |
| `/usr/local/php83/lib/php.ini` | main ini |
| `/usr/local/php83/lib/php.conf.d/` | extra ini files; yours survive (for example `11-custom.ini`) |
| `/usr/local/php83/etc/php-fpm.d/` | **generated** per-user pools (verify on your system) |
| `php-fpm83` | systemd service for that slot |

`phpN_mode` tells the handler: `php-fpm`, `lsphp` (LiteSpeed), `fastcgi`, or `mod_php` (**highest risk**).

## 2. Is it patched?

```bash
da update                    # updates DirectAdmin and CustomBuild's version list
da build versions            # shows available updates per slot
for b in /usr/local/php*/bin/php; do echo "$b: $($b -v | head -1)"; done
```

- 8.2–8.5: `8.3.36` (and so on) or higher is fixed.
- 8.1 and older: an asterisk in `da build versions` (for example `8.1.34*`) means **same version, new patches**. A version number cannot prove the fix. Check that the build date in `php -v` is after the patch, and that CustomBuild's patch folder holds the CVE patch: `ls /usr/local/directadmin/custombuild/patches/php-8.1/ | grep -i cve-2026` (verify on your system).

## 3. Patch it

```bash
cp -a /usr/local/php83 /usr/local/php83.bak-$(date +%Y%m%d)    # rollback copy, per slot you rebuild
da build php 2>&1 | tee /root/build-php-$(date +%Y%m%d).log    # rebuilds every configured slot
grep -E 'FAILED|failed to apply' /root/build-php-*.log          # must print nothing
```

- Rebuilding one slot at a time is possible (`da build php 8.3` (verify on your system)); do the least-used slot first.
- Compiling takes 10–30 minutes per version. CustomBuild restarts the FPM service itself; check it (section 5).
- On older installs the same commands are `cd /usr/local/directadmin/custombuild && ./build update && ./build php`.
- Ask before running on production. Staging first if you have one.

**Rollback:** `systemctl stop php-fpm83`, swap the folder back, `systemctl start php-fpm83`.

## 4. If you cannot patch today

This reduces exposure. It does not make the server safe.

**ini, all slots:** create `/usr/local/php83/lib/php.conf.d/11-php2shell.ini` (repeat per version):

```ini
session.upload_progress.enabled = 0
post_max_size = 8M          ; 32M if sites take uploads
upload_max_filesize = 6M    ; keep below post_max_size
; PHP 8.5 only:
; fatal_error_backtraces = 0
```

**Pool `php_admin_*`** (so apps cannot override): pools are generated from templates. Put your change in a **custom** template copy under `/usr/local/directadmin/custombuild/custom/` (verify on your system the exact sub-folder for php-fpm templates), then run `da build rewrite_confs`. Never edit `php-fpm.d/*.conf` directly. Check the result:
`grep -rn 'memory_limit\|upload_progress' /usr/local/php*/etc/php-fpm.d/`

**`memory_limit = -1`:** only together with a cgroup memory limit on `php-fpmXY` (for example `systemctl edit php-fpm83` with `MemoryMax=`). Never with RLIMIT_AS / RLIMIT_DATA. Without a boundary, leave it.

**Apply:** `systemctl restart php-fpm83` (each slot). For `mod_php` mode, restart Apache (`systemctl restart httpd`).

**mod_php mode:** switch the slot to `php-fpm` (`da build set php1_mode php-fpm`, then `da build php` and `da build rewrite_confs` (verify on your system)). Ask first; `.htaccess` `php_value` lines stop working.

## 5. Verify

- FPM master per slot started after the build; `(deleted)` means old code:
  `for p in $(pgrep -f 'php-fpm: master'); do ps -o pid=,lstart=,args= -p "$p"; ls -l /proc/$p/exe; done`
- `da build versions` shows no pending PHP update.
- Per site: a one-off probe page with a random name in `public_html`, owned by the user, deleted at once (same probe as `debian-ubuntu.md`, section 5). Do not use `phpinfo()`.

## 6. Traps on this stack

- **`/usr/local/bin/php` is one slot only** (usually `php1`). Check every `/usr/local/phpXY/bin/php`.
- **Per-domain FastCGI ini** (`/usr/local/directadmin/data/users/<user>/php/<domain>.ini`) **replaces** the global one. A fix in `php.conf.d` may not reach that domain.
- **Per-host sections** (`[HOST=…]`, `[PATH=…]` in `php.conf.d`) can set values back.
- **A failed patch hunk** can still end in "Installed". Read the build log.
- **ionCube and OPcache** must load after the rebuild (`php -m`).

## Sources

- https://www.php.net/ (21 and 23 Oct 2026 advisories)
- https://docs.directadmin.com/webservices/php/php-options.html (php.ini path, `php.conf.d`, per-domain ini, `da build rewrite_confs`)
- https://docs.directadmin.com/ (CustomBuild)
- https://computingforgeeks.com/patch-php2shell-directadmin/ (`da build versions` asterisk, rebuild log check, rollback; third-party)
