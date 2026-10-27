# Was it already used, and what to do if it was

## 0. Before you change anything: keep the evidence
A patch, a restart or a container recreate destroys evidence: `docker logs` of the old container, the memory of the running process, rotated logs. So first, for every server you will touch:
```bash
sudo install -d -m 700 /root/incident-$(date +%Y%m%d)
cd /root/incident-$(date +%Y%m%d)
# logs of every container you will recreate
docker logs --timestamps <c> > <c>.log 2>&1
docker inspect <c> > <c>.inspect.json
# web and PHP logs that may rotate away
sudo cp -a /var/log/nginx /var/log/apache2 /var/log/httpd . 2>/dev/null   # add your stack's log paths
find . -type f -exec sha256sum {} + > SHA256SUMS
```
Never print the payloads you find. Describe them by pattern, size and hash.

## 1. Choose the window
The exposure starts on the day the box became reachable **and** vulnerable. For this bug that is at most 21 Oct 2026 (public release; exploits followed within two days). If a runtime was patched late, the window ends when its **last old worker** stopped, not when the package was installed.

## 2. Run the three scans
All three are read-only. Use the same `--since` date.

| Script | Looks for | Good to know |
|---|---|---|
| `php2shell_ioc_scan.sh` | FPM crashes (SIGSEGV/SIGABRT), `in Unknown on line 0` memory errors, 502 bursts on POST, multipart without a boundary in JSON logs | Normal access logs do not record Content-Type. **No hits means "nothing found", not "not attacked".** |
| `webshell_scan.sh` | new or changed PHP files, PHP inside upload/storage/cache folders, PHP code in image files, eval/system fed by request data, executables in /tmp | Frameworks use `eval` legitimately in `vendor/`; those are INFO unless new |
| `persistence_check.sh` | new users, uid 0, sudoers, SSH keys, cron, systemd units no package owns, `ld.so.preload`, deleted executables, miners, outbound connections, privileged containers | Every SSH key: **ask the user** whether they recognise it |

Then, by hand, for each web app:
- PHP files in public or upload folders that git does not know: `git ls-files` vs `find`;
- admin users created or changed after the window start (application database);
- the exact log lines around each FPM crash: what request came just before?

## 3. Judge
| Verdict | When |
|---|---|
| **No signs found** | Nothing above, or only scanner noise (404s for `/wp-login.php`, `/.env`, `phpunit/eval-stdin.php` and the like). Say what was checked and what could not be checked. |
| **Suspicious** | Exploit-shaped requests or worker crashes, but no new files, users, keys, cron or processes. Most attempts end here: the attacker tried and either failed or left nothing visible. |
| **Compromised** | A planted file that runs code, an unknown SSH key / user / cron / service, a miner, unexplained outbound connections, or changed application admins. |

Before you call a file a web shell: `stat` it (owner, times), hash it, and check whether it is the team's own tool or test fixture. **Classify, then ask.** Never delete it yourself: it is evidence.

## 4. If it is "suspicious"
1. Patch (the main workflow).
2. Rotate what a successful attacker would have read first: the application's env/config secrets on that server (database passwords, app keys, API keys). Ask the user which keys they own and which belong to a client or a provider account. Install new keys before old ones are revoked.
3. Keep the edge rule and the evidence folder. Check again in a week.

## 5. If it is "compromised"
**Stop and show the user the evidence.** Then propose, and do only with a yes:
1. **Contain:** take the site off the internet or put up a maintenance page; block the outbound addresses you saw; disable (do not delete) unknown keys, users, cron entries and services.
2. **Do not trust the box.** An attacker who ran code as the PHP user may have gone further. The safe answer is a **rebuild**: a fresh server or fresh containers from a known-good image and code from git, with data restored from a backup taken **before** the window, or checked carefully.
3. **Rotate everything** the server could read: every secret in every env file, database users, SSH keys that were on it, deploy keys, and third-party API keys (the owner of each account must reissue those).
4. **Tell the people who must know:** the owner and, if personal data may have been read, whoever handles data-protection notices. That is their decision; your job is a clear, honest summary.
5. Keep the evidence folder until the owner says otherwise.

## 6. Words to use with a non-technical owner
- "No signs found" → "We checked the server for signs that the attack succeeded and found none. Our logs cannot prove it 100%, so we are also changing the passwords as a precaution."
- "Suspicious" → "Attackers tried this hole on our server. We see no sign that they got in, but to be safe we are changing all passwords and keys."
- "Compromised" → "Attackers got access to part of the server. We have contained it and are rebuilding it cleanly. Here is what they could have seen, and what we are doing about it."

Never claim "no data was stolen" when you can only say "we found no evidence".
