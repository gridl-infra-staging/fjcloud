<!-- [scrai:start] -->
## canary

| File | Summary |
| --- | --- |
| customer_loop_synthetic.sh | customer_loop_synthetic.sh — staging customer-loop canary owner.

Stage 4 scope in this owner:
- enforce quiet-window short-circuit before any HTTP work
- run signup -> verification -> Stripe setup-intent wiring -> index loop
- enforce deterministic teardown (index, account, admin cleanup)
- dispatch failures only via send_critical_alert. |
| outside_aws_health_check.sh | outside_aws_health_check.sh — one-shot external health probe owner.

This script is the single owner for:
- target URLs
- curl transport flags
- exit-code behavior
- target-specific failure logging

The GitHub Actions workflow is wiring only and must not duplicate probe logic.
Keep the one-shot behavior here: fail immediately when any external target is
unavailable so staging gets a clear outside-AWS outage signal. |
| support_email_deliverability.sh | support_email_deliverability.sh — canary wrapper over inbound roundtrip probe. |
<!-- [scrai:end] -->
