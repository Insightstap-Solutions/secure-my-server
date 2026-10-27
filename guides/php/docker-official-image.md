# PHP in Docker images

Covers the official `php` image (`php:8.4-fpm`, `php:8.4-apache`, `php:8.4-cli`, `-alpine` variants) and custom images that install distro PHP (Debian `php8.x-fpm`, Alpine `php84`).

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), test config before reload, staging before production, and ask the human before any production recreate.

Fixed upstream: **8.5.12, 8.4.27, 8.3.36, 8.2.35**. 8.1 and older: no official release.

## 1. How to recognise it

`scripts/php_runtimes.sh` prints `kind=docker` for a PHP runtime inside a container.

```bash
docker ps --format '{{.Names}}\t{{.Image}}'
docker exec <c> printenv PHP_VERSION PHP_INI_DIR   # set only by the official image
grep -n '^FROM' Dockerfile* docker/*/Dockerfile* 2>/dev/null
```

| The `FROM` line | What it means |
|---|---|
| `php:8.x-fpm…` | Official image. PHP is built into `/usr/local`. ini in `/usr/local/etc/php/conf.d/`, pools in `/usr/local/etc/php-fpm.d/`. |
| `php:8.x-apache…` | Official image with **mod_php inside Apache**. Highest risk. Consider moving to `-fpm` plus a web server. |
| `php:8.x-cli…` | No web SAPI. Patch it anyway if it runs anything web-facing (for example `php -S`). |
| `debian`/`ubuntu` + `apt-get install php8.x-fpm` | Distro PHP. Paths and the "is it patched" check are in `debian-ubuntu.md`. |
| `alpine` + `apk add php84-fpm` | Distro PHP. Paths are in `alpine.md`. |
| `dunglas/frankenphp` or similar | Read `frankenphp.md` instead. |

## 2. Is it patched?

```bash
docker exec <c> php-fpm -v      # or: php -v (same build in the official image)
```

- **Official image:** it ships upstream versions, with no backports. The version number is the answer.
- **The official 8.1 and older tags no longer get PHP releases.** (Check on Docker Hub whether your tag still moves.)
- **Distro PHP inside the image:** the version can stay old after a backport. Check the package, as in `debian-ubuntu.md` or `alpine.md`. Slim Debian images often have no `/usr/share/doc`; then compare `dpkg-query -W php8.2-fpm` with the distro's security tracker.

Is the running container on the new image?

```bash
docker inspect -f '{{.Image}}' <c>
docker image inspect -f '{{.Id}}' <image:tag>   # must be the same id
```

## 3. Patch it

1. **Keep the same minor version and base**, for example `php:8.4-fpm-bookworm`. Change one thing at a time.
2. **Add a build guard.** The build then fails if PHP is too old:
   ```dockerfile
   RUN php -r 'exit(version_compare(PHP_VERSION,"8.4.27",">=")?0:1);'
   ```
   Use `8.3.36`, `8.2.35` or `8.5.12` for other branches.
3. **Rebuild with a fresh base image:**
   ```bash
   docker compose -p <proj> -f <file> build --pull <svc>
   ```
   For images that run `apt-get`/`apk` themselves, add `--no-cache`. A cached `apt-get update` layer installs the old package again.
4. **Rebuild every service that uses the image**: web, queue workers, scheduler.
5. **Staging first.** Run the app's smoke tests.
6. **Recreate, do not restart.** `docker restart` keeps the old image.
   ```bash
   docker compose -p <proj> --env-file <env> -f <file> up -d --no-deps --no-build --dry-run <svc>
   docker compose -p <proj> --env-file <env> -f <file> up -d --no-deps --no-build <svc>
   ```
   Use the same project name, files and env file the container was created with (read its labels).

**Downtime:** a few seconds of 502 while the container is replaced, unless you run two replicas. **Stop signal:** the official `-fpm` images set `STOPSIGNAL SIGQUIT` (graceful stop); `-apache` sets `SIGWINCH`. A custom shell entrypoint that ignores SIGQUIT makes every stop wait the whole grace period. Check `docker inspect -f '{{.Config.StopSignal}}' <c>`. If needed, set `stop_signal: SIGTERM` in compose and trap it in the entrypoint.

