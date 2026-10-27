# Per-stack guides

Every server is set up differently. These guides hold the commands and paths for **one kind of setup each**.

**How to use them:**
1. Run the detection scripts.
2. Look up what they printed in the tables below.
3. Read **only** that guide and follow it, in order.

`scripts/detect_stack.sh` and `scripts/php_runtimes.sh` print a `kind` for every PHP runtime they find. A box can have more than one runtime, for example panel PHP on the host plus PHP inside Docker. Handle each runtime with its own guide, one after the other.

> **Rule: never mix instructions from two panels on one box. The panel owns its PHP.**
> On a cPanel box, do not `apt`/`dnf` the panel's PHP by hand. On an aaPanel box, do not install distro PHP "to fix it". Use the guide for the panel that owns the runtime.

If the scripts disagree with what you see on the box, trust the box, and tell the human what differed.

## PHP runtimes

| The scripts say | Read |
|---|---|
| `kind=docker` (official `php:` image, or any image with PHP inside) | [`php/docker-official-image.md`](php/docker-official-image.md) |
| `kind=distro` on Debian or Ubuntu | [`php/debian-ubuntu.md`](php/debian-ubuntu.md) |
| `kind=sury` (Ondřej Surý repo or PPA) | [`php/debian-ubuntu.md`](php/debian-ubuntu.md) |
| `kind=distro` on RHEL, AlmaLinux, Rocky, CentOS (Stream) | [`php/rhel-family.md`](php/rhel-family.md) |
| `kind=remi` | [`php/rhel-family.md`](php/rhel-family.md) |
| `kind=distro` on Alpine | [`php/alpine.md`](php/alpine.md) |
| `kind=cpanel-ea`, or any runtime under `/opt/alt/php*` (CloudLinux `alt-php`, which the scripts may label `distro`) | [`php/cpanel-whm.md`](php/cpanel-whm.md) |
| `kind=plesk` | [`php/plesk.md`](php/plesk.md) |
| `kind=aapanel` | [`php/aapanel.md`](php/aapanel.md) |
| `kind=directadmin` | [`php/directadmin.md`](php/directadmin.md) |
| `kind=lsphp` (CyberPanel, OpenLiteSpeed, LiteSpeed) | [`php/cyberpanel-openlitespeed.md`](php/cyberpanel-openlitespeed.md) |
| A `frankenphp` binary or image (check this row before `source`: a binary in `/usr/local/bin` can look like a source build) | [`php/frankenphp.md`](php/frankenphp.md) |
| `kind=source` (built by hand, phpbrew, php-build) | [`php/source-built.md`](php/source-built.md) |
| `kind=unknown` | Find out who installed it (package owner, panel folders, build notes), then pick the matching row. If nothing matches, use [`php/source-built.md`](php/source-built.md) and tell the human. |

## Web servers (request limits, the bad-multipart filter)

| The front of the site is | Read |
|---|---|
| nginx (any, including panel nginx) | [`web/nginx.md`](web/nginx.md) |
| Apache httpd (mod_php or proxy to FPM) | [`web/apache.md`](web/apache.md) |
| Caddy | [`web/caddy.md`](web/caddy.md) |
| OpenLiteSpeed or LiteSpeed Enterprise | [`web/litespeed.md`](web/litespeed.md) |
| A CDN or WAF in front (Cloudflare and similar) | [`web/cdn-waf.md`](web/cdn-waf.md), **plus** the origin's guide |

## Firewalls

| The box uses | Read |
|---|---|
| ufw | [`firewall/ufw.md`](firewall/ufw.md) |
| firewalld | [`firewall/firewalld.md`](firewall/firewalld.md) |
| plain nftables or iptables | [`firewall/nftables-iptables.md`](firewall/nftables-iptables.md) |
| Docker publishes ports (any of the above) | [`firewall/docker.md`](firewall/docker.md) **as well** |

## Order of work

1. **Patch PHP** (the PHP guide, sections 1–3). This is the only real fix.
2. **If you cannot patch today**, apply the stopgap (PHP guide, section 4). It reduces exposure. It does not make the server safe.
3. **Edge limits** (the web guide). Useful even after patching.
4. **Firewall** (the firewall guide). Close what should not be public.
5. **Verify** every step from the running process and from outside.

## The facts every PHP guide relies on

- **CVE-2026-109618** (RCE via OOM corruption) and **CVE-2026-109619** (RCE via stale global state). Unauthenticated remote code execution, CVSS 4.0 score 9.2.
- **Fixed in 8.5.12, 8.4.27, 8.3.36, 8.2.35.** PHP 8.1 and older get no official release. Distros and LTS vendors may backport. The PHP project published source-only backport branches for 7.4, 8.0 and 8.1.
- **At risk:** PHP-FPM, Apache mod_php (highest risk: a demonstrated exploit runs before any app code), php-cgi, FrankenPHP, LiteSpeed.
- **Distro packages keep the old version number** after a backport. Check the package changelog for the CVE id, not the version.
- **Keep `session.upload_progress.enabled=0` even after patching**, until the next regular PHP bugfix release (23 Oct advisory, CVE-2026-115560).
- **Seen in the wild:** `multipart/form-data` POST, 1–8 MB, empty or missing boundary, sent to `/`. Symptoms: FPM workers die with SIGSEGV, visitors see 502.

## Safety, every time

- Back up every file before you edit it: `cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`.
- Test the config before you reload.
- Staging before production.
- Ask the human before any production restart.
- Never print secrets. Never turn off a security feature as a "fix".
