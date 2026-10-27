# Phase 6: Deploy safety

Goal: the **next deploy** must not undo the fixes, re-open ports, delete data folders, or remove live-only code.

## 1. Read every deploy script
For each app, answer:
- What does it copy, from where, to where?
- Does it use `rsync --delete`? Which excludes?
- Does it overwrite `docker-compose.yml`? The env files?
- How does it build and restart? `up -d --build` of every service?
- Which nginx binary does it reload? (trap T1)

## 2. Is the live code in git? (drift check)
Run `scripts/drift_check.sh` on the server, inside the git checkout:
```bash
ssh host 'bash -s -- /path/to/checkout apps/api/app /live/path/app' < scripts/drift_check.sh
```
It extracts each candidate branch and counts the **code** files that differ from live. Compare code folders only: docs and chat logs inflate the count.

- **A branch with 0 differences:** good. Make sure that branch is the one the deploy uses.
- **No branch matches:** a deploy would **delete live-only code**. Snapshot live into a new deploy branch:
  1. Base it on the **remote** branch, and if the remote history was cleaned of secrets, on the cleaned one (T11).
  2. Rsync live into it, excluding env, data, uploads, logs, temp and caches.
  3. **Secret-scan** before committing (`04-secrets.md` §4).
  4. Commit `chore(prod): snapshot of the code live on <date>`.
  5. Cherry-pick the security fixes.
  6. Push. Do not deploy.

Remember: **`rsync -n` prints nothing without `-i`** (T9). Always use `rsync -anci`.

## 3. Prove the compose file is equivalent to what runs
```bash
docker compose -p <proj> --project-directory <live-dir> --env-file <live-dir>/.env -f <new-file> config | sha256sum
docker compose -p <proj> --project-directory <live-dir> --env-file <live-dir>/.env -f <live-dir>/docker-compose.yml config | sha256sum
```
The two must be identical (or differ only in ways you can explain).

## 4. Fix the deploy scripts
- Exclude bind-mounted data folders (`uploads/`, `logs/`, `temp/`, `.tmp/`), `.well-known/` (ACME challenges), and anything else `--delete` would wipe.
- Use the **right nginx binary** with `-t` first, and `|| exit 1`. Under `set -e`, a failed command inside an `&&` list is ignored.
- Keep empty bind-mounted folders in git with `.gitkeep`.
- Back up each script, run `bash -n` on it, show the diff, **do not run it.**

## 5. Server checkouts with hand edits
Once the fix is merged:
1. Drop the local edits.
2. Fast-forward.
3. Prove that `compose config` is identical before and after.
4. Use `--dry-run` to see whether anything would be recreated.

Do **not** merge into somebody else's feature branch to make the server clean. A conflicting `git pull` is refused, never silently applied.

## 6. Hotfix vs promote
- **If staging holds unreleased features:** don't promote everything for a security fix. Branch from `main`, then open a PR into **both** staging and main.
- **If the user chooses to promote everything:** show them the list of what ships first.

## 7. CI
- **CI that doesn't run** (billing failure, disabled runners) means code merges untested. Report it.
- **A check that has been red for months** trains people to ignore checks. Report it, and suggest fixing or removing it.
- Prove a red check is unrelated: compare the same check on recent commits of the base branch.
