# PHP on Debian and Ubuntu (distro packages or Ondřej Surý)

Covers PHP from the Debian/Ubuntu archive (`kind=distro`) and from the Ondřej Surý repository: `packages.sury.org/php` for Debian, `ppa:ondrej/php` for Ubuntu (`kind=sury`).

**Safety:** back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`), test config before reload, staging before production, and ask the human before any production restart.

Fixed upstream: **8.5.12, 8.4.27, 8.3.36, 8.2.35**. 8.1 and older: no official release, only distro or vendor backports.

## 1. How to recognise it

```bash
ls /etc/php/                                    # one folder per installed version
systemctl list-units --type=service 'php*-fpm*' # php8.3-fpm and so on
apache2ctl -M 2>/dev/null | grep -i php         # php_module = mod_php is loaded
apt-cache policy php8.3-fpm                     # which repo the package came from
```

- A version string with `deb.sury.org` means Surý. One with `ubuntu`, `~deb12u`, `+deb13u` means the distro.
- Paths: ini files in `/etc/php/X.Y/{fpm,apache2,cgi,cli}/php.ini` and `conf.d/`; pools in `/etc/php/X.Y/fpm/pool.d/`.

## 2. Is it patched?

List every installed PHP package with its version:

```bash
dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${Version}\n' 'php*' 'libapache2-mod-php*' | awk '$1=="ii"'
```

| Source | How to decide |
|---|---|
| **Surý**, 8.2–8.5 | Upstream versions. `8.3.36-1+…deb.sury.org…` or higher is fixed. |
| **Debian / Ubuntu archive** | The version stays old after a backport (for example `8.3.6-0ubuntu0.24.04.x`, `…~deb12uN`). **Look for the CVE id in the changelog.** |
| **Surý**, 7.4/8.0/8.1 | Look for the CVE id in the changelog (verify on your system). No CVE line means not fixed. |

```bash
zgrep -E 'CVE-2026-10961[89]' /usr/share/doc/php8.3-fpm/changelog.Debian.gz \
  || zgrep -E 'CVE-2026-10961[89]' /usr/share/doc/php8.3-common/changelog.Debian.gz
apt changelog php8.3-fpm 2>/dev/null | grep -E 'CVE-2026-10961[89]'   # newest available, from the network
```

Also read the tracker for your release: `https://security-tracker.debian.org/tracker/CVE-2026-109618` or `https://ubuntu.com/security/CVE-2026-109618`.

Old releases: Ubuntu 20.04 (php7.4) gets fixes only through Ubuntu Pro / ESM. Debian 11 (php7.4) depends on the Debian LTS / ELTS status. Check before you count on a fix.

## 3. Patch it

```bash
PKGS=$(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 'php*' 'libapache2-mod-php*' | awk '$1=="ii"{print $2}')
apt-get update
apt-get -s install --only-upgrade $PKGS     # simulate first: read what changes
apt-get install --only-upgrade $PKGS
```

Then restart **every** PHP that serves web requests (ask first on production):

```bash
systemctl restart php8.3-fpm        # each installed version that runs
systemctl restart apache2           # if mod_php is loaded; full restart, not graceful
```

- **Restart, not reload, after an upgrade.** Then check the master start time (section 5). Do not assume the package scripts restarted it.
- **Downtime:** FPM restart drops in-flight requests (about a second of 502). An Apache restart drops connections too.
- **Staging first**, then production.
- If `needrestart` is installed, `needrestart -r l` lists services still running old code.

## 4. If you cannot patch today

This reduces exposure. It does not make the server safe. Do it for **each version** and **each web SAPI** (`fpm`, `apache2`, `cgi`).

**ini file** `/etc/php/8.3/fpm/conf.d/99-php2shell.ini` (and the same in `apache2/conf.d/` or `cgi/conf.d/` if used):

