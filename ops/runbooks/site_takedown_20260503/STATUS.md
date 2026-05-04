---
created: 2026-05-03
updated: 2026-05-03
---

# Site takedown — 2026-05-03 post v1.0.0 launch review

## What is down

Customer-facing web surfaces — all return NXDOMAIN authoritatively (public resolvers within a few minutes):

- `https://cloud.flapjack.foo/`  (was Cloudflare Pages: marketing + dashboard + signup)
- `https://app.flapjack.foo/`    (was Pages alias)
- `https://flapjack.foo/`        (was prerendered marketing on the API ALB)
- `https://www.flapjack.foo/`    (alias of apex)

The `flapjack-cloud` Cloudflare Pages project still exists and `https://flapjack-cloud.pages.dev/` is still reachable for anyone who knows that URL. Cloudflare API does not allow deleting an active production deployment without project deletion. To fully suppress this residual: either (a) delete the Pages project entirely, or (b) deploy a maintenance HTML over it via `wrangler pages deploy`. Real-world risk is minimal (project name was never linked from anywhere indexable).

## What is NOT down (intentionally preserved)

- **`api.flapjack.foo`** — 200 OK on `/health`. Stripe webhooks continue flowing so the in-flight $1 / $0.50 charge probe state stays consistent. If you also want the API down, delete the api.flapjack.foo CNAME (record id `51203f0d39602dd734d93cd8561101b9` per `dns_records_full_backup.json`) — but be aware this halts webhook delivery and Stripe will retry events for hours.
- **MX records for `flapjack.foo`** — Google Workspace email continues working. Five MX records preserved.
- **TXT records** (SPF, Google site verification, DKIM, etc.) — preserved.

## Why

Critical adversarial review surfaced BLOCKERs that should be fixed before exposing the site to customers:

- Legal pages (Terms, Privacy, DPA) carry "(Draft)" stamps and a banner saying "not a final launch contract"
- Stripe Customer Portal redirect for "Manage billing" + cancel hits hCaptcha → returning customers can't update card
- `/account/export` claims data export but only returns profile (no indexes/keys/invoices/usage)
- Verification email is bare unbranded HTML with no plain-text part → Gmail spam
- No Help/Docs/Support link in dashboard sidebar
- Password minimum is 8 chars with no complexity rule
- Fail-open alerting: if `SLACK_WEBHOOK_URL` / `DISCORD_WEBHOOK_URL` env unset, alerts silently log to stdout
- Webhook idempotency has a TOCTOU race in real Postgres (mocks mask it)

Full audit: see end-of-prior-turn report in chat history.

## Files in this directory

- `dns_records_full_backup.json` — complete pre-takedown snapshot of all 40 zone records (used for record IDs, restore reference)
- `restore.sh` — one-command revert of all 5 changes (4 DNS records + 2 Pages custom domains)
- `STATUS.md` — this file

## Restore

```bash
set -a
source /Users/stuart/repos/gridl-dev/uff_dev/.secret/.env.secret
set +a
bash /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/ops/runbooks/site_takedown_20260503/restore.sh
```
