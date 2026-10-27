# PHP on CyberPanel, OpenLiteSpeed and LiteSpeed (lsphp)

Covers LiteSpeed's PHP builds, `lsphp74` … `lsphp85`, installed under `/usr/local/lsws/lsphpXY/` (`kind=lsphp`). CyberPanel and plain OpenLiteSpeed use them; LiteSpeed Enterprise can too.

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), test config before reload, staging before production, and ask the human before any production restart.

Fixed upstream: **8.5.12, 8.4.27, 8.3.36, 8.2.35**. 8.1 and older: no official release.

## 1. How to recognise it

```bash
ls -d /usr/local/lsws/lsphp*/
for b in /usr/local/lsws/lsphp*/bin/php; do echo "$b: $($b -v | head -1)"; done
pgrep -a lsphp | head
ls -l /usr/local/lscp/fcgi-bin/lsphp 2>/dev/null     # CyberPanel's own copy for the panel
```

Find the ini files from the binary itself; the layout differs between Debian/Ubuntu and RHEL builds:

```bash
/usr/local/lsws/lsphp83/bin/php --ini
```

Typical results (verify on your system): `/usr/local/lsws/lsphp83/etc/php/8.3/litespeed/php.ini` with `mods-available/` on Debian/Ubuntu; `/usr/local/lsws/lsphp83/etc/php.ini` with `php.d/` on RHEL family.

## 2. Is it patched?

```bash
dpkg-query -W 'lsphp*' 2>/dev/null; rpm -qa 'lsphp*' 2>/dev/null
```

LiteSpeed's packages follow upstream versions (for example `8.3.36-1+<codename>`), so `8.3.36` or higher is fixed. For `lsphp74/80/81`, look for the CVE id in the package changelog; no line means not proven fixed.

**CyberPanel's own panel PHP** (`/usr/local/lscp/fcgi-bin/lsphp`) is a separate copy. It must be refreshed too. Compare it with the lsphp it was copied from:

```bash
sha256sum /usr/local/lscp/fcgi-bin/lsphp /usr/local/lsws/lsphp*/bin/lsphp
```

Do not assume which version the panel uses. CyberPanel's notice warns against blindly copying the 8.3 binary.

## 3. Patch it

```bash
# Debian/Ubuntu
apt-get update
PKGS=$(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 'lsphp*' | awk '$1=="ii"{print $2}')
apt-get -s install --only-upgrade $PKGS && apt-get install --only-upgrade $PKGS
# RHEL family
dnf upgrade 'lsphp*'
```

Refresh the panel copy only as CyberPanel's own instructions say for your version (verify on your system).

Then recycle **every** PHP process (ask first on production). A web-server reload alone can leave detached PHP workers alive:

```bash
systemctl restart lsws            # or: /usr/local/lsws/bin/lswsctrl restart
pkill lsphp                       # ends detached lsphp processes; they start again on demand
systemctl restart lscpd           # CyberPanel's own panel service
```

**Downtime:** a short gap while lsphp starts again. The first requests after the restart are slower.

## 4. If you cannot patch today

This reduces exposure. It does not make the server safe.

Add a file to the scan folder that `--ini` printed (for example `mods-available/` on Debian/Ubuntu or `php.d/` on RHEL), named `99-php2shell.ini`:

```ini
session.upload_progress.enabled = 0
post_max_size = 8M          ; 32M if the site takes uploads
upload_max_filesize = 6M    ; keep below post_max_size
; PHP 8.5 only:
; fatal_error_backtraces = 0
```

On Debian/Ubuntu builds, a file in `mods-available/` may only load if it is also linked into the SAPI's `conf.d`. Check it with the probe in section 5.

**Per-site overrides:** CyberPanel's per-site PHP editor, the vhost's **php.ini Override**, or `.htaccess` `php_value` (LiteSpeed Enterprise) can set values back. Search them:
`grep -rn 'upload_progress\|memory_limit\|post_max_size' /usr/local/lsws/conf/vhosts/ 2>/dev/null`

**`memory_limit = -1`: do not apply it here without a cgroup boundary.** LiteSpeed's external-app *Memory Soft/Hard Limit* are process resource limits (verify on your system). The PHP advisory says RLIMIT_AS / RLIMIT_DATA style limits can **cause** the vulnerable allocation failure. Do not tighten them as a "mitigation". Patch instead.

**Apply:** recycle all lsphp processes as in section 3.

## 5. Verify

- No lsphp process older than the change: `ps -o pid,lstart,args -C lsphp`. `ls -l /proc/<pid>/exe` must not end in `(deleted)`.
- Per site: a one-off probe page with a random name in the site's `public_html`, deleted at once (same probe as `debian-ubuntu.md`, section 5). `PHP_SAPI` should be `litespeed`. Do not use `phpinfo()`.
- CyberPanel: also check the panel and phpMyAdmin still work after the panel PHP refresh.

## 6. Traps on this stack

- **Detached mode:** lsphp processes outlive a web-server reload. Only `pkill lsphp` (or a full restart) proves they are new.
- **Two PHP copies:** site lsphp and the panel's `/usr/local/lscp/fcgi-bin/lsphp`. Patching one does not patch the other.
- **CLI `php` may not be lsphp.** `/usr/bin/php` can be a distro PHP. Check `/usr/local/lsws/lsphpXY/bin/php`.
- **Several lsphp versions.** Each vhost's external app chooses one. Patch all that sites use.
- **OpenLiteSpeed picks up `.htaccess` changes only after a restart**, and supports less of `.htaccess` than Apache (verify on your system which `php_value` lines it applies). Do not rely on `.htaccess` for the fix.

## Sources

- https://www.php.net/ (21 and 23 Oct 2026 advisories)
- https://cyberpanel.net/blog/php-security-october-2026-cyberpanel-response (panel PHP copy, recycling workers, settings placement)
- https://docs.litespeedtech.com/lsws/extapp/php/configuration/options/ (`pkill lsphp` to restart PHP)
- https://support.cpanel.net/hc/en-us/articles/1500003203541 (detached LSAPI processes keep old ini until restarted)
