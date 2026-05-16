<!-- [scrai:start] -->
## canary

| File | Summary |
| --- | --- |
| customer_loop_synthetic.sh | Stub summary for customer_loop_synthetic.sh. |
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

| Directory | Summary |
| --- | --- |
| contracts | This directory contains infrastructure validation contracts that test critical system components: EC2 firewall port coverage, Lambda canary invocation functionality, and OAuth redirect URI handling. |
<!-- [scrai:end] -->
