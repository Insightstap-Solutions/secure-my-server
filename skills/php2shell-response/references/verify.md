# Proving the fix

"Installed" is not "running". Prove each of these, with the command and its output in the report.

## 1. The running PHP is the fixed one
- Re-run `php_runtimes.sh`: every web runtime `PATCHED` or `PATCHED_VENDOR`.
- Check the **process start time is after the patch** (`ps -o lstart= -p <master pid>`). An FPM master started before the update still runs the old code, even if `php -v` on disk says new. For Docker: the container's `Created` time, and the image's PHP version (`docker exec <c> php -v`).
- mod_php: Apache was **restarted**, not just reloaded with an old binary still mapped. Check `apachectl -M | grep -i php` and the Apache master start time.

## 2. The settings are live in the right SAPI
`php -i` reads the **command-line** settings, which are often a different file. Read the web SAPI:
- FPM: `php-fpm<ver> -i` (loads the FPM ini) plus the pool overrides, or `scripts/fpm_ini_probe.sh <container>` for Docker (asks the running FPM over its socket);
- any SAPI, as a last resort: a phpinfo file with a **random name**, fetched once, **deleted at once**, and the deletion checked (`curl` → 404). Never leave one behind.

Expected: `session.upload_progress.enabled` off, `display_errors` off, `expose_php` off.

## 3. The sites still work
Home page, login, one normal form, and an upload if the site has uploads. Use the public URL (`curl -sS -o /dev/null -w '%{http_code}\n' https://site/`). A `curl` to `127.0.0.1` without the right `Host:` header often gets a 400 from the framework's trusted-host check; that is not a failure.

## 4. Edge rules (if you added them)
From outside the server:
```bash
# empty boundary → 400 from the edge
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: multipart/form-data; boundary=' --data-binary 'x' https://site/
# a normal multipart form → reaches the app (200/302/405/419/422 are all fine; not 400 from the edge)
curl -s -o /dev/null -w '%{http_code}\n' -F 'a=b' https://site/
# oversized body on a non-upload route → 413
head -c 20000000 /dev/zero | curl -s -o /dev/null -w '%{http_code}\n' -X POST --data-binary @- https://site/
```
Run these on production only once each: they show up in the logs. Write down the time, so a later check does not report your own test as an attack.

## 5. Nothing new since the patch
Re-run `php2shell_ioc_scan.sh --since <patch date>` a day later. New FPM crashes after the patch mean something else is wrong: look at them.

## 6. Independent check
For production, ask the `server-verifier` agent to check from scratch. Give it the server list and the problems ("PHP X on server Y was vulnerable; upload progress was on"), not what you did or what you concluded.
