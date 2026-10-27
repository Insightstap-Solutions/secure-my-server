# 5. Safety rules

These rules are inside the skill too. They are here so **people** know what to expect.

## 1. Secrets are never shown
- Claude never prints a password or key on the screen, in a report, in a commit or in a pull request.
- To check whether two keys are the same, it compares a **fingerprint** (a short code made from the key), never the key itself.
- If a secret is shown by accident, Claude **says so** and adds it to the "change this key" list.
- **You** should not paste secrets into the chat either.

## 2. Evidence first
Before restarting anything suspicious, Claude **saves its logs and data** to a safe, root-only folder. A restart deletes the logs, and they may be the only proof of what happened.

## 3. Claude asks before these steps
| Step | Why it asks |
|---|---|
| Anything on **production** (deploy, restart, recreate) | Real users are affected |
| Changing a project that is **not yours** | Another team's work |
| **Deleting** files | Cannot be undone |
| **Firewall or SSH** changes | You could get locked out |
| Rewriting **git history** or force-pushing | Everyone has to re-download the repo |
| Anything the **permission system blocked** | A block is a "no" until you say "yes" |

## 4. Back up before editing
Every settings file is copied first, with the date and the reason in the name.

## 5. Check twice
- Claude checks important claims **itself**, even when a helper agent reported them.
- Claude checks whether **another session** is working on the same server at the same time.

## 6. Test, then staging, then production
A fix goes to the test environment first, then staging, and production last, with your OK.

## 7. Keep the repo clean
Never commit secrets, chat logs or client names to a repository.

---

## What YOU should do
- Give clear answers about **ownership** and **accepted risks**.
- Use **long, unique passwords** for anything you decide to leave open (for example SSH password login or the control panel).
- Change the keys the client sends **promptly**. Until keys are changed, they are still a risk.

Next: [06 – Roadmap](06-roadmap.md)
