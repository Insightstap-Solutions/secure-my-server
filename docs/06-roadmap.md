# 6. Roadmap

## Where we are: v0.2.0 (first public release)
- [x] Two skills: `php2shell-response` (focused) and `secure-my-server` (full pass)
- [x] The `server-verifier` agent for an independent re-check
- [x] Read-only detectors: stack, PHP runtimes, exploit logs, web shells, persistence
- [x] Guides for each setup: PHP (Docker, Debian/Ubuntu, RHEL family, Alpine, cPanel, Plesk, aaPanel, DirectAdmin, CyberPanel/OpenLiteSpeed, FrankenPHP, source builds), web servers, firewalls
- [x] Tests against fake servers, shellcheck, repository checks, CI
- [x] MIT licence and icon

## Next: v0.3 (prove it on real servers)
- [ ] Run `php2shell-response` on real servers of each kind: a cPanel box, a Plesk box, a plain Ubuntu box with distro PHP, a RHEL box with Remi, a Docker host. Fix every wrong path or command the guides contain.
- [ ] Run the skill evals (`plugins/secure-my-server/skills/*/evals/`) with `claude plugin eval`, with and without the plugin, and keep the results.
- [ ] Tune both skill descriptions so Claude picks the right one.
- [ ] A "report only" mode: findings table, no changes at all.

## Later
- [ ] Windows/IIS PHP is out of scope today; decide whether to add it.
- [ ] Node and Python dependency checks (`npm audit`, `pip-audit`) in the full pass.
- [ ] A weekly "quick check": ports, PHP versions, certificate expiry, debug mode.
- [ ] Reminders for follow-ups (for example "remove the old app key after 7 days").
- [ ] Submit to the Claude plugin directory.

## How to improve it
1. Use it on a real server.
2. Write down anything that went wrong or was confusing.
3. Add the trap to `plugins/secure-my-server/skills/secure-my-server/references/07-traps.md`, or fix the guide for that setup.
4. Run `tests/run.sh` and `python3 tools/check_repo.py`.
5. Open a pull request (see `CONTRIBUTING.md`).