**On 8.1 or older:** move to 8.3 or 8.4 (8.2 reaches end of life on 31 Dec 2026). If that is impossible today, use section 4, then plan the upgrade. Building the backport branch inside your image is covered in `source-built.md`.

## 4. If you cannot patch today

This reduces exposure. It does not make the server safe.

**ini file** `/usr/local/etc/php/conf.d/zz-php2shell.ini` (`zz-` loads last):

```ini
session.upload_progress.enabled = 0
post_max_size = 8M          ; 32M if the site takes uploads
upload_max_filesize = 6M    ; keep below post_max_size
memory_limit = -1           ; ONLY with a container memory limit, see below
; PHP 8.5 only:
; fatal_error_backtraces = 0
```

**FPM pool** `/usr/local/etc/php-fpm.d/zz-php2shell.conf` (sorts after `zz-docker.conf`). Apps cannot override `php_admin_*` with `ini_set()` or `.user.ini`:

```ini
[www]
php_admin_value[memory_limit] = -1
php_admin_flag[session.upload_progress.enabled] = off
php_admin_value[post_max_size] = 8M
php_admin_value[upload_max_filesize] = 6M
```

The section name must match your pool (`[www]` by default; check with `docker exec <c> php-fpm -tt`).

**`-apache` image:** use the same ini file, and also pin the values in Apache config, for example `/etc/apache2/conf-enabled/zz-php2shell.conf`:

```apache
php_admin_value memory_limit -1
php_admin_flag session.upload_progress.enabled off
```

**Memory boundary:** `memory_limit=-1` needs a cgroup limit, or one request can eat the host. Set `mem_limit: 1g` (or `deploy.resources.limits.memory`) on the service. Do **not** use `ulimits` for `as` or `data` (RLIMIT_AS / RLIMIT_DATA): those can trigger the bug.

**Apply:** bake the files into the image (best), or bind-mount them read-only as a quick fix. Then recreate the container, so every worker restarts. Also add web-server limits (`guides/web/`).

## 5. Verify

- **FPM:** `scripts/fpm_ini_probe.sh <container>`. It reads values from FPM, not the CLI. It needs `cgi-fcgi` in the image (`libfcgi-bin` on Debian; on Alpine the `fcgi` package (verify on your system)).
- **Apache image:** use a one-off probe page with a random name, and delete it at once. Do not use `phpinfo()`: it can show environment secrets.
  ```bash
  N="probe-$(openssl rand -hex 12).php"
  docker exec -i <c> sh -c "cat > /var/www/html/$N" <<'PHP'
  <?php header('Content-Type: text/plain'); echo PHP_VERSION, ' ', PHP_SAPI, "\n";
  foreach (['memory_limit','post_max_size','upload_max_filesize','session.upload_progress.enabled','fatal_error_backtraces'] as $k)
    echo $k, ' = ', var_export(ini_get($k), true), "\n";
  PHP
  curl -s -H "Host: <domain>" "http://127.0.0.1:<port>/$N"; docker exec <c> rm -f "/var/www/html/$N"
  ```
- Expect the patched version, `session.upload_progress.enabled = '0'` (or `''`), and your limits.

## 6. Traps on this stack

- **`php -i` shows the CLI**, not FPM. Pool `php_admin_*` values never show there.
- **Layer cache** keeps old distro packages. Use `--pull`, plus `--no-cache` for `apt`/`apk` images.
- **A floating tag** (`8.4-fpm`) on a CI runner or registry mirror can be stale. Check the version inside the built image, not the tag.
- **`docker restart`** does not pick up a new image or new mounts. Recreate.
- **Copying `php.ini-production`** changes many other values. Set only what you mean.
- **Other stacks on the same box** may use their own images. Check every container, not just yours.

## Sources

- https://www.php.net/ (21 and 23 Oct 2026 advisories)
- https://hub.docker.com/_/php
- https://github.com/docker-library/php/blob/master/8.4/bookworm/fpm/Dockerfile (`PHP_INI_DIR`, `STOPSIGNAL SIGQUIT`, `zz-docker.conf`)
- https://github.com/docker-library/php/blob/master/8.4/bookworm/apache/Dockerfile (`STOPSIGNAL SIGWINCH`, mod_php)
