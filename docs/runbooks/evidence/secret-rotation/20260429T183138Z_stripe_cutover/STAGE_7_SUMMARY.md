---
created: 2026-04-30
updated: 2026-04-30
---

# Stripe restricted-key cutover — summary

Test-mode cutover from a standard secret key to a scoped restricted key. All 7 stages complete.

## Identity

- Cutover UTC stamp: `20260429T183138Z`
- Old key (revoked): `sk_test_…aTLZ` (standard secret, full API access)
- New key (active): `rk_test_…ldbeZ` (restricted, "Recurring subscriptions and billing" template)
- Restricted key name in Stripe dashboard: `fjcloud-staging-2026-04-29`
- Deployed SHA proving the new key works in staging runtime: `cac1f3ac2d3ccd38d6fae58b73a889d357d3274a`

## Per-stage results

| Stage | Owner | Result | Evidence |
|---|---|---|---|
| 1 prereq gate | `scripts/stripe_cutover_prereqs.sh` | PASSED | [PREREQUISITE_STATUS.md](PREREQUISITE_STATUS.md) |
| 2 SSM rotation | `scripts/stripe_cutover_apply.sh` | PASSED | [STAGE_2_PLAN.md](STAGE_2_PLAN.md), [STAGE_2_ssm_rotation.json](STAGE_2_ssm_rotation.json) |
| 3 deploy with new key | CI (deploy-staging via OIDC) | PASSED | Deployed SHA `cac1f3ac…` |
| 4 validate-stripe.sh against staging | `scripts/validate-stripe.sh` | PASSED | [STAGE_4_validate_stripe_output.json](STAGE_4_validate_stripe_output.json) |
| 5 runtime probe (post-deploy) | health + journalctl + validate-stripe replay | PASSED | [STAGE_5_health_response.txt](STAGE_5_health_response.txt), [STAGE_5_stripe_warning_count.txt](STAGE_5_stripe_warning_count.txt), [STAGE_5_post_deploy_validate_stripe.json](STAGE_5_post_deploy_validate_stripe.json) |
| 6 dashboard revoke of old key | Operator via Stripe dashboard | PASSED | [STAGE_6_revoke_old_key.md](STAGE_6_revoke_old_key.md) |
| 7 summary | This file | PASSED | this file |

## Blast-radius reduction proven

Before: a leaked `sk_test_…aTLZ` would have full Stripe-account API access on test mode (create live products, modify Connect accounts, send payouts in test, etc.).

After: a leaked `rk_test_…ldbeZ` is constrained to the 40-permission "Recurring subscriptions and billing" template scope (Customers, Subscriptions, Invoices, Invoice Items, Setup Intents, Checkout Sessions, Billing Portal Sessions, Payment Methods read, Events read, Webhook Endpoints read). The unused permission categories (Tax, Quotes, Climate, Issuing, Connect, Terminal, etc.) are not in the granted scope.

## Future cutovers

Stage 1-7 contract is reusable for any future Stripe key rotation (test or live). The runbook entry point and per-stage owners are documented in `docs/runbooks/secret_rotation.md` and the operator-facing checklist lives in `OPERATOR_NEXT_STEPS.md` under this directory.

The eventual `rk_live_*` cutover at paid-beta launch follows the same Stage 1-7 template with `BACKEND_LIVE_GATE=1` and live-mode dashboard navigation. No new repo plumbing is needed for that flip.
