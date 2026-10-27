# 4. How it works

The full check (`secure-my-server`) works in **8 phases**, always in this order. Each phase has its own detailed file in `skills/secure-my-server/references/`.

The PHP2Shell skill (`php2shell-response`) is a shorter version of the same idea: look → check for a break-in → stop the bleeding → patch → prove it → report. It can do the read-only steps on many servers at the same time.

**Where the "every server is different" part lives:** phase 1 runs `scripts/detect_stack.sh` and `scripts/php_runtimes.sh`. They say, for example, "cPanel, Apache, three PHP versions, no Docker". Claude then opens only the matching files in `guides/`, such as `guides/php/cpanel-whm.md`, and follows those commands instead of guessing.

```
1. Look around      →  2. Check for break-in  →  3. Close open doors
        ↓
4. Make apps safer  →  5. Change the keys     →  6. Make deploys safe
        ↓
7. Second check by another Claude  →  8. Write it all down
```

---

## Phase 1: Look around (read-only)
**Question:** *What is running here, and what can the internet reach?*
- Find out how the server is built: control panel, web server, every PHP, Docker, firewall.
- List every open port, and every Docker container if there is Docker.
- Find the web server that is really live (sometimes there are **two** nginx programs!).
- Find every settings file that holds secrets (`.env`).
- Find out how each app gets to production.

**Nothing changes in this phase.**
File: `references/01-inventory.md`

## Phase 2: Check for a break-in (read-only)
**Question:** *Did anyone already get in?*
- Look at the logs **before** restarting anything, because restarting a container deletes its logs.
- Check databases and Redis for strange users, settings or data.
- Look for unknown PHP files, new admin users, unknown SSH keys, strange scheduled tasks, unknown programs.
- Look in the logs for the shape of the attack.

If Claude finds real signs of a break-in, it **stops and tells you** before changing anything.
File: `references/02-compromise-checks.md`

## Phase 3: Close open doors
**Question:** *Can the internet reach things it should not?*
- Make databases and Redis reachable **only from inside the server**.
- Add a firewall rule as a second layer. (On Docker servers, published ports skip the normal firewall: this surprises everyone.)
- Remove default passwords like `changeme`.

File: `references/03-hardening.md` (part 1)

## Phase 4: Make the apps safer
- **PHP:** hide error details and version numbers, and switch off risky unused features.
- **Front web server:** limit request size and speed, and block broken uploads (the attack's shape).
- **Logs:** keep them in a safe place, so a restart does not delete them.
- **Debug mode:** off on every site the internet can see.

File: `references/03-hardening.md` (part 2)

## Phase 5: Change the keys
- Make a list of **every secret** in every project, **without showing any of them**.
- Find keys that are **shared** (for example the test site and the live site using the same key; that is bad).
- Split the list: keys **we** change, and keys the **client** must make new.
- Change ours safely, so nobody gets logged out and nothing breaks.
- Check git: were keys ever written into the code?

File: `references/04-secrets.md`

## Phase 6: Make deploys safe
**Question:** *Will the next deploy undo our fixes or break the site?*
- Read every deploy script.
- Check that the live code really is in git. (Sometimes it is not!)
- Fix scripts that would delete important folders.

File: `references/05-deploy-safety.md`

## Phase 7: Second check
Another Claude gets **only the list of problems and a checklist**. It is **not** told what was fixed, so it checks for real instead of agreeing.

File: `references/06-verification.md`

## Phase 8: Write it down
- A final table: problem → change → where → proof → still open.
- Simple-English documents for the team.
- A short message and a key-request email for the client.

File: `references/08-communication.md`

---

## The most important file: the traps

`references/07-traps.md` lists **every mistake we made or nearly made**. For example:
- restarting a container instead of recreating it, which crashed the site in a loop;
- a stop signal the program ignored, which caused 11 minutes of downtime;
- a backup filter that caught today's backups, because `cp -p` keeps the old date;
- editing a settings file in a way the running container could not see.

Claude reads this file so it does **not** repeat them.

Next: [05 – Safety rules](05-safety-rules.md)
