# 1. What is this?

## The short answer

This is a **plugin** for Claude Code. A plugin is a package you install once. This one holds:

- two **skills**. A skill is like a **checklist plus a toolbox** that Claude reads before doing a job:
  - **`php2shell-response`**: find and fix the October 2026 PHP2Shell security hole on all your servers;
  - **`secure-my-server`**: a full safety check and clean-up of one server;
- one **agent**, `server-verifier`: a second Claude that checks the work again, without being told what was done;
- **scripts** that look around a server without changing anything;
- **guides** for each kind of server setup.

The job of all of it:

> **Make a server safe, step by step, without breaking anything.**

**Every server is different.** One runs cPanel, one runs Docker, one runs plain Ubuntu with Apache. So the plugin **looks first** at how each server is built, and then follows the steps for that kind of server.

---

## Why we made it

One of our servers was attacked in October 2026.

- A new weakness in PHP was made public, and attackers started using it the same day.
- When we checked the whole server, we found **more problems** than the attack itself:
  - databases open to the internet, with the password `changeme`;
  - debug pages showing code to anyone;
  - the same secret key used on live and test sites;
  - a hidden link that skipped all our protections;
  - a deploy script that would have **deleted live code** on the next deploy.
- Fixing it took a full day and many steps, and **we made some mistakes on the way**. One of them took the live site down for 11 minutes.

We do not want to learn all of that again on the next server. So we wrote it all down, and turned it into this plugin.

---

## A simple picture

Think of a server as a **house**.

| House | Server |
|---|---|
| Doors and windows | Ports (numbered doors on the server) |
| The front door with a guard | The web server at the front (nginx, Apache, LiteSpeed…) |
| Rooms inside | The apps (sometimes each in its own Docker container) |
| Keys | Passwords and API keys |
| A spare key under the mat | A secret written in a file or in git |
| A side door with no guard | A port or tunnel that skips the web server |
| The alarm and camera | Logs |

The plugin walks around the house, checks every door, changes the locks, and makes sure the cameras keep recording.

---

## Who is this for?

- **Developers** who look after a server.
- **Claude Code**, which follows the steps.
- Anyone who needs to answer: *"Is our server safe? What do we have to fix?"*

You do **not** need to be a security expert. Claude explains each step, and asks you before anything risky.

---

## What you get at the end

At the end you get:

1. **A table:** each problem, what changed, where, the proof (command and output), and what is still open.
2. **A list of keys:** which ones **we** change, and which ones the **client** must make new.
3. **Simple documents** for your team, in very easy English.
4. **Ready messages** for the client (a short chat message, and a key-request email).

Next: [02 – Install](02-install.md)
