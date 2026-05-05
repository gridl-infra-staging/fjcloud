# Stripe Live Alert Routing Checkpoint (Awaiting Operator Confirmation)

Attempt timestamp (UTC): 20260505T004248Z
Runbook: docs/runbooks/operator/stripe_live_alert_routing.md
Stripe mode: live dashboard

Dispute alert: Dispute created (`charge.dispute.created`)
Test send dispatched at: <ISO>
Test send received at: <ISO>
Recipient channel: <email|sms>
Routing confirmed: <yes|no>

Dispute alert: Dispute funds withdrawn (`charge.dispute.funds_withdrawn`)
Test send dispatched at: <ISO>
Test send received at: <ISO>
Recipient channel: <email|sms>
Routing confirmed: <yes|no>

Fraud alert: Early fraud warning created (`radar.early_fraud_warning.created`)
Test send dispatched at: <ISO>
Test send received at: <ISO>
Recipient channel: <email|sms>
Routing confirmed: <yes|no>

Fraud alert: Review queue item opened (`review.opened`)
Test send dispatched at: <ISO>
Test send received at: <ISO>
Recipient channel: <email|sms>
Routing confirmed: <yes|no>

Payout alert: Payout failed (`payout.failed`)
Test send dispatched at: <ISO>
Test send received at: <ISO>
Recipient channel: <email|sms>
Routing confirmed: <yes|no>

Payout alert: Payouts paused (dashboard label)
Test send dispatched at: <ISO>
Test send received at: <ISO>
Recipient channel: <email|sms>
Routing confirmed: <yes|no>

Operator verification timestamp: <ISO>

Notes:
- This file is the single source of truth for operator confirmation for this attempt.
- Update placeholder fields only after each Stripe dashboard test-send action and recipient confirmation.
