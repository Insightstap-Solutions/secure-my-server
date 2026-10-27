# Plain nftables or iptables

Use this guide when **no** front end (ufw, firewalld, a panel firewall) manages the rules. If one does, use its guide: hand edits under a front end are overwritten or fight with it. Docker adds its own rules; read `docker.md` too.

**Safety:** firewall changes can lock you out. Ask the human first. Keep a second SSH session open. Save the current rules before any change (commands below).

## 1. What is in charge?

```bash
systemctl is-active ufw firewalld nftables netfilter-persistent iptables 2>/dev/null
iptables -V                   # "(nf_tables)" = iptables-nft, "(legacy)" = old backend
nft list tables
```

`iptables-nft` writes into nftables tables. Mixing hand-written `nft` tables with iptables rules works, but both are evaluated: a packet must pass **both**.

## 2. See what is open

```bash
ss -ltnup                                 # what listens, and on which address
nft list ruleset                          # nftables
iptables -S; ip6tables -S                 # iptables, IPv4 and IPv6
iptables -L INPUT -n -v --line-numbers
```

Test from **outside**, IPv4 and IPv6: `nmap -Pn -p 1-65535 <ipv4>`, `nmap -6 -Pn -p 1-65535 <ipv6>`.

## 3. Save before you change

```bash
nft list ruleset > /root/nft.bak-$(date +%Y%m%d-%H%M%S)
iptables-save  > /root/iptables.v4.bak-$(date +%Y%m%d-%H%M%S)
ip6tables-save > /root/iptables.v6.bak-$(date +%Y%m%d-%H%M%S)
```

## 4. Restrict a port

Best first: make the service listen on `127.0.0.1` only.

**nftables:** edit the rules file (`/etc/nftables.conf` on Debian/Ubuntu; `/etc/sysconfig/nftables.conf` on RHEL family (verify on your system)). Example inside an `inet` table's input chain (example address):

```
tcp dport 22 ip saddr 203.0.113.10 accept
tcp dport { 3306, 5432, 6379 } drop
```

Check, then load:

```bash
nft -c -f /etc/nftables.conf && nft -f /etc/nftables.conf
```

An `inet` table covers IPv4 and IPv6 together.

**iptables:** use `iptables-apply`. It loads a rules file and rolls back unless you confirm within the timeout:

```bash
cp -p /etc/iptables/rules.v4 /etc/iptables/rules.v4.bak-$(date +%Y%m%d-%H%M%S)
# edit /etc/iptables/rules.v4, for example:
#   -A INPUT -p tcp --dport 3306 -j DROP
iptables-restore --test < /etc/iptables/rules.v4
iptables-apply -t 60 /etc/iptables/rules.v4
```

Repeat for IPv6 with `ip6tables-restore` / `rules.v6`. IPv4 rules do nothing for IPv6.

## 5. Persistence

| Setup | Saved where | Make it load at boot |
|---|---|---|
| nftables | `/etc/nftables.conf` (Debian/Ubuntu) | `systemctl enable nftables` |
| iptables, Debian/Ubuntu | `/etc/iptables/rules.v4`, `rules.v6` (package `iptables-persistent`) | `netfilter-persistent save` saves the live rules |
| iptables, RHEL family | `/etc/sysconfig/iptables`, `ip6tables` (package `iptables-services`) | `systemctl enable iptables ip6tables` |

## 6. Verify

- The saved file matches the live rules (`nft list ruleset` / `iptables-save`).
- From outside: only the ports you meant, IPv4 **and** IPv6.
- A **new** SSH session works. After the next planned reboot, check again.

## 7. Traps

- **Flushing everything** (`nft flush ruleset`, `iptables -F`) also removes Docker's rules and can cut containers off. Never flush on a Docker host.
- **Policy DROP before an SSH allow** locks you out at once. Add the allow first.
- **IPv6 forgotten.** `iptables` rules do not cover IPv6.
- **Saving at the wrong moment.** `netfilter-persistent save` also saves Docker's dynamic rules, which can conflict at boot (verify on your system). Prefer saving only your own chains on Docker hosts.
- **Cloud firewalls** are a separate layer. Check them too.

## Sources

- https://wiki.nftables.org/wiki-nftables/index.php/Main_Page
- https://manpages.debian.org/stable/nftables/nft.8.en.html (`-c` check mode)
- https://manpages.debian.org/stable/iptables/iptables-apply.8.en.html
- https://manpages.debian.org/stable/iptables-persistent/netfilter-persistent.8.en.html
