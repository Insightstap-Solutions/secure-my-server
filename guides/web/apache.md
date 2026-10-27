# Apache httpd: mod_php vs FPM, request limits, bad-multipart filter

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), run `apachectl -t` before every reload, staging before production, and ask the human before touching production.

## 1. How PHP runs here

```bash
apachectl -M 2>/dev/null | grep -Ei 'php|proxy_fcgi|mpm|security2|reqtimeout'
apachectl -S 2>/dev/null | head -30          # vhosts and their config files
```

| You see | Meaning |
|---|---|
| `php_module` / `php7_module` | **mod_php**: PHP runs inside Apache. **Highest risk**: the advisory has a demonstrated exploit that runs before any app code. |
| `proxy_fcgi_module` + `SetHandler "proxy:unix:…php-fpm.sock…"` | Apache hands PHP to PHP-FPM. Better. |

**Recommendation: move mod_php sites to PHP-FPM where you can.** On Debian/Ubuntu (ask first; test on staging):

```bash
a2dismod php8.3 mpm_prefork
a2enmod mpm_event proxy_fcgi setenvif
a2enconf php8.3-fpm
apachectl -t && systemctl restart apache2
```

Under FPM, `php_value` / `php_flag` lines in `.htaccess` cause a 500. Move them to the FPM pool first. On panels, switch the handler in the panel instead (see the PHP guide for that panel).

After a PHP upgrade with mod_php, do a **full restart** (`systemctl restart apache2` / `httpd`), not a graceful one, so no child keeps the old library.

## 2. Request limits (core and mod_reqtimeout)

In the server config or each PHP vhost:

Apache does not allow a comment at the end of a directive line, so comments go on their own line:

```apache
# 8 MB; bigger only on upload paths
LimitRequestBody      8388608
# the next three are the defaults; written down so nobody raises them by accident
LimitRequestFields    100
LimitRequestFieldSize 8190
LimitRequestLine      8190

<Location "/upload/">
    # 32 MB, only here
    LimitRequestBody 33554432
</Location>

<IfModule reqtimeout_module>
    RequestReadTimeout header=20-40,MinRate=500 body=20,MinRate=500
</IfModule>
```

- Since httpd 2.4.53 the default `LimitRequestBody` is 1 GiB. Older versions had no limit. Set it.
- Match the body limit to PHP's `post_max_size` (8M without uploads, 32M with).
- Apache cannot count multipart parts or nesting. PHP does that (`max_input_vars`, `max_file_uploads`, `max_multipart_body_parts`, `max_input_nesting_level`).

## 3. Refuse multipart without a usable boundary

**Test before enabling.** Try it on staging, and check the error log for real users hitting it.

**With mod_rewrite** (in the vhost, not `.htaccess`):

```apache
RewriteEngine On
RewriteCond %{REQUEST_METHOD} =POST
RewriteCond %{HTTP:Content-Type} ^multipart/form-data [NC]
RewriteCond %{HTTP:Content-Type} !boundary=(\x22[^\x22]+\x22|[^;\s\x22]+) [NC]
RewriteRule ^ - [R=400,L]
```

(`\x22` is a double quote, so `boundary=""` counts as missing.)

**With ModSecurity (mod_security2)**, as a rule idea:

```apache
SecRule REQUEST_HEADERS:Content-Type "@rx (?i)^multipart/form-data" \
    "id:1026109,phase:1,deny,status:400,log,msg:'multipart without boundary',chain"
    SecRule REQUEST_HEADERS:Content-Type "!@rx (?i)boundary=(\x22[^\x22]+\x22|[^;\s\x22]+)"
```

Pick an `id` that does not clash with your rule sets. If you run the OWASP Core Rule Set, it may already reject some of these; check its logs first so you do not double-block.

## 4. Test, then reload

```bash
apachectl -t || { echo "TEST FAILED, NOT RELOADING"; exit 1; }
apachectl -k graceful            # or: systemctl reload apache2 / httpd
```

Graceful reload keeps open connections. Use a full restart only after a mod_php upgrade.

## 5. Prove it from outside

```bash
U=https://<domain>/
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: multipart/form-data; boundary=' --data-binary 'x' "$U"   # 400
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: multipart/form-data' --data-binary 'x' "$U"              # 400
head -c 20000000 /dev/zero | curl -s -o /dev/null -w '%{http_code}\n' -X POST --data-binary @- "$U"                          # 413
curl -s -o /dev/null -w '%{http_code}\n' -F 'a=b' "$U"                                                                        # not 400/413
```

## 6. Traps

- **`apachectl -M` lists modules loaded globally.** A vhost can still `SetHandler` to FPM while mod_php is loaded. Check both.
- **Panels regenerate vhosts** (cPanel, Plesk, DirectAdmin). Use their include folders or "additional directives", not the generated file.
- **`.htaccess` can raise `LimitRequestBody`** only if `AllowOverride` allows it; it cannot add `LimitRequestFields`. Keep limits in server config.
- **`RLimitMEM`** sets process limits on CGI children. Do not use it as a "memory" fix: RLIMIT_AS / RLIMIT_DATA style limits can trigger the PHP bug.
- **mod_php needs `mpm_prefork`.** Moving to FPM lets you use `mpm_event`, which handles slow clients better.

## Sources

- https://httpd.apache.org/docs/2.4/mod/core.html (`LimitRequestBody` and its 1 GiB default since 2.4.53, `LimitRequestFields`, `LimitRequestFieldSize`, `LimitRequestLine`)
- https://httpd.apache.org/docs/2.4/mod/mod_reqtimeout.html
- https://httpd.apache.org/docs/2.4/rewrite/flags.html (`R` with a non-3xx code)
- https://github.com/owasp-modsecurity/ModSecurity/wiki/Reference-Manual-(v2.x)
- https://www.php.net/ (21 Oct 2026 advisory)