```ini
session.upload_progress.enabled = 0
post_max_size = 8M          ; 32M if the site takes uploads
upload_max_filesize = 6M    ; keep below post_max_size
memory_limit = -1           ; ONLY with a cgroup memory limit, see below
; PHP 8.5 only:
; fatal_error_backtraces = 0
```

**FPM pool:** add to **each** pool in `/etc/php/8.3/fpm/pool.d/*.conf`, inside that pool's `[name]` section:

```ini
php_admin_value[memory_limit] = -1
php_admin_flag[session.upload_progress.enabled] = off
php_admin_value[post_max_size] = 8M
php_admin_value[upload_max_filesize] = 6M
```

Then check that no pool sets a finite value back: `grep -rn 'memory_limit\|upload_progress' /etc/php/*/fpm/pool.d/`.

**mod_php:** add the same two `php_admin_*` lines in Apache syntax to `/etc/apache2/conf-available/php2shell.conf` (`php_admin_value memory_limit -1`, `php_admin_flag session.upload_progress.enabled off`), then `a2enconf php2shell`.

**Memory boundary** (needed with `memory_limit=-1`): `systemctl edit php8.3-fpm` and add:

```ini
[Service]
MemoryMax=2G
```

Do **not** use `LimitAS=` or `LimitDATA=`. Check: `systemctl show php8.3-fpm -p LimitAS -p LimitDATA` should say `infinity`.

**Apply:** `php-fpm8.3 -t`, `apache2ctl -t`, then restart FPM and Apache as in section 3. Add web limits from `guides/web/`.

## 5. Verify

Is the running process the new one?

```bash
for p in $(pgrep -f 'php-fpm: master'); do ps -o pid=,lstart=,args= -p "$p"; ls -l "/proc/$p/exe"; done
grep -E ' (upgrade|install) php8\.3-fpm' /var/log/dpkg.log | tail -1
grep -h libphp /proc/$(pgrep -o -x apache2)/maps 2>/dev/null | grep -c deleted   # mod_php: must be 0
```

`(deleted)` after the exe path means the old binary is still running. The master must start **after** the upgrade time.

Read values from FPM, not the CLI. Use a one-off probe page with a random name, then delete it. Do not use `phpinfo()`, which can show secrets.

```bash
D=/var/www/<site>/public; N="probe-$(openssl rand -hex 12).php"
cat > "$D/$N" <<'PHP'
<?php header('Content-Type: text/plain'); echo PHP_VERSION, ' ', PHP_SAPI, "\n";
foreach (['memory_limit','post_max_size','upload_max_filesize','session.upload_progress.enabled','fatal_error_backtraces'] as $k)
  echo $k, ' = ', var_export(ini_get($k), true), "\n";
PHP
curl -s "https://<domain>/$N"; rm -f "$D/$N"; ls "$D/$N" 2>/dev/null && echo "NOT REMOVED"
```

Note: `PHP_VERSION` shows the upstream number (for example `8.3.6`) even when the distro has patched it. The changelog check in section 2 is the proof.

## 6. Traps on this stack

- **Several versions installed.** Sites can point at different sockets. Patch and mitigate every version that serves a site.
- **CLI and FPM read different ini files.** `php -i` proves nothing about FPM.
- **Mixing Surý and distro packages** for one version causes dependency fights. Stay with one source per version.
- **unattended-upgrades** usually allows only the distro security origin. Surý updates are not installed by it unless you added that origin. Check `/var/log/unattended-upgrades/` and `apt-mark showhold`.
- **A pool or `.user.ini` sets `memory_limit` back.** `php_admin_value` in the pool wins over `.user.ini` and `ini_set()`.
- **mod_php and FPM both enabled.** `apache2ctl -M` shows which one actually serves `.php`.

## Sources

- https://www.php.net/ (21 and 23 Oct 2026 advisories)
- https://security-tracker.debian.org/tracker/
- https://ubuntu.com/security/cves
- https://deb.sury.org/ and https://launchpad.net/~ondrej/+archive/ubuntu/php
