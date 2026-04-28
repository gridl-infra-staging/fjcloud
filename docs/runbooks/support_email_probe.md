# Support Email Probe (support@flapjack.foo)

**Status:** stub created during T0.5 audit. Manual operator probe today; T1.10 will automate every 6h.

## Why this matters

`SUPPORT_EMAIL` (today: `support@flapjack.foo`) is referenced across the customer-facing UI. Every login screen, error page, password-reset email, and onboarding flow tells users "email support@flapjack.foo". If the address silently bounces or routes to a black hole, every beta user effectively has no escape valve — they will churn before opening a ticket.

The 2026-04-26 morning Workspace migration changed the MX records. Re-verifying delivery post-flip is the operator-side T0.5 audit.

## Probe procedure (manual, run before any beta customer onboards)

### Send

From an external email account (Gmail / Outlook / Proton / any non-Workspace account):

```
To:       support@flapjack.foo
From:     <your external address>
Subject:  T0.5 probe — fjcloud beta readiness — <ISO timestamp>
Body:     <repeat the timestamp + a unique nonce so you can search for it>
```

The unique nonce in the subject and body is what makes this discriminating: when you go look in the Workspace inbox, search for the exact nonce string. If the nonce isn't found, the message did not arrive (or arrived in spam).

### Verify (within 60s)

1. **Inbox check:** open the Workspace inbox for `support@flapjack.foo`. The probe must appear within 60 seconds.

2. **Spam check:** if the message is not in the inbox, check the Spam folder. A probe in Spam is a partial pass — delivery works but Workspace is suppressing legitimate support requests, which is its own problem. Adjust spam filters until the probe lands in inbox.

3. **Headers check (optional but recommended):** open the message, view headers, confirm:
   - `Authentication-Results: mx.google.com; dkim=pass spf=pass dmarc=pass` — if any of these are `fail`, fix DNS records before onboarding.
   - The `Received:` chain shows the message reached Google's MX without intermediate rewrites.

### What "pass" means

- Probe arrives in inbox within 60s. ✅
- Probe arrives in spam → fix spam filters, re-probe. ⚠️
- Probe never arrives within 5 minutes → MX/DNS misconfigured, do NOT onboard customers until fixed. ❌

## Diagnostic checklist if the probe fails

1. **MX records:**
   ```bash
   dig +short MX flapjack.foo
   ```
   Should return Google Workspace MX (`*.googlemail.com` or `aspmx.l.google.com`).

2. **SPF / DKIM / DMARC:**
   ```bash
   dig +short TXT flapjack.foo | grep -i 'v=spf'
   dig +short TXT _dmarc.flapjack.foo
   dig +short TXT google._domainkey.flapjack.foo
   ```
   All three should resolve. SPF must include `_spf.google.com`. DMARC should be at least `p=none` (and ideally `quarantine` or `reject`).

3. **Workspace routing rules:** a misconfigured "send to other system" rule could be silently swallowing inbound. Open Workspace Admin Console → Apps → Google Workspace → Gmail → Routing.

4. **Recent MX-change propagation:** DNS TTLs can take up to a few hours to propagate globally. If the migration was very recent (<6h), retry from a different network / mobile carrier.

## When to re-run this probe

- **Always before a customer beta cohort onboards.** Tier 0 sign-off requires this.
- **After any DNS change** affecting flapjack.foo MX, SPF, DKIM, or DMARC.
- **After any Workspace admin change** affecting routing or filtering for support@.
- **After any ESP change** (e.g. switching out SES outbound vendor).

## Handoff to T1.10 (automated probe)

T1.10 ([apr26_3pm_1_operator_tooling_gaps_pre_beta.md T1.10](../../chats/apr26_3pm_1_operator_tooling_gaps_pre_beta.md)) automates this probe at 6h cadence. Automation will:

1. Reuse the existing `test.flapjack.foo` SES outbound→inbound test-inbox path to prove the SES/DNS/auth-headers mail chain still works end-to-end.
2. Page via Slack/Discord webhook on failure.
3. Keep real Workspace `support@flapjack.foo` inbox placement as a separate manual/operator check until a later stream adds a trustworthy mailbox-readback seam.

Until T1.10 ships, this manual procedure is the contract. Run it before any onboarding event.

## Probe log

Append a line per probe so the audit history is greppable. Format: `<ISO timestamp> | <result: PASS|FAIL|SPAM> | <prober> | <notes>`.

```
# Example:
# 2026-04-26T18:00:00Z | PASS | stuart | post-Workspace-MX-flip; lands in inbox <60s; DKIM/SPF/DMARC all pass
```

(The first real entry goes here once T0.5 is run by the operator.)
