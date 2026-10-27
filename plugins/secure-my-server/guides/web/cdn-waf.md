# A CDN or WAF in front (Cloudflare and similar)

A WAF rule can stop the known attack shape before it reaches your server. It is a **stopgap**: it only helps if the attacker cannot go around the CDN to your origin directly. Patch PHP anyway.

**Safety:** back up or export the current rules first, start every new rule in log-only mode when the product has one, and ask the human before blocking on production.

## 1. Is there a CDN in front?

```bash
dig +short <domain> A; dig +short <domain> AAAA     # CDN ranges, not your server's IP?
curl -sI https://<domain>/ | grep -iE 'server:|cf-ray|via:|x-cache'
```

Then check the origin's access log: do client IPs look like CDN ranges? If yes, the origin needs real-IP config (`nginx.md`, `caddy.md`), or every per-IP limit there is one shared bucket.

## 2. A rule for multipart without a usable boundary

Attack shape: `POST`, `Content-Type: multipart/form-data` with an empty or missing `boundary`, body 1–8 MB, often to `/`.

**Cloudflare custom rule** (expression editor), action **Block**. Use **Log** first if your plan has it. Cloudflare's docs do not state plan limits for these functions; the editor refuses an expression it cannot run, so you will know (verify on your system).

```
http.request.method eq "POST"
and any(starts_with(lower(http.request.headers["content-type"][*]), "multipart/form-data"))
and not any(lower(http.request.headers["content-type"][*]) contains "boundary=")
```

This catches a **missing** boundary. To also catch `boundary=` with nothing after it, add a second rule:

```
http.request.method eq "POST"
and any(ends_with(lower(http.request.headers["content-type"][*]), "boundary="))
```

**Other WAFs:** build the same logic: content type starts with `multipart/form-data` (case-insensitive) AND no `boundary=<non-empty value>`. Where regex is allowed: `(?i)boundary=("[^"]+"|[^;\s"]+)` must NOT match.

Also check whether your WAF vendor has published a managed rule for these CVEs, and turn it on.

## 3. Body size at the edge

Most CDNs cap request bodies by plan. That cap is usually far above what the attack needs (1–8 MB), so do not count on it. Keep the origin limits from the web guides.

## 4. The origin must not be reachable directly

If anyone can reach the origin's IP, they skip every edge rule.

**Check from outside** (a laptop or another host, not the server itself), on IPv4 **and** IPv6:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' --resolve <domain>:443:<origin-ipv4> https://<domain>/
curl -sk -o /dev/null -w '%{http_code}\n' --resolve '<domain>:443:[<origin-ipv6>]' https://<domain>/
nmap -Pn -p 80,443 <origin-ipv4>; nmap -6 -Pn -p 80,443 <origin-ipv6>
```

A normal page answer means the origin is open to everyone.

**Close it** (pick one, ask first; a mistake takes the site down):

- Allow 80/443 on the origin **only from the CDN's published IP ranges** (Cloudflare: `https://www.cloudflare.com/ips/`), using the firewall guide for this box. Keep the list updated.
- Or use the CDN's authenticated origin feature (Cloudflare: Authenticated Origin Pulls, mTLS) or a tunnel, so the origin accepts only the CDN.

## 5. Places the origin IP leaks

- Old DNS records: `direct.`, `origin.`, `ftp.`, `mail.` or an apex record without the proxy on.
- MX records or mail headers when mail goes out from the same server.
- An AAAA record that points straight at the origin while A is proxied.
- Historic DNS: if the IP was ever public, assume it is known. The firewall rule in step 4 is the real fix.

## 6. Prove it

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: multipart/form-data' --data-binary 'x' https://<domain>/   # blocked by the WAF
curl -s -o /dev/null -w '%{http_code}\n' -F 'a=b' https://<domain>/                                                          # not blocked
```

Then repeat step 4 and confirm the origin no longer answers directly.

## Sources

- https://developers.cloudflare.com/waf/custom-rules/
- https://developers.cloudflare.com/ruleset-engine/rules-language/functions/ (`any`, `lower`, `starts_with`, `ends_with`)
- https://developers.cloudflare.com/ruleset-engine/rules-language/fields/ (`http.request.headers`)
- https://www.cloudflare.com/ips/
- https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/
