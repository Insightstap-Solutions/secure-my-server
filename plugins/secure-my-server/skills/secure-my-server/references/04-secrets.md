# Phase 5: Secrets

Goal: know every secret, find the shared and weak ones, rotate the ones we control, and hand the owner a clear list for the rest. **Never print a value.**

## 1. Inventory
Run `scripts/env_inventory.sh` over every **live** env file (`--help` shows how to pass the files):
```bash
ssh host 'sudo -n bash -s' < scripts/env_inventory.sh | column -t -s'|'
```
Each output line is `project | KEY | class | group`:
- **class:** `empty`, `PLACEHOLDER/WEAK`, `STRIPE-LIVE-SECRET`, `stripe-test`, `webhook-signing-secret`, `set`, `set(short:N)`;
- **group:** `G1…` when the **same value** appears in more than one project or env.

**How to read the result:**
- Prod and staging sharing APP_KEY or DB passwords means **staging can forge prod** cookies and signed links.
- One AI key in several projects means one rotation has to be applied in N places.
- Prod, staging and dev sharing a JWT `SECRET_KEY` means a dev token works on prod.
- `REDIS_PASSWORD=null` / empty means no auth.

Also check that the password a container was **created** with matches the env file, without printing it:
```bash
docker exec <c> sh -c 'printf %s "$POSTGRES_PASSWORD"' | grep -cxF -- "$pw"
```

## 2. Who rotates what
- **We rotate:** framework keys (APP_KEY, SECRET_KEY), DB, Redis and root passwords, webhook basic-auth values we chose, internal tokens.
- **The account owner reissues:** keys that come from someone else's account, for example payment (secret key + webhook signing secret), online store, email delivery, AI providers, file storage, CAPTCHA, maps, SMS. Go through the env files and list each one.
- **Ask** who owns uncertain accounts before writing the client email (`08-communication.md`).

## 3. Rotation recipes
All of them: back up first, write the env file **in place** (trap T5), and check there is no running compose for the project.

### MySQL in Docker (Laravel example): `scripts/rotate_mysql_laravel.sh`
Other stacks follow the same order: change the password in the database, write it to the app's config, restart the app, verify, then remove the old one from any other place.
1. `ALTER USER IF EXISTS` for the app user, `root@%` and `root@localhost` (SQL on stdin, `MYSQL_PWD`).
2. Write the env file in place.
3. Recreate `mysql` (its healthcheck has the root password baked in, trap T18).
4. **Recreate** (not restart) app → scheduler → queue (trap T3).
5. Verify: `current_user()` from the app, old root refused, new root works, login page 200.

The expected error window on prod is about 30 s.

### Postgres
- `ALTER ROLE "<user>" PASSWORD '…'` over the container's local socket.
- Replace the value **everywhere** in the env file (`POSTGRES_PASSWORD` **and** `DATABASE_URL`), then recreate the API service.
- **Verify over TCP to the container IP:** the local socket is often `trust`, so a local check proves nothing.

### Redis
- Compose: `--requirepass "${REDIS_PASSWORD:?}"`.
- **The ordering trap (T6):** the app and Redis must switch together. Write the env value **immediately before** the deploy that recreates both. Add a deploy pre-flight, and a branch guard that refuses a compose file without `--requirepass`.
- Verify: NOAUTH without the password, WRONGPASS with the old one, PONG with the new one; the app's own client ping; cache put/get; a session round trip.

### Laravel APP_KEY: `scripts/rotate_laravel_app_key.sh`
1. **Find what the key protects:** `'encrypted'` / `'encrypted:array'` casts, `Crypt::`, `hash_hmac` with `app.key`, 2FA secrets. Count the encrypted rows.
2. **Confirm** the framework honours `APP_PREVIOUS_KEYS` for **both** encryption and URL signing (Laravel ≥ 11):
   ```bash
   grep previous_keys vendor/laravel/framework/src/Illuminate/{Routing/RoutingServiceProvider,Encryption/EncryptionServiceProvider}.php
   ```
3. Set `APP_KEY=<new>` and `APP_PREVIOUS_KEYS=<old>`, then recreate app, scheduler and queue.
4. **Re-encrypt** each encrypted column: set the attribute through the model, then write the raw value with the query builder (a plain `save()` does not mark it dirty).
5. Verify that a value encrypted with the old key still decrypts.
6. **Remove `APP_PREVIOUS_KEYS` after about 7 days.** Put the date in the report.

**Side effect:** open Livewire pages fail their checksum once; a refresh fixes it. Do this at low traffic.

**For an env that must stop holding another env's key** (staging had prod's key): re-encrypt, then remove the previous key **straight away**.

### JWT / app SECRET_KEY
Grep every place it is used. If it only signs tokens, rotating it means users log in again. Give each env its own value.

### Third-party keys
Install the new key → test the integration → only then tell the owner to delete the old one.

## 4. Secrets in git
1. Build a needle file of **real values** from the server env files, with `umask 077` (values ≥ 16 chars, no placeholders, and no plain `redis://host:port/db` URLs).
2. Run `scripts/secret_scan_repo.sh <repo> <needles>`. It also checks patterns (`sk-ant-`, `sk-proj-`, `standard_<hex>`, `sk_live_`, `whsec_`, `pcsk_`, `AKIA`, private keys). **Delete the needle file afterwards.**
3. Map each hit to a key name and env without printing it. Many hits are false positives: `.env.example` placeholders, and plain URLs.
4. Redact real hits with `[REDACTED]` and re-scan to 0. The usual places are committed AI chat logs (`*.jsonl`) and code-review notes.
5. Check history: `git log --all --oneline -- <path>` for env files that were once tracked.

**Redaction is not rotation.** History and every clone keep the key, so **rotate first**. Rewriting history (`git filter-repo` + force-push + everyone re-clones) is the team's decision.

**History-rewrite hazard (T11):** if the remote branch was already rewritten, an old server clone still holds the un-redacted history. Base new work on the remote's cleaned branch.

## 5. Clean-up
- Delete old env backups **by filename date** (not mtime: `cp -p` keeps the old date, trap T7). List them, ask, then delete.
- Keep today's backups for about 7 days, as a way to undo.
- Old checkouts and rsync copies with env files: ask the owner, then delete.
