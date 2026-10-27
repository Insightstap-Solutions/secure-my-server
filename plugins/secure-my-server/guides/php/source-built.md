# PHP built from source (by hand, phpbrew, php-build and similar)

Covers PHP compiled on the box (`kind=source`): usually under `/usr/local`, `/opt/php-*`, or a per-user folder from phpbrew, php-build or asdf.

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), test config before reload, staging before production, and ask the human before any production restart.

Fixed upstream: **8.5.12, 8.4.27, 8.3.36, 8.2.35**. 8.1 and older: no official release; the PHP project published **source-only backport branches** for 7.4, 8.0 and 8.1.

## 1. How to recognise it

```bash
for p in $(pgrep -f 'php-fpm: master'); do readlink -f /proc/$p/exe; done   # which binary really runs
<that-binary> -v
<that-binary> -i | grep -E 'Loaded Configuration File|Scan this dir'
dirname "$(dirname <that-binary>)"/bin/php-config --configure-options       # how it was built
```

Not owned by any package: `dpkg -S <binary>` or `rpm -qf <binary>` finds nothing. Look also for the service unit or init script that starts it (`systemctl cat <service>`).

## 2. Is it patched?

The version is the answer for 8.2–8.5: `8.3.36` or higher is fixed.

For 7.4, 8.0 and 8.1 the version does not change. You must know **which source tree** it was built from. Without notes from whoever built it, treat it as not fixed.

## 3. Patch it

**Build into a new folder. Keep the old one for rollback.**

1. Save the old build options: `php-config --configure-options > /root/php-configure-$(date +%Y%m%d).txt`.
2. Get the source.
   - **8.2–8.5:** the release tarball from php.net, with its checksum checked against the downloads page.
   - **7.4 / 8.0 / 8.1:** the backport branch. Check it exists first:
     ```bash
     git ls-remote https://github.com/php/php-src 'refs/heads/PHP-*-CVE-2026-109618-109619'
     git clone --depth 1 --branch PHP-8.1-CVE-2026-109618-109619 https://github.com/php/php-src.git php-src-8.1-cve
     cd php-src-8.1-cve && ./buildconf --force     # a git checkout needs this; a release tarball does not
     ```
3. Build with the **same options**, but a **new prefix**:
   ```bash
   ./configure --prefix=/opt/php-8.3.36 <the old options, minus the old --prefix>
   make -j"$(nproc)"
   make install
   /opt/php-8.3.36/bin/php -v && /opt/php-8.3.36/bin/php -m    # compare -m with the old build
   ```
   If the old build used `--with-config-file-path`/`--with-config-file-scan-dir`, keep them so it reads the same ini. Rebuild PECL extensions (`phpize`) against the new build.
4. Point the service at the new binary (edit the unit or the symlink your setup uses), then on staging:
   ```bash
   /opt/php-8.3.36/sbin/php-fpm -t -y <your php-fpm.conf>
   systemctl daemon-reload && systemctl restart <php-fpm service>
   ```
5. Production only after staging works, and after the human says yes.

**Rollback:** point the unit or symlink back to the old folder and restart.

**phpbrew / php-build / asdf:** use the tool to install the fixed version beside the old one (for example `phpbrew install 8.3.36 +default +fpm` (verify on your system)), then switch the service to it. These tools build release tarballs; for the 7.4/8.0/8.1 branches, build by hand as above.

**Downtime:** only the restart (about a second of 502). The build itself does not touch the running PHP.

## 4. If you cannot patch today

This reduces exposure. It does not make the server safe.

Add an ini file in the **scan dir** that `-i` printed (or the end of the loaded `php.ini` if there is no scan dir):

```ini
session.upload_progress.enabled = 0
post_max_size = 8M          ; 32M if the site takes uploads
upload_max_filesize = 6M    ; keep below post_max_size
memory_limit = -1           ; ONLY with a cgroup memory limit
; PHP 8.5 only:
; fatal_error_backtraces = 0
```

And in **each** FPM pool section:

```ini
php_admin_value[memory_limit] = -1
php_admin_flag[session.upload_progress.enabled] = off
php_admin_value[post_max_size] = 8M
php_admin_value[upload_max_filesize] = 6M
```

Memory boundary: `MemoryMax=` on the service (`systemctl edit <service>`). Not `LimitAS=`/`LimitDATA=`. Then `php-fpm -t` and restart.

## 5. Verify

- The running master is the new binary and started after the change:
  `for p in $(pgrep -f 'php-fpm: master'); do ps -o pid=,lstart= -p $p; readlink -f /proc/$p/exe; done`
- A one-off probe page with a random name, deleted at once (same probe as `debian-ubuntu.md`, section 5). Do not use `phpinfo()`.
- For a backport build, record in the server notes: branch name, commit id (`git rev-parse HEAD`), build date, prefix.

## 6. Traps on this stack

- **`php` on `$PATH` is not what FPM runs.** Always start from `/proc/<pid>/exe`.
- **Missing extensions** after a rebuild break the app quietly. Compare `php -m` old vs new.
- **Building in the live prefix** (`make install` over the running one) leaves no rollback. Never do it.
- **OPcache file cache** (`opcache.file_cache`) from the old build can confuse the new one. Clear that folder if it is set.
- **Nobody updates this PHP for you.** Write down how it was built, so the next fix is faster.

## Sources

- https://www.php.net/ (21 and 23 Oct 2026 advisories, backport branches)
- https://www.php.net/downloads.php
- https://github.com/php/php-src (branches `PHP-7.4-CVE-2026-109618-109619`, `PHP-8.0-…`, `PHP-8.1-…`)
- https://www.php.net/manual/en/install.unix.php
