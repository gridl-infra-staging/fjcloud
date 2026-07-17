# Stripe Live-Mode Dashboard Alert Routing

## Purpose

Provide an operator-only procedure to verify Stripe live-mode dashboard
notifications for dispute, fraud, and payout alert categories by using Stripe
Dashboard test-send actions.

## Scope

- Live-mode Stripe Dashboard notification routing only.
- Dashboard path: `Account -> Settings -> Team & security -> Notifications`,
  plus Radar review queue and Payouts surfaces.
- No API-mode toggles, no webhook reconfiguration, and no live-mode CLI/API
  calls.

## Prerequisites

- Operator is logged into Stripe in **live mode**.
- On-call recipient endpoints (email and/or SMS) are already enrolled in
  Stripe notification preferences.
- Review baseline alerting behavior in [alerting.md](../alerting.md) and
  incident escalation expectations in
  [incident-response.md](../incident-response.md).
- Open the mutable operator checkpoint for this attempt before sending any
  tests.

## Required Alert Categories and Labels

Use the dashboard-visible label text verbatim when you execute the test-send
flow:

- Disputes: `Dispute created` (`charge.dispute.created`)
- Disputes: `Dispute funds withdrawn` (`charge.dispute.funds_withdrawn`)
- Radar/Fraud: `Early fraud warning created` (`radar.early_fraud_warning.created`)
- Radar/Fraud: `Review queue item opened` (`review.opened` / review queue alert)
- Payouts: `Payout failed` (`payout.failed`)
- Payouts: `Payouts paused` (dashboard payout-pause alert label)

If your Stripe dashboard text differs slightly, use the exact live dashboard
label and record that exact wording in the operator-readiness artifact.

## Operator Procedure

1. Open Stripe in live mode and navigate to
   `Account -> Settings -> Team & security -> Notifications`.
2. In the **Disputes** notification section, confirm both dispute alerts are
   enabled:
   - `Dispute created`
   - `Dispute funds withdrawn`
3. Use Stripe's **Send test notification** action for each dispute alert.
4. In the **Radar / Fraud** notification section (Account -> Settings ->
   Team & security -> Notifications, Radar/Fraud subsection), confirm
   `Early fraud warning created` is enabled, then run **Send test
   notification** for that alert.
5. Navigate to Radar review notifications (review queue surface), confirm
   review-queue alerting is enabled for `Review queue item opened`, then run
   **Send test notification**.
6. Navigate to the **Payouts** notification section, confirm both payout alerts
   are enabled:
   - `Payout failed`
   - `Payouts paused`
7. Use **Send test notification** for each payout alert.
8. Record all timing and delivery confirmation fields only in the current
   attempt file under
   `docs/runbooks/operator-readiness/stripe_live_alert_routing/`.
9. Do not add confirmation timestamps or routing verdicts to this runbook.

## Guardrails (Operator-Gate Enforcement)

- Agent must NOT author any `Status: approved-*` line at column 0 in this
  runbook or related stage artifacts.
- Verification timestamp and test-send receipt evidence must come from
  operator-observed Stripe dashboard actions and recipient delivery, not agent
  inference.
- Canary-only, transport-only, or "looks routed" evidence is insufficient; only
  operator-confirmed test-send delivery counts.
