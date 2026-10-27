# PHP on Alpine Linux

Covers Alpine packages such as `php83`, `php84`, `php84-fpm` (`kind=distro` on Alpine), on a host or inside an image `FROM alpine`. For the official `php:*-alpine` image, read `docker-official-image.md` instead: that one is built from source, not from these packages.

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), test config before reload, staging before production, and ask the human before any production restart.

Fixed upstream: **8.5.12, 8.4.27, 8.3.36, 8.2.35**. 8.1 and older: no official release.

## 1. How to recognise it

```bash
cat /etc/alpine-release
apk info -vv 2>/dev/null | grep -E '^php[0-9]{2}(-fpm)?-[0-9]'
ls -d /etc/php[0-9]*                      # /etc/php84 ...
```

Paths for `php84` (swap the number for your version):

| What | Path |
|---|---|
| ini | `/etc/php84/php.ini`, extra files in `/etc/php84/conf.d/` |
| FPM | binary `/usr/sbin/php-fpm84`, pools in `/etc/php84/php-fpm.d/` |
| Service (OpenRC) | `php-fpm84` |

## 2. Is it patched?

```bash
apk policy php84-fpm          # installed and available versions
php-fpm84 -v
```

Alpine packages usually follow upstream versions, so `8.4.27` or higher is fixed. If the version is lower, check Alpine's security data for the CVE (`https://security.alpinelinux.org/`) (verify on your system).

**Is your Alpine branch still getting updates?** PHP lives in the `community` repository, which is supported for a shorter time than `main` (check the Alpine releases page). An old branch may never get the fix. Then move to a newer branch or to the official `php` image.

## 3. Patch it

On a host:

```bash
apk update
apk upgrade --simulate        # read what changes
apk upgrade
rc-service php-fpm84 restart  # ask first on production
```

In an image: rebuild with a fresh base and **no layer cache**, then recreate the container (see `docker-official-image.md`, section 3):

```bash
docker compose -p <proj> -f <file> build --pull --no-cache <svc>
```

Add a build guard to the Dockerfile:

```dockerfile
RUN php84 -r 'exit(version_compare(PHP_VERSION,"8.4.27",">=")?0:1);'
```

**Downtime:** about a second of 502 for an FPM restart; a few seconds for a container recreate.

## 4. If you cannot patch today

This reduces exposure. It does not make the server safe.

**ini file** `/etc/php84/conf.d/99-php2shell.ini`:

```ini
session.upload_progress.enabled = 0
post_max_size = 8M          ; 32M if the site takes uploads
upload_max_filesize = 6M    ; keep below post_max_size
memory_limit = -1           ; ONLY with a cgroup or container memory limit
; PHP 8.5 only:
; fatal_error_backtraces = 0
```

**FPM pool:** in each file in `/etc/php84/php-fpm.d/`, inside its `[name]` section:

```ini
php_admin_value[memory_limit] = -1
php_admin_flag[session.upload_progress.enabled] = off
php_admin_value[post_max_size] = 8M
php_admin_value[upload_max_filesize] = 6M
```

**Memory boundary:** in a container, set `mem_limit` on the service. Do not use `ulimit -v` or RLIMIT_AS / RLIMIT_DATA limits: those can trigger the bug.

**Apply:** `php-fpm84 -t`, then restart the service (or recreate the container).

## 5. Verify

- Container: `scripts/fpm_ini_probe.sh <container>` (needs `cgi-fcgi`; on Alpine the `fcgi` package (verify on your system)). The script calls `php-fpm`; on Alpine the binary is `php-fpm84`, so the pool dump at the end may fail. The ini values above it are what matter.
- Host: use a one-off probe page with a random name and delete it at once (the same probe as in `debian-ubuntu.md`, section 5). Do not use `phpinfo()`.
- Check that the FPM master started after the upgrade: `ps -o pid,etime,args | grep '[p]hp-fpm: master'`.

## 6. Traps on this stack

- **The CLI is `php84`, not `php`**, unless a `php` symlink was added. Scripts that call `php` may hit a different version.
- **musl, not glibc.** Some extensions behave differently. Test the app on staging after an upgrade.
- **Cached `apk add` layers** keep the old package in images. Use `--no-cache` when you rebuild.
- **BusyBox `ps`** has fewer columns than procps. Use `ps -o pid,etime,args`.

## Sources

- https://www.php.net/ (21 and 23 Oct 2026 advisories)
- https://security.alpinelinux.org/
- https://pkgs.alpinelinux.org/packages?name=php84*
