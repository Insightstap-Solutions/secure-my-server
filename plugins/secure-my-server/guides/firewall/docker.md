# Docker-published ports and the host firewall

**The problem:** a port published with `-p 5432:5432` (or `ports: ["5432:5432"]` in compose) is open to the internet even when ufw or firewalld says "deny". Docker rewrites the destination (DNAT) before the host's INPUT rules run. The packet then goes through the **FORWARD** path, where Docker's own rules accept it. ufw's and firewalld's normal rules never see it.

**Safety:** ask the human before changing compose files on production, before recreating containers, and before any firewall change. Back up every file first (`cp -p f f.bak-$(date +%Y%m%d-%H%M%S)`).

## 1. See what Docker publishes

```bash
docker ps --format 'table {{.Names}}\t{{.Ports}}'
ss -ltnp | grep -E 'docker-proxy|:5432|:3306|:6379'
```

| `docker ps` shows | Meaning |
|---|---|
| `127.0.0.1:5432->5432/tcp` | local only. Good. |
| `0.0.0.0:5432->5432/tcp` and `[::]:5432->…` | open on every IPv4 and IPv6 address. |

With no host address in the mapping, Docker publishes on `0.0.0.0` **and** `[::]`. Even on an IPv4-only bridge network, the default userland proxy maps the host's IPv6 addresses to the container's IPv4 address. So check IPv6 too.

## 2. The fix: bind to loopback

In each compose file, for every database, cache and internal app port:

```yaml
ports:
  - "127.0.0.1:5432:5432"
```

Before you change an app port, check:

- the reverse proxy reaches it through `127.0.0.1`, not the public IP;
- no frontend code or other server calls `http://<public-ip>:<port>`;
- containers reach each other by **service name**, not the host IP.

If something really uses the port from outside, stop and ask.

Recreate only those services, with the **same** project name, files and env file the containers were created with (read `docker inspect` labels):

```bash
docker compose -p <proj> --env-file <env> -f <file> up -d --no-deps --no-build --dry-run <svc>
docker compose -p <proj> --env-file <env> -f <file> up -d --no-deps --no-build <svc>
```

A database service that nobody outside needs should have **no** `ports:` at all.

## 3. The belt: a DOCKER-USER rule

`DOCKER-USER` is a chain Docker creates and leaves alone. Its rules run before Docker's accept rules. Packets there are already DNAT'ed, so match the **original** host port with conntrack:

```
-A DOCKER-USER -i eth0 -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport 5432 -j DROP
```

Find the public interface first: `ip route show default` (it may not be `eth0`).

| Host firewall | Where the rule goes |
|---|---|
| ufw | a `*filter` block with `:DOCKER-USER - [0:0]` and the rules, appended to `/etc/ufw/after.rules` **and** `after6.rules`, then `ufw reload`. Template: `templates/firewall/docker-user.rules`. |
| firewalld | firewalld's direct interface, for example `firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 <rule>` (verify on your system; the direct interface is deprecated in newer firewalld). Docker also creates a firewalld zone `docker` with target `ACCEPT` and puts its bridges there. |
| plain iptables | `iptables -I DOCKER-USER …` plus your persistence method (`nftables-iptables.md`). Mind boot order: the chain exists only after Docker starts. |

Dry-run a rules block before loading it: `iptables-restore --test -n < block` (and `ip6tables-restore` for IPv6).

Check order: `iptables -S FORWARD | head -3` should show `-j DOCKER-USER` near the top.

Newer Docker versions can use an nftables backend instead of iptables (verify on your system with `docker info`). Then the DOCKER-USER chain may not exist; rely on loopback binds (step 2) and read Docker's firewall docs for your version.

## 4. Verify from outside

Run from a laptop or another host, never from the server itself (local traffic takes another path):

```bash
nmap -Pn -p 3306,5432,6379,27017 <public-ipv4>
nmap -6 -Pn -p 3306,5432,6379,27017 <public-ipv6>     # get it with: ip -6 addr show scope global
nc -vz -w3 <public-ipv4> 5432
```

Expected: `filtered` or `closed`, on IPv4 **and** IPv6. Then check the app still works (it reaches the database by service name).

## 5. Traps

- **`ufw deny 5432` looks fine and does nothing** for a published port.
- **Docker's `"ip": "127.0.0.1"` in `daemon.json`** changes the default bind address **only for the default bridge network**. Compose projects use their own networks, so it does not cover them (those take the `com.docker.network.bridge.host_binding_ipv4` network option). It also needs a daemon restart, which restarts containers unless `live-restore` is on. Explicit `127.0.0.1:` binds in compose are the clear fix.
- **Docker older than 28.0.0:** hosts on the same L2 network segment can still reach ports published on `127.0.0.1`. Check `docker version`; on a shared network, add the DOCKER-USER belt or upgrade.
- **`docker restart` keeps the old port mapping.** Port changes need a recreate.
- **Old containers from another compose path** keep their old mappings. Check `docker ps` for every project on the box.
- **Never `docker compose down -v`** to "reset". `-v` deletes volumes: data.

## Sources

- https://docs.docker.com/engine/network/packet-filtering-firewalls/ (published ports skip ufw's rules; firewalld `docker` zone with target ACCEPT; nftables backend)
- https://docs.docker.com/engine/network/firewall-iptables/ (DOCKER-USER runs before Docker's chains; `--ctorigdstport` example)
- https://docs.docker.com/engine/network/port-publishing/ (`0.0.0.0` and `[::]` by default; IPv6-to-IPv4 mapping; `127.0.0.1` binds and the pre-28.0.0 L2 exception; `"ip"` is default-bridge only)
- https://docs.docker.com/reference/compose-file/services/#ports
