---
created: 2026-04-30
updated: 2026-04-30
---

# Stage 6 — old test-mode standard secret key revoked

Operator action via Stripe dashboard at 2026-04-30T23:24:16Z.

## What was done

- Logged into https://dashboard.stripe.com in Test mode
- Navigated: Developers → API keys → Standard keys
- Located the standard secret key whose value ended in `…aTLZ` (prefix `sk_test_51Sy`)
- Rolled the key with **Expires in: Now**, invalidating the old value immediately

## Verification

Post-roll dashboard listing (operator-captured 2026-04-30T23:24:16Z):

- Restricted keys → `fjcloud-staging-2026-04-29`: `rk_test_51SyNWBGXI8zVz4UH…ldbeZ` (Last used: Apr 30, Created: Apr 29) — staging runtime is using the new restricted key
- Standard keys → Secret key: `sk_test_51SyNWBGXI8zVz4UH…OncY` (Created: Apr 30) — post-roll new value, unused (not deployed anywhere)
- Standard keys → Publishable key: `pk_test_51SyNWBGXI8zVz4UH…YxjubE` (Created: Feb 7) — unchanged

The pre-roll old standard secret value `…aTLZ` no longer authenticates against the Stripe API.

## Pre-revoke staging proof (from earlier in this cutover)

Stage 5 already proved the new restricted key works end-to-end against deployed staging:

- `STAGE_5_health_response.txt` — `/health` 200
- `STAGE_5_post_deploy_validate_stripe.json` — `validate-stripe.sh` PASS
- `STAGE_5_stripe_warning_count.txt` — zero `STRIPE_SECRET_KEY not set` warnings in journalctl

Rolling `…aTLZ` was therefore safe; staging continued to authenticate via the new restricted key without interruption.

## Stage 7 (next)

Stage 7 is the summary commit closing out the full Stripe restricted-key cutover bundle (`20260429T183138Z_stripe_cutover/`). No further dashboard action required.
