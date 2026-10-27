# nginx: request limits and the bad-multipart filter

Edge limits do not fix PHP. They make the known attack shape (a `multipart/form-data` POST of 1–8 MB with an empty or missing boundary, sent to `/`) fail at nginx, before PHP sees it. Use them as well as patching.

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), run `nginx -t` before every reload, staging before production, and ask the human before reloading production.

## 1. Find the LIVE nginx

A box can have two nginx installs (a panel's and the distro's). Work on the one that is running.

```bash
ps -eo pid,args | grep '[n]ginx: master'           # shows the binary and any -c
readlink -f /proc/$(pgrep -o -f 'nginx: master')/exe
<binary> -V 2>&1 | tr ' ' '\n' | grep -E 'conf-path|pcre'
ss -ltnp | grep -E ':(80|443) '                    # which process owns the ports
```

From now on, call it with the full path and `-c <conf>`. Examples: distro `/usr/sbin/nginx -c /etc/nginx/nginx.conf`; aaPanel `/www/server/nginx/sbin/nginx -c /www/server/nginx/conf/nginx.conf`.

Read the whole running config. **Grep it; do not paste it into reports** (it can hold tokens in headers):

```bash
<binary> -T -c <conf> 2>/dev/null | grep -nE 'client_max_body_size|client_body_timeout|client_header_timeout|limit_req|server_name|fastcgi_pass|proxy_pass'
```

## 2. Measure before you limit

- Is there a CDN in front? Then nginx needs `set_real_ip_from` + `real_ip_header`, or every per-IP limit becomes one shared bucket.
- Which routes take uploads, and how big are real uploads?
- Peak requests per second per IP for signed-in users (offices behind one NAT IP).
- Webhook senders (they must never be throttled into failures).

## 3. http context (one file, loaded once)

For example `/etc/nginx/conf.d/00-php2shell-http.conf` (aaPanel: `/www/server/panel/vhost/nginx/0.php2shell.conf`):

```nginx
# 1 = multipart without a usable boundary (the attack shape)
map $http_content_type $bad_multipart {
    default 0;
    "~*^multipart/form-data(?!.*boundary=(\"[^\"]+\"|[^;\s\"]+))" 1;
}

# Per-IP limit for POSTs only (GETs are not counted)
map $request_method $post_limit_key { POST $binary_remote_addr; default ""; }
limit_req_zone $post_limit_key zone=post_per_ip:10m rate=5r/s;
```

The `(?!…)` is a PCRE lookahead. Normal nginx builds have PCRE (`nginx -V` shows `--with-pcre` or links it). If `nginx -t` reports a regex error, your build lacks it; stop and ask.

## 4. server context (each PHP site)

```nginx
if ($bad_multipart) { return 400; }

client_max_body_size  8m;      # small default; match PHP's post_max_size
client_header_timeout 15s;
client_body_timeout   30s;     # per read, not per request: slow big uploads still work

limit_req zone=post_per_ip burst=20 nodelay;
limit_req_status 429;

# Only real upload routes get more:
location ^~ /upload/ {
    client_max_body_size 32m;
    # copy the SAME fastcgi_pass / proxy_pass and headers as the main location
}
```

- nginx's default `client_max_body_size` is `1m`. Many sites raised it to something huge for one form. Make it small, and large only where needed.
- Header size is bounded by `large_client_header_buffers` (default `4 8k`). Leave it unless you have a reason.
- nginx cannot count multipart parts or nesting. PHP does that (`max_input_vars`, `max_file_uploads`, `max_multipart_body_parts`, `max_input_nesting_level`).

## 5. Test, then reload

```bash
<binary> -t -c <conf> || { echo "TEST FAILED, NOT RELOADING"; exit 1; }
<binary> -s reload -c <conf>          # or the panel's / systemd reload for THAT nginx
```

A reload is graceful: no dropped connections.

## 6. Prove it from outside

```bash
U=https://<domain>/
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: multipart/form-data; boundary=' --data-binary 'x' "$U"   # 400
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: multipart/form-data' --data-binary 'x' "$U"              # 400
head -c 20000000 /dev/zero | curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/octet-stream' --data-binary @- "$U"   # 413
curl -s -o /dev/null -w '%{http_code}\n' -F 'a=b' "$U"                     # NOT 400/413 (the app answers)
```

Also: a real upload on the upload route still works; a normal page burst gets 200s; logged-in users are not seeing 429.

## 7. Traps

- **Testing the wrong nginx.** A bare `nginx -t` may test the distro copy while the panel copy serves traffic.
- **`$` inside a single-quoted ssh command** expands on your laptop. Send config files over stdin.
- **A panel regenerates vhost files.** Put your lines in files it does not rewrite (aaPanel: `proxy/<site>/` or `0.*.conf` in the vhost folder).
- **A new upload `location` without the original proxy headers** (`X-Forwarded-Proto` and others) breaks signed URLs and HTTPS detection.
- **`limit_req` behind a CDN** without real-IP config throttles the CDN, not the attacker.

## Sources

- https://nginx.org/en/docs/http/ngx_http_core_module.html (`client_max_body_size` default 1m, timeouts, `large_client_header_buffers`)
- https://nginx.org/en/docs/http/ngx_http_map_module.html
- https://nginx.org/en/docs/http/ngx_http_limit_req_module.html (an empty key is not counted)
- https://www.php.net/ (21 Oct 2026 advisory: web-server limits on body size, fields and nesting)
