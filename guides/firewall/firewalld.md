# firewalld (RHEL, AlmaLinux, Rocky, Fedora, some others)

firewalld manages rules in **zones**. Each network interface belongs to one zone. **It does not filter ports that Docker publishes** the way you expect; for those, also read `docker.md`.

**Safety:** firewall changes can lock you out. Ask the human first. Keep a second SSH session open. Back up `/etc/firewalld/` first: `cp -a /etc/firewalld /root/firewalld.bak-$(date +%Y%m%d-%H%M%S)`.

## 1. See what is open

```bash
firewall-cmd --state
firewall-cmd --get-active-zones                 # which zone each interface is in
firewall-cmd --list-all --zone=public           # services, ports, rich rules of that zone
firewall-cmd --list-all-zones | less            # everything
ss -ltnup                                       # what actually listens
```

A service on `127.0.0.1` / `[::1]` is local only. `0.0.0.0`, `*` or `[::]` is every address.

Test from **outside**, IPv4 and IPv6:

```bash
nmap -Pn -p 1-65535 <public-ipv4>
nmap -6 -Pn -p 1-65535 <public-ipv6>
```

## 2. Restrict a port

Best first: make the service listen on `127.0.0.1` only.

**Runtime vs permanent.** A plain `firewall-cmd` change is runtime only: lost on reload or reboot. `--permanent` changes only the saved config: not active until `--reload`. Work like this:

1. Make the change at runtime. Check you can still open a new SSH session.
2. Save it: `firewall-cmd --runtime-to-permanent`.

Examples:

```bash
firewall-cmd --zone=public --remove-port=8080/tcp          # close a port
firewall-cmd --zone=public --remove-service=mysql          # close a service
# allow SSH from one address only (example address):
firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="203.0.113.10/32" service name="ssh" accept'
firewall-cmd --zone=public --remove-service=ssh            # only AFTER the rule above works
```

An added rule can expire on its own while you test: add `--timeout=300` (runtime only).

**Safety net:** schedule a reload of the saved config, which undoes runtime changes; cancel it when you are sure:

```bash
echo 'firewall-cmd --reload' | at now + 5 minutes      # 'atq' / 'atrm <id>' to cancel
```

## 3. Persistence

```bash
firewall-cmd --runtime-to-permanent
firewall-cmd --check-config        # checks the saved XML config
firewall-cmd --reload
systemctl is-enabled firewalld
```

Saved config lives in `/etc/firewalld/zones/*.xml`.

## 4. Verify

- `firewall-cmd --list-all --zone=<zone>` matches what you meant, and so does `firewall-cmd --permanent --list-all --zone=<zone>` (runtime and permanent agree).
- From outside: only the ports you meant, on IPv4 **and** IPv6.
- A **new** SSH session works.

## 5. Traps

- **Wrong zone.** You changed `public`, but the interface is in another zone. Check `--get-active-zones`.
- **Runtime only.** It looks fixed, then a reboot or `--reload` brings the port back. Always `--runtime-to-permanent`.
- **Docker.** Docker creates a `docker` zone (target `ACCEPT`) for its bridges and publishes ports through its own NAT rules. Do not assume rules on `public` stop a published port; test from outside (see `docker.md`).
- **Rich rule family.** A `family="ipv4"` rule does nothing for IPv6. Add an `ipv6` rule too when needed.
- **Cloud firewalls** (provider security groups) are a separate layer. Check them too.

## Sources

- https://firewalld.org/documentation/man-pages/firewall-cmd.html
- https://firewalld.org/documentation/man-pages/firewalld.richlanguage.html
- https://docs.docker.com/engine/network/packet-filtering-firewalls/ (Docker and firewalld)
