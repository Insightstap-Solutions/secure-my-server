# 2. Install

You need:
- **Claude Code**, installed and working;
- **SSH access** to the server you want to check (for example `ssh myserver` works from your laptop);
- ideally **`sudo` without a password** on that server for your user (`sudo -n true` should work).

---

## Option A: install the plugin (recommended)

In Claude Code, type:
```
/plugin marketplace add ankitraj20616/secure-my-server
/plugin install secure-my-server@secure-my-server
```
Or from a terminal:
```bash
claude plugin marketplace add ankitraj20616/secure-my-server
claude plugin install secure-my-server@secure-my-server --scope user
```
- **`--scope user`** means "for me, in every project". That is what you want: this plugin is for servers, not for one codebase.
- **`--scope project`** puts it in the current project's settings instead, so everyone who opens that project gets it.

## Getting updates

Plugins from outside Anthropic do **not** update by themselves unless you turn it on. Either:
- run `claude plugin update secure-my-server@secure-my-server`, or
- in Claude Code, open `/plugin` → Marketplaces → turn on auto-update.

After an update, type `/reload-plugins` (or start a new session).

## Option B: work on the plugin itself

If you want to change the plugin, clone the repo and add **your copy** as the marketplace. Claude then uses your files directly, with no version bump needed:
```bash
git clone https://github.com/ankitraj20616/secure-my-server
claude plugin marketplace add ./secure-my-server
claude plugin install secure-my-server@secure-my-server --scope user
```
After each change, type `/reload-plugins`.

---

## Check that Claude sees it

Start a new Claude Code session and ask:

> "Which skills do you have for server security?"

You should see **php2shell-response** and **secure-my-server** in the answer. You can also type `/secure-my-server:` and see them in the menu.

---

## Before the first real use

1. Read [05 – Safety rules](05-safety-rules.md). It is short.
2. Have these answers ready (Claude will ask for them):
   - the SSH names of the servers;
   - which apps on it are **yours to change**, and which are **hands off**;
   - which one is **production** for each app, and how it is deployed;
   - risks you **accept on purpose** (for example "SSH password login stays");
   - who owns each outside account (Stripe, OpenAI and so on): **us** or the **client**.

Next: [03 – How to use](03-how-to-use.md)
