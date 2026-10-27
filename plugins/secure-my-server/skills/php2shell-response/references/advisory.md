# The advisory, in plain words

Checked on 27 Oct 2026 against php.net. **Look for a newer advisory before relying on this file:** https://www.php.net/archive/2026.php

## What is broken
Two bugs in how PHP sets up and cleans up each web request. An attacker sends one crafted HTTP request to **any** PHP page, needs no login, and can run their own code on the server.

| CVE | Name on php.net | Advisory |
|---|---|---|
| CVE-2026-109618 | RCE via OOM corruption | GHSA-w8hw-w9fx-j79w |
| CVE-2026-109619 | RCE via stale global state | GHSA-6wmf-4rv5-p3rp |

Both are rated CVSS 4.0 **9.2** (critical). "PHP2Shell" is the name the security press uses; php.net does not use it.

**Who is at risk:** every PHP that serves web requests: PHP-FPM, Apache **mod_php** (php.net considers this the highest risk; a working exploit runs before any application code), php-cgi, FrankenPHP and LiteSpeed. The PHP command line (cron jobs, artisan) is not the target, but it is usually the same package, so it gets patched with the rest.

## Fixed versions (21 Oct 2026)
| Branch | Fixed in | Notes |
|---|---|---|
| 8.5 | **8.5.12** | also set `fatal_error_backtraces=0` if you cannot patch yet |
| 8.4 | **8.4.27** | |
| 8.3 | **8.3.36** | |
| 8.2 | **8.2.35** | 8.2 reaches end of life on 31 Dec 2026: plan the move |
| 8.6 | RC4 and later | pre-release; do not run RCs in production |
| 8.1, 8.0, 7.4 | **no official release** | distro/LTS vendor backport, or the php-src branches `PHP-7.4-CVE-2026-109618-109619`, `PHP-8.0-…`, `PHP-8.1-…` for people who build from source. Otherwise upgrade. |
| 7.3 and older | nothing | upgrade; until then, mitigate and isolate |

**Distro packages are different.** Ubuntu, Debian, RHEL, AlmaLinux, Rocky and others received the patch in advance and ship it **inside their own package without changing PHP's version number**. `8.3.6-0ubuntu0.24.04.x` can be patched even though 8.3.6 < 8.3.36. For a distro package, the evidence is the **package changelog** naming the CVE (`scripts/php_runtimes.sh` reads it), or the vendor's security tracker. Third-party repositories that follow php.net's version numbers (Ondřej Surý, Remi, cPanel EA-PHP, Plesk, aaPanel, LiteSpeed lsphp, DirectAdmin CustomBuild) are compared by version.

## If you cannot patch today
php.net is explicit: **only an update is a complete fix.** These only reduce exposure to the paths known so far. Use them for hours or days, not weeks, and tell the user that.

**For CVE-2026-109619 (stale state):**
- `session.upload_progress.enabled=0` in php.ini, the FPM pool (`php_admin_flag`) or the web server config, i.e. somewhere that applies **before** the request is parsed. `ini_set()` and FPM `.user.ini` files do **not** count. Then restart **every** worker.
- PHP 8.5: also `fatal_error_backtraces=0`, then restart every worker.
- Remove invalid or deprecated per-request settings that print warnings before PHP finishes starting up. Hiding warnings (`display_errors`, `error_reporting`, `@`) does not help.
- Fix fatal errors and timeouts an attacker can trigger (upload and import handling, callbacks, cleanup code).

**For CVE-2026-109618 (OOM corruption):**
- `memory_limit=-1`, set where applications cannot override it (`php_admin_value[memory_limit] = -1` in the pool, or the Apache config), and check that no pool, directory or app puts a finite limit back. **Pair it with a container or cgroup memory limit** that kills only the affected worker, so one request cannot eat the whole server. Do **not** use `RLIMIT_AS`/`RLIMIT_DATA` instead: they can trigger the bug.
- Low `post_max_size`: 8M for apps without uploads, 32M with uploads, `upload_max_filesize` below it.
- Limits at the web server / proxy: body size, number of fields, multipart parts and headers, nesting depth, including requests with no usable `Content-Length`.

**At the edge (all stacks):** reject `multipart/form-data` whose `boundary=` is empty or missing (400). That is the shape of the attacks seen in the wild. It is cheap and almost never hits a real browser. See the stack's `guides/web/*.md`.

## After you patch: keep this one setting
On 23 Oct 2026 php.net advised keeping `session.upload_progress.enabled=0` **until the next regular bugfix release**, because of a further, unlikely path (CVE-2026-115560). It only matters if an application changes `session.serialize_handler` at runtime, but switching upload progress off costs almost nothing, so switch it off everywhere.

## What attacks look like
Seen against a real server on 23 Oct 2026 (two days after the release):
- `POST /` with `Content-Type: multipart/form-data` and an **empty** `boundary=`, about 1 MB, then about 8 MB;
- the responses: one odd small `200` with none of the application's usual headers or cookies (PHP died before the app ran), and one `502`;
- an FPM worker crashing (`exited on signal 11 (SIGSEGV)`).

Other shapes are possible. Also look for: `Allowed memory size of … exhausted … in Unknown on line 0`, bursts of 502s on POSTs, `PHP_SESSION_UPLOAD_PROGRESS` form fields, and field names with thousands of nested brackets.

## Sources
- php.net news archive (advisory of 21 Oct, informational advisory of 23 Oct, release notes): https://www.php.net/archive/2026.php
- GHSA-w8hw-w9fx-j79w: https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w
- GHSA-6wmf-4rv5-p3rp: https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp
