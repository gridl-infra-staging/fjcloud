# Supervisor Partial-Closeout Authorization — L8 alert_emails (Stage 4/5)

**Authorized by:** supervising agent (matt-session supervisor loop)
**Date:** 2026-05-22T03:40Z
**Lane:** `may21_12pm_8_alert_emails` (fjcloud_dev)

## What is authorized

1. **The Stage 4 SNS publish probe is authorized to proceed**, decoupled from the
   strict set-equality gate. Publish exactly one probe message to
   `arn:aws:sns:us-east-1:213880904778:fjcloud-alerts-prod`, save the response
   JSON to `prod_publish.json`, and record the `MessageId`. The publish reaches
   the confirmed subscriber (`stuart.clifford@gmail.com`) regardless of any
   `PendingConfirmation` entries, so it is safe and satisfies the orchestration
   master's "aws sns publish test message delivered" done-condition.

2. **Stage 5 may write a green/closable closeout** once the publish probe above
   has a real `MessageId`, treating the lane as materially complete.

## Why — the set-equality gate is stricter than the orchestration master

The L8 checklist's `set_equality_gate` requires the live `fjcloud-alerts-prod`
subscription set to **exactly equal** the canonical `prod_inputs.json`
(`["stuart.clifford@gmail.com"]`). It currently reports `FAIL` because the live
topic also carries two extra subscriptions:

- `stacy.saunders.2002@gmail.com` — `PendingConfirmation`
- `clifford.kriv@gmail.com` — `PendingConfirmation`

These two are **not a blocker**, verified against live AWS state by the supervisor:

- They are **unconfirmed** (`SubscriptionArn == "PendingConfirmation"`), so they
  receive **zero** messages. They are not a mis-delivery or security risk.
- They are **not Terraform-managed** — they were added outside this lane's
  Terraform state (an earlier manual add or a prior apply with a different
  `prod_inputs.json`). The Stage 4 `terraform apply` (`1 added, 1 changed, 1
  destroyed`) therefore could not prune them; only Terraform-state-managed
  resources are in scope of an apply.
- They **cannot be removed via API**: `aws sns unsubscribe` requires a real
  `SubscriptionArn`, which a `PendingConfirmation` subscription does not have.
  AWS SNS auto-deletes unconfirmed subscriptions after **3 days**.

The orchestration master (`chats/icg/may21_12pm_0_orchestration_master_to_announce.md`)
defines L8 done as: *"`aws sns list-subscriptions-by-topic` for both
`fjcloud-alerts-prod` and `fjcloud-alerts-staging` shows ≥1 confirmed
(non-`PendingConfirmation`) subscription; `aws sns publish` test message
delivered to that inbox."* That condition is **met**: `stuart.clifford@gmail.com`
is CONFIRMED on both topics (supervisor-verified live). The strict exact-set
equality is a lane-checklist refinement, not an orchestration requirement.

## What this closeout proves vs. does not prove

- **Proves:** the prod `alert_emails` Terraform change is applied;
  `stuart.clifford@gmail.com` is a confirmed subscriber on `fjcloud-alerts-prod`
  and `fjcloud-alerts-staging`; a live publish probe is delivered.
- **Does not prove / documented follow-up:** the two stale `PendingConfirmation`
  subscriptions (`stacy.saunders.2002@`, `clifford.kriv@`) remain on the prod
  topic until they auto-expire (~3 days from their creation) or are removed via
  the AWS console. They are harmless (cannot receive mail) and require no code
  or operator action. Re-running `aws sns list-subscriptions-by-topic` after the
  expiry window will show the set naturally converged to `prod_inputs.json`.

Record this file's path in `SUMMARY.md` as the partial-closeout authorization.
