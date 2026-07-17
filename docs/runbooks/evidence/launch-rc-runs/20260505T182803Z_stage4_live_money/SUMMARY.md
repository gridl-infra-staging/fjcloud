Stage 4 Live-Money Evidence Summary
timestamp_utc: 20260505T182803Z (started) — 20260505T184300Z (concluded)
head_sha: f01f45fa923193535cd4d0b238bf135cf16433d8

## Verdicts

| Gate | Verdict | Detail |
|------|---------|--------|
| Dry-run canary | PASS | signup, verify, index CRUD, cleanup on deployed staging |
| fjcloud signup/verify/sync | PASS | Two tenants created, verified via SSM, synced to Stripe |
| Live card attach | BLOCKED | hCaptcha + raw card data restriction + PM binding (3 mechanisms) |
| Live invoice/charge/refund | BLOCKED | Privacy.com MC 4338 declined (worked 2026-05-03, failing 2026-05-05) |
| fjcloud tenant cleanup | PASS | Both tenants deleted via admin API |
| Stripe customer deletion | PENDING | STOP-8: operator-only action |
| Live readback verification | NOT REACHED | Blocked by card decline |

## Overall Stage 4 Verdict: BLOCKED

The deployed staging surface successfully completes the autonomous fjcloud-side roundtrip
(signup -> email verify -> Stripe customer sync -> admin cleanup). The live-money portion
is blocked by two independent external factors:

1. **Fresh card attach impossible**: Stripe added hCaptcha to their SetupIntent confirmation
   page since Phase G (2026-05-03). The account lacks raw card data API access (PCI Level 1
   required). PaymentMethods are customer-bound and cannot be reused across customers.

2. **Existing card declined**: The Privacy.com Mastercard (last4 4338) that worked during
   Phase G is now declining with `card_declined` / `incorrect_number`. The card appears
   deactivated or paused at Privacy.com.

## Operator Actions Required to Unblock

1. Reactivate the Privacy.com card ending 4338, OR create a new Privacy.com card
2. If new card: attach it to `cus_URij8h4pXDprIK` via manual browser session (human can solve hCaptcha)
3. Then: run the invoice/charge/refund proof (can be automated once card is working)
4. STOP-8: delete Stripe customers after proof completes

## Artifacts

| File | Content |
|------|---------|
| context_probe.txt | Evidence bundle context fields |
| 01_dryrun_preflight.txt | Dry-run canary environment and result |
| 03_live_key_preflight.txt | Live key verification and card identity |
| 04_live_flow.txt | Full live flow transcript with all phases and blockers |
| 06_tenant_cleanup.txt | fjcloud tenant deletion proof |
| 08_card_status_followup_probe.txt | 20260505T184959Z re-probe of PM 4338 — still card_declined/generic_decline; external blocker confirmed unchanged |

## Stripe Resources for Operator Cleanup

- `cus_USjANpIjWX1zM7` — test-mode customer (synced from staging API)
- `cus_USjFZnH4OX8hWr` — live-mode customer (created directly, no PM attached)
- `seti_1TTnmeGXI8zVz4UHMBwRt5Df` — live SetupIntent (never confirmed)
- `cus_URij8h4pXDprIK` — Phase G customer (voided invoice `in_1TTntTGXI8zVz4UHrNPc7oa0`, 2 failed charges)

## Stage 6 Input

This summary is the Stage 6 launch-verdict input for the live-money proof gate.
The gate cannot close until the card blocker is resolved and the invoice/charge/refund
proof is captured. The fjcloud-side roundtrip is independently proven and does not
need to be re-run.
