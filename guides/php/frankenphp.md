# FrankenPHP

FrankenPHP is a web server (built on Caddy) with **PHP compiled inside it**. You do not update PHP on its own. You install a fixed FrankenPHP binary or image, then restart the whole process.

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), test config before reload, staging before production, and ask the human before any production restart.

Fixed upstream PHP: **8.5.12, 8.4.27, 8.3.36, 8.2.35**. FrankenPHP **v1.13.2** (21 Oct 2026) ships Docker images built with those versions and static binaries with PHP 8.5.12. v1.13.3 (23 Oct) is a bug-fix release on top.

## 1. How to recognise it

```bash
pgrep -a frankenphp
docker ps --format '{{.Names}}\t{{.Image}}' | grep -i franken
frankenphp version            # FrankenPHP, PHP and Caddy versions (verify on your system)
```

Two forms: a **static binary** on the host (often `/usr/local/bin/frankenphp` with a systemd unit), or a **Docker image** (`dunglas/frankenphp:…`, or your own image `FROM` it).

## 2. Is it patched?

- FrankenPHP **v1.13.2 or newer** with a fixed PHP branch.
- Check the PHP version the process really embeds: `frankenphp version` or a probe page (section 5).
- In Docker: also check the running container uses the new image (`docker inspect -f '{{.Image}}' <c>` vs `docker image inspect -f '{{.Id}}' <image>`).

## 3. Patch it

- **Static binary:** download the new release from GitHub, check its checksum, put it beside the old one, switch the unit or symlink, then `systemctl restart <service>`. Keep the old binary for rollback.
- **Docker:** bump the tag (for example to a `1.13`-series tag with your PHP branch), `docker compose build --pull <svc>`, then **recreate** the container (`up -d --no-deps --no-build <svc>`). `docker restart` keeps the old image.
- **Worker mode:** restarting workers through FrankenPHP's admin API does **not** load the new PHP. Only a full process restart or a new container does.
- Read the v1.13.2 release notes first: static builds moved to static-php-cli v3.

**Downtime:** the restart (seconds). With worker mode, the app boots again, so the first requests are slower.

## 4. If you cannot patch today

This reduces exposure. It does not make the server safe.

- **Docker image:** it reads `/usr/local/etc/php/php.ini` (the image ships without one). A file in `/usr/local/etc/php/conf.d/`, for example `zz-php2shell.ini`, should also load (verify on your system with the probe in section 5).
- **Static binary:** it reads `php.ini` from the folder where `frankenphp run` / `php-server` is started, then `/etc/frankenphp/php.ini`. Or set values in the Caddyfile's global `frankenphp` block with `php_ini` (documented; it can be repeated):
  ```caddyfile
  {
      frankenphp {
          php_ini session.upload_progress.enabled 0
          php_ini post_max_size 8M
          php_ini upload_max_filesize 6M
      }
  }
  ```

```ini
session.upload_progress.enabled = 0
post_max_size = 8M          ; 32M if the site takes uploads
upload_max_filesize = 6M    ; keep below post_max_size
; PHP 8.5 only:
; fatal_error_backtraces = 0
```

`memory_limit = -1` only with a container or cgroup memory limit, never with RLIMIT_AS / RLIMIT_DATA. Add `request_body { max_size 8MB }` in the site (see `guides/web/caddy.md`). Restart the whole process after any change.

## 5. Verify

- A one-off probe page with a random name in the document root, deleted at once (same probe as `debian-ubuntu.md`, section 5). `PHP_SAPI` reads `frankenphp`. Do not use `phpinfo()`.
- The process or container started after the change: `ps -o pid,lstart,args -C frankenphp`, or `docker ps` "Created" time.

## 6. Traps on this stack

- **Worker mode keeps state between requests by design.** A partial restart is not enough. Restart the process.
- **The CLI inside the image** (`php`) may be a separate binary. Check the server's own version.
- **Admin API exposed** to the network is its own risk. Keep it on localhost.

## Sources

- https://www.php.net/ (21 and 23 Oct 2026 advisories)
- https://github.com/php/frankenphp/releases/tag/v1.13.2 (PHP versions in images and static binaries)
- https://frankenphp.dev/docs/config/ (`php_ini` in the `frankenphp` block)
