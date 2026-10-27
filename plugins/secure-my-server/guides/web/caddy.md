# Caddy: body limits, headers, real IPs, logs

**Safety:** back up the Caddyfile first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), run `caddy validate` before every reload, staging before production, and ask the human before reloading production.

## 1. Find the live config

```bash
pgrep -a caddy                                   # host: shows --config
docker ps --format '{{.Names}}\t{{.Image}}' | grep -i caddy
docker exec <c> cat /etc/caddy/Caddyfile         # usual path in the official image
```

If an outer nginx or CDN sits in front, Caddy is the **inner** proxy. Limits belong at the outer edge first (`nginx.md`, `cdn-waf.md`); Caddy limits are the second belt.

## 2. Body size

```caddyfile
example.com {
    request_body {
        max_size 8MB
    }
    request_body /upload/* {
        max_size 32MB
    }
    # php_fastcgi / reverse_proxy as before
}
```

Match PHP's `post_max_size` (8M without uploads, 32M with). Caddy's docs say reads past the limit fail with 413. Test it anyway through `php_fastcgi`/`reverse_proxy`, and note what you really get.

## 3. Refuse multipart without a usable boundary

Caddy's regex engine (Go RE2) has no lookahead, so use two matchers. **Test before enabling.**

```caddyfile
# inside the site block
@bad_multipart {
    method POST
    header_regexp Content-Type `(?i)^multipart/form-data`
    not header_regexp Content-Type `(?i)boundary=("[^"]+"|[^;\s"]+)`
}
respond @bad_multipart 400
```

The backticks quote the regex, so the `"` inside it is safe. Run `caddy validate` (section 6) before you trust it.

## 4. Timeouts and header size (global options)

A Caddyfile has **one** global options block at the very top. Merge the `servers` lines from this section and section 5 into it.

```caddyfile
{
    servers {
        timeouts {
            read_header 15s
            read_body   30s
        }
        max_header_size 16KB
    }
}
```

## 5. Headers, real client IPs, logs

```caddyfile
{
    servers {
        trusted_proxies static private_ranges
        client_ip_headers X-Forwarded-For
    }
}

example.com {
    header {
        defer
        -X-Powered-By
        -Server
    }
    log {
        output file /var/log/caddy/access.log {
            roll_size 50MiB
            roll_keep 20
        }
        format json
    }
}
```

- `defer` makes header changes apply to responses from `php_fastcgi` too. Without it, `X-Powered-By` from PHP can slip through.
- `trusted_proxies` makes Caddy (and the app) see real client IPs behind an outer proxy. Without it, every per-IP limit in the app is one shared bucket. **Tell the human:** it changes behaviour. Trust only ranges you control (`private_ranges` assumes the outer proxy is on a private network).
- In Docker, `/var/log/caddy` must be a **named volume**. Otherwise logs vanish with the container.
- Only one `log` block per site works as expected. Keep the stdout copy in the global `log` options if you need both.
- **Keep any existing line that forces HTTPS for the app** (for example `header_up X-Forwarded-Proto https` or `env HTTPS on` in `php_fastcgi`). Signed URLs depend on it.

## 6. Validate, then reload

```bash
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
caddy reload   --config /etc/caddy/Caddyfile --adapter caddyfile     # graceful, no dropped connections
# in Docker:
docker exec <c> caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec <c> caddy reload   --config /etc/caddy/Caddyfile --adapter caddyfile
```

If the Caddyfile is a single-file bind mount, an editor save may create a new inode that the container never sees. Edit in place, or recreate the container.

## 7. Prove it

```bash
U=https://<domain>/
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: multipart/form-data; boundary=' --data-binary 'x' "$U"   # 400
head -c 20000000 /dev/zero | curl -s -o /dev/null -w '%{http_code}\n' -X POST --data-binary @- "$U"                          # 413
curl -sI "$U" | grep -i x-powered-by                                                                                         # nothing
```

Count log lines, restart the container, send a request, count again: the count must grow, not reset.

## Sources

- https://caddyserver.com/docs/caddyfile/directives/request_body
- https://caddyserver.com/docs/caddyfile/matchers (`header_regexp`, `not`)
- https://caddyserver.com/docs/caddyfile/options (`servers`: `timeouts`, `max_header_size`, `trusted_proxies`, `client_ip_headers`)
- https://caddyserver.com/docs/caddyfile/directives/header (`defer`)
- https://caddyserver.com/docs/caddyfile/directives/log
- https://caddyserver.com/docs/command-line (`validate`, `reload`)
