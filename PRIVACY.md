# Privacy policy

**Plugin:** secure-my-server (Claude Code plugin)
**Last updated:** 27 October 2026

## In one sentence
The plugin collects nothing, stores nothing and sends nothing anywhere: it runs read-only checks on servers **you** name, over **your own** SSH connection, and the results stay in your own Claude session.

## What the plugin reads
When you ask Claude to check a server, Claude runs the plugin's scripts **on that server** over your SSH connection. To find security problems they read:
- system information: OS, installed packages, running processes, listening ports, firewall rules, Docker containers;
- configuration files of the web server, PHP and the control panel;
- web, PHP and system logs, which can contain **visitors' IP addresses** and request paths;
- account information: **Linux usernames**, password-change dates (never the password hashes), and the fingerprints and comments of SSH keys (a comment is often an **email address**); never the key material;
- application env/config files, to check whether secrets are weak or shared. Only key names, a class (for example "empty", "placeholder", "set") and a short fingerprint are printed, **never a value**;
- file names, sizes, dates and hashes in web folders; **never file contents**.

Some of this can be personal data (usernames, email addresses in key comments, IP addresses in logs).

## Where it goes
- The scripts print their findings to your SSH session. Claude reads that output as part of your conversation, under the terms of your own Claude account.
- The plugin has no server, no telemetry, no analytics and no network calls of its own. It sends nothing to the plugin's author or anyone else.
- Nothing is stored by the plugin. If you choose to save a report, it is saved where you tell Claude to save it.

## What it changes
The detector scripts are read-only. Changes (patching, config edits, restarts) are proposed by Claude and made only after you approve each one.

## Your responsibility
Use the plugin only on servers you own or are allowed to administer, and handle the findings (which may include personal data from your servers) according to the rules that apply to you.

## Contact
Questions about this policy: open an issue at https://github.com/ankitraj20616/secure-my-server/issues. Security problems: see `SECURITY.md`.
