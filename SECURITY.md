# Security policy

## Reporting a problem in this plugin
If you find a bug that could cause harm, for example a script that prints a secret, changes a server when it says it is read-only, or advice that would leave a server open, please **do not open a public issue**. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository. I aim to reply within 7 days.

## Reporting a problem in PHP itself
This project does not handle PHP vulnerabilities. Report those to the PHP project: https://github.com/php/php-src/security

## Using this plugin safely
- Use it only on servers you own or are allowed to administer.
- The detector scripts are read-only, but they read sensitive places (logs, cron, SSH key fingerprints). Their output stays on your machine and in your Claude Code session. Treat it as private.
- Claude asks before any change, restart or deletion. Read what it proposes before you say yes, especially on production.
- The advisory facts in this plugin are dated. Always check php.net for newer advisories.
- This software comes with no warranty (see `LICENSE`).
