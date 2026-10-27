# Phase 8: Reports and messages

## 1. Final report
Use the template in `SKILL.md` ("Final report"). Every "fixed" needs **proof**: the command and its output. "Still open" items need an owner and a date.

## 2. Team documents (very simple English)
Create a folder like `docs/security/<date>-<short-name>/` with:
- `README.md`: the short story, a glossary of words (port, container, Redis, rotation…), the timeline, what was affected, a fix table, and lessons as rules.
- `OPEN_ITEMS_EXPLAINED.md`: each open item with **what it is**, a **simple example** (house, doors, keys), **what could happen**, **how to fix it**, **time**, **who**. Split it into "Done" and "Still open".

Ask before committing these. They contain internal paths, and must never contain secrets.

## 3. Message to a non-technical client (chat, short)
> Hi [Name],
>
> On [date], a serious new weakness in [software] called "[name]" was made public, and on [date] our server was attacked using it. Because of this, we ran a full security check of the whole server, which found several vulnerabilities[ and showed that attackers had got limited access to one internal system of X].
>
> The good news: so far we have found no evidence that any data was stolen, and no harmful software was able to run.
>
> We are treating this as our top priority and fixing it before any new feedback items. Right now we are:
> • updating the server software;
> • hiding technical details from visitors;
> • switching off unused risky features;
> • adding request limits and filters;
> • locking down internal systems, with an extra firewall layer;
> • keeping activity records safely;
> • watching the server closely.
>
> We will give you an update very soon.
>
> As a safety step, all passwords and access keys also need to be changed, including the ones in your accounts (Stripe, Shopify, …). We'll change the ones we manage ourselves. For the rest we need your help, and we're sending you an email now with the full list and simple steps.

**Rules:**
- Say "we are fixing" until the work is verified, then "fixed".
- **Don't claim the attack created weaknesses that existed before it.** "The attack led us to run a full check, which found…" is honest and still gets the priority.
- No jargon: no "ports", "containers" or "CVE numbers" unless the client is technical.

## 4. Key-request email to the account owner
```
Subject: Action needed: please reissue API keys for [platforms]

Hi [Name],

[2–3 calm sentences: what happened, that we found no sign of a break-in,
and that we are changing every key as a precaution.]

We are changing everything we control ourselves (server passwords, database
passwords and internal signing keys). The keys below come from your own
accounts, so we need you, or whoever manages each account, to create new ones.

[PLATFORM 1]
1. Stripe: roll the live secret key and the webhook signing secret
   (Developers > API keys > Roll key; Developers > Webhooks > endpoint > Roll secret).
   If Stripe offers an expiry for the old key, 24 hours is fine.
2. …

How to send them: please do not send keys by plain email. Share them through a
password manager or a one-time secret link, or we can join a short call and
enter them together.

What happens next: as soon as each key arrives, we will install it, confirm the
platform works, and then you can delete the old key. There will be no downtime
and users will not be logged out.

Best regards,
[Name]
```

## 5. Effort list (if the client is billed)
Write `item -> N hr`, grouped by project, with a total. Mark the hours as **estimates**. Leave out internal incidents the client message does not mention, unless the user wants them in.
