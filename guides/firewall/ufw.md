# ufw (Ubuntu, Debian)

ufw is a front end that writes iptables/nftables rules. **It does not protect ports that Docker publishes**; for those, also read `docker.md`.

**Safety:** firewall changes can lock you out. Ask the human first. Keep a second SSH session open while you work. Back up `/etc/ufw/` first: `cp -a /etc/ufw /root/ufw.bak-$(date +%Y%m%d-%H%M%S)`.

## 1. See what is open

```bash
ufw status verbose                 # on/off, default policies, rules
ufw status numbered                # rule numbers, for deleting
ss -ltnup                          # what actually listens, and on which address
grep '^IPV6=' /etc/default/ufw     # IPV6=yes, or IPv6 is not filtered by ufw
```

Read `ss` carefully: a service on `127.0.0.1` or `[::1]` is local only. One on `0.0.0.0`, `*` or `[::]` listens on every address.

The real test is from **outside** (laptop or another host), IPv4 and IPv6:

```bash
nmap -Pn -p 1-65535 <public-ipv4>
nmap -6 -Pn -p 1-65535 <public-ipv6>
```

## 2. Restrict a port

Best first: make the service listen on `127.0.0.1` only (its own config). A port nobody listens on needs no rule.

If it must be reachable, allow only who needs it:

```bash
ufw allow from 203.0.113.10 to any port 22 proto tcp     # one admin IP (example address)
ufw limit 22/tcp                                          # rate-limit new SSH connections
ufw deny 3306/tcp                                         # explicit deny (default deny also works)
ufw delete <number>                                       # remove a too-wide rule, by number from 'status numbered'
```

Allow SSH **before** you run `ufw enable` or tighten the default policy:

```bash
ufw allow OpenSSH        # or your SSH port
ufw default deny incoming
ufw default allow outgoing
ufw enable
```

**Safety net for remote work:** schedule an automatic undo, cancel it when you are sure you can still log in:

```bash
echo 'ufw disable' | at now + 5 minutes      # needs the 'at' service; 'atq' / 'atrm <id>' to cancel
```

## 3. Persistence

Rules added with the `ufw` command are saved at once (`/etc/ufw/user.rules`, `user6.rules`) and survive a reboot when ufw is enabled (`systemctl is-enabled ufw`).

Hand-written rules go in `/etc/ufw/before.rules` / `after.rules` (and the `6` versions for IPv6). Test them before loading:

```bash
ufw reload
```

`ufw reload` fails and keeps the old rules if a file has a syntax error. Read its output.

## 4. Verify

- `ufw status verbose` shows the rules you meant, for both v4 and v6.
- From outside: `nmap` shows only the ports you meant, on IPv4 **and** IPv6.
- You can still open a **new** SSH session.

## 5. Traps

- **Docker-published ports bypass ufw.** `ufw deny 5432` does nothing for a container's `-p 5432:5432`. See `docker.md`.
- **`IPV6=no`** in `/etc/default/ufw` leaves IPv6 unfiltered by ufw.
- **Rule order matters.** An earlier `allow` wins over a later `deny`. Use `ufw insert 1 …` for a deny that must come first.
- **Cloud firewalls** (provider security groups) are a separate layer. Check them too.
- **Do not turn the firewall off as a "fix"** for a broken service. Find the rule.

## Sources

- https://manpages.ubuntu.com/manpages/noble/man8/ufw.8.html
- https://help.ubuntu.com/community/UFW
