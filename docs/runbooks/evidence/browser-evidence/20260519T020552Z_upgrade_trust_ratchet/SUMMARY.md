# Upgrade Trust-Ratchet Evidence

Evidence bundle for the self-service `POST /billing/upgrade` trust-ratchet contracts.

## Contracts Tested

| Contract | Payment Method | Expected HTTP | Evidence Dir |
|----------|---------------|---------------|--------------|
| success-paid | `${UPGRADE_PM_SUCCESS}` | 200 | `success_paid/` |
| declined-402 | `${UPGRADE_PM_DECLINED}` | 402 | `declined_402/` |
| requires_action-402 | `${UPGRADE_PM_REQUIRES_ACTION}` | 402 | `requires_action_402/` |

## Per-Contract Artifacts

Each subdirectory contains:
- `setup.json` — customer_id and stripe_customer_id audit identifiers
- `pre_upgrade_status.json` — `GET /account/upgrade-status` before upgrade attempt
- `upgrade_response.json` — raw response body from `POST /billing/upgrade`
- `upgrade_http_code.txt` — HTTP status code
- `post_upgrade_status.json` — `GET /account/upgrade-status` after upgrade attempt
- `result.json` — pass/fail summary
- `stripe_invoice.json` (success path only) — Stripe invoice confirming paid status

## Trust-Ratchet Verification

- **success-paid**: Plan transitions free→shared, `subscription_cycle_anchor_at` is set, Stripe invoice is `paid`
- **declined-402**: Plan stays `free`, `upgrade_ready` remains `true` (customer can retry), response contains `code: "card_declined"`
- **requires_action-402**: Plan stays `free`, `upgrade_ready` remains `true`, response contains `code: "invoice_payment_intent_requires_action"`
