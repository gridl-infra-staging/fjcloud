# Billing Coverage A2 Terminus Evidence Tick

- Timestamp (UTC): 2026-05-25T22:09:59Z
- Bundle path: `docs/runbooks/evidence/billing_coverage_a2/20260525T220959Z_TERMINUS/`
- Scope: close Section 2 rerun-terminus gaps for SCA/requires_action and legacy lifecycle boundary rows.

## Command outcomes

- `cd infra && cargo test -p api --test billing_endpoints_test billing_upgrade_402_on_requires_action_and_rolls_back_free_plan -- --nocapture --test-threads=1` -> `01.log`
- `cd infra && cargo test -p api --test stripe_pay_invoice_test stripe_pay_invoice_local_requires_action_path_returns_action_required_contract -- --nocapture --test-threads=1` -> `02.log`
- `cd infra && cargo test -p api --test billing_endpoints_test legacy_subscription_routes_return_404_and_preserved_billing_routes_remain_reachable -- --nocapture --test-threads=1` -> `03.log`

See `results.json` for per-command cache/run status and pass/fail.
