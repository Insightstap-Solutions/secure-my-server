# OpenLiteSpeed and LiteSpeed Enterprise: request limits

Covers the web server side. For the lsphp runtime itself, read `guides/php/cyberpanel-openlitespeed.md`.

**Safety:** back up every config file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), staging before production, and ask the human before restarting production.

## 1. Which LiteSpeed is this?

```bash
/usr/local/lsws/bin/lshttpd -v                 # version and edition
ls /usr/local/lsws/conf/
```

| Edition | Main config |
|---|---|
| **OpenLiteSpeed** (often with CyberPanel) | `/usr/local/lsws/conf/httpd_config.conf`, vhosts in `/usr/local/lsws/conf/vhosts/<name>/vhconf.conf`. WebAdmin console on port 7080. |
| **LiteSpeed Enterprise** | Its own config under `/usr/local/lsws/conf/`, or Apache's config files when it replaces Apache on cPanel, Plesk or DirectAdmin. |

## 2. Request body size

**OpenLiteSpeed:** WebAdmin › **Server Configuration › Tuning › Max Request Body Size (bytes)**. In the file it is `maxReqBodySize` (verify on your system that it sits in the `tuning` block of `httpd_config.conf`). Related settings on the same page: *Max Request Header Size* and *Max Request URL Length*.

```
maxReqBodySize           8M
```

This is server-wide. LiteSpeed's manual advises keeping it as small as real uploads allow. If a site needs bigger uploads, raise it to that size (32M with PHP's `post_max_size = 32M`) and keep PHP's `post_max_size` as the real per-site limit.

**LiteSpeed Enterprise:** per virtual host, inside an Apache-style config, wrapped so Apache ignores it:

```apache
<IfModule LiteSpeed>
    MaxReqBodySize 8M
</IfModule>
```

Where LiteSpeed Enterprise reads Apache config, the Apache limits in `guides/web/apache.md` (`LimitRequestBody` and friends) may also apply (verify on your system).

## 3. Refuse multipart without a usable boundary

LiteSpeed understands Apache-style rewrite rules. In the vhost's rewrite rules (OLS: WebAdmin › Virtual Hosts › Rewrite) or `.htaccess`. **Test before enabling** (verify on your system that your edition returns 400 for `R=400`):

```apache
RewriteEngine On
RewriteCond %{REQUEST_METHOD} =POST
RewriteCond %{HTTP:Content-Type} ^multipart/form-data [NC]
RewriteCond %{HTTP:Content-Type} !boundary=(\x22[^\x22]+\x22|[^;\s\x22]+) [NC]
RewriteRule ^ - [R=400,L]
```

If you run ModSecurity rules in LiteSpeed, the rule idea in `apache.md`, section 3, is an alternative.

## 4. PHP memory limits here

LiteSpeed's external-app settings for lsphp include *Memory Soft Limit* / *Memory Hard Limit*. These are process resource limits (verify on your system). The PHP advisory warns that RLIMIT_AS / RLIMIT_DATA limits can **trigger** the bug. Do not tighten them as a fix. Patch PHP.

## 5. Apply

```bash
/usr/local/lsws/bin/lswsctrl restart      # LiteSpeed's restart is graceful
# or: systemctl restart lsws
```

OpenLiteSpeed reads `.htaccess` changes only after a restart. Detached lsphp processes may survive it; see the PHP guide if you also changed PHP.

## 6. Prove it from outside

```bash
U=https://<domain>/
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: multipart/form-data; boundary=' --data-binary 'x' "$U"   # 400
head -c 20000000 /dev/zero | curl -s -o /dev/null -w '%{http_code}\n' -X POST --data-binary @- "$U"                          # 413 (or the edition's refusal code)
curl -s -o /dev/null -w '%{http_code}\n' -F 'a=b' "$U"                                                                        # not 400/413
```

## 7. Traps

- **WebAdmin on port 7080 open to the internet.** Restrict it with the firewall (`guides/firewall/`).
- **CyberPanel rewrites some vhost files.** Use CyberPanel's own rewrite/vhost editors so your change survives.
- **The panel nginx or CDN in front** may have its own (bigger) limit. The smallest limit on the path wins; set the outer one too.

## Sources

- https://docs.litespeedtech.com/lsws/configuration/ (`MaxReqBodySize` per vhost inside `<IfModule LiteSpeed>`)
- https://openlitespeed.org/kb/ and the OpenLiteSpeed Users' Manual, *Server Tuning* (Max Request Body Size, Max Request Header Size)
- https://docs.litespeedtech.com/lsws/extapp/php/configuration/options/
- https://www.php.net/ (21 Oct 2026 advisory: no RLIMIT_AS / RLIMIT_DATA)
