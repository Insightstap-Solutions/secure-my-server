# 3. How to use

## Just ask

In Claude Code, ask in your own words. For example:

> "Check all my servers for PHP2Shell: `web1`, `web2`, `shop`. `shop` is production."

> "A new PHP security bug came out. Check our server `ssh prod-box` and fix what's needed."

> "Audit `ssh client-vps` for security. It has two Docker apps. Don't touch the one in /root/legacy."

> "Our Redis might be open to the internet. Can you check the whole server?"

Claude picks the right skill by itself. You can also call one directly:
- `/secure-my-server:php2shell-response web1 web2`: only the PHP2Shell problem, on one or many servers;
- `/secure-my-server:secure-my-server myserver`: the full safety check of one server.

---

## What happens next (what you will see)

1. **Claude asks you a few questions** (see the list in [02 – Install](02-install.md)). Answer them once.
2. **Claude looks around (read-only).** It finds out how the server is built (control panel, web server, every PHP, Docker, firewall) and lists the apps, open ports and secret files. Nothing changes yet.
3. **Claude checks for a break-in.** If it finds signs of one, it **stops** and shows you the evidence first.
4. **Claude shows you a plan** and asks before every risky step:
   - "May I restart the production database?"
   - "May I delete these 35 old backup files?"
   - "May I deploy this to production?"
5. **Claude fixes things** one environment at a time: test → staging → production.
6. **A second Claude checks everything again.** It is not told what was fixed, so it cannot just agree.
7. **You get the final report** and simple documents.

---

## How long does it take?

- PHP2Shell only, one server: often **under an hour**, plus your approvals.
- A full check of a small server with one app: about **2–4 hours**.
- A server with several apps and environments: **a full day**.
- Most of the waiting is for **you** (approvals) and for **the client** (new keys).

---

## Tips

- **Say who owns what.** "Project X is ours. Project Y belongs to another team: report only."
- **Say what you accept.** If you want SSH password login to stay, say so. Claude records it and moves on.
- **Answer approval questions quickly.** Claude waits for you before production steps.
- **Don't paste secrets into the chat.** The skill never needs you to.

---

## When NOT to use this skill

- Writing new app features (it is not a coding skill).
- Reviewing a single pull request for bugs (use a code-review skill).
- A server you do not have permission to change. **Get permission first.**

Next: [04 – How it works](04-how-it-works.md)
