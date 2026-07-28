# Local Reverification Summary

tested_head_sha=f8e09a73b94fef307517c69ffd78a3606e5f1554
tested_head_log=f8e09a73b matt: stage 1 completion
evidence_commit=committed_after_validation; see session handoff/final for commit SHA
bundle_path=docs/runbooks/evidence/local-reverification/20260728T161546Z/
start_timestamp=20260728T161546Z
end_timestamp=20260728T162136Z
manifest_model=relationship-granular matrix-row/owner relationships
section3_matrix_rows_total=9
section5_matrix_rows_total=8

section3: rows_total=13 rows_run_locally=8 rows_green=8 rows_red=0 rows_not_local=5
section5: rows_total=8 rows_run_locally=5 rows_green=5 rows_red=0 rows_not_local=3

## Commands Run
- `cd infra && INTEGRATION=1 BACKEND_LIVE_GATE=1 cargo test -p api --test billing stripe_webhook_signature -- --nocapture`
- `cd infra && INTEGRATION=1 BACKEND_LIVE_GATE=1 cargo test -p api --test auth_admin auth_rate_limit_returns_429_after_threshold -- --nocapture`
- `cd infra && INTEGRATION=1 BACKEND_LIVE_GATE=1 cargo test -p api --test auth_admin s3_rate_limit_enforces_retry_after_and_slowdown_payload -- --nocapture`
- `cd infra && INTEGRATION=1 BACKEND_LIVE_GATE=1 cargo test -p api --test platform noisy_neighbor -- --nocapture`
- `cd infra && INTEGRATION=1 BACKEND_LIVE_GATE=1 cargo test -p api --test auth_admin auth_lockout -- --nocapture`
- `cd infra && INTEGRATION=1 BACKEND_LIVE_GATE=1 cargo test -p api --test auth_admin api_key_auth -- --nocapture`
- `cd infra && INTEGRATION=1 BACKEND_LIVE_GATE=1 cargo test -p api --test auth_admin tenant_wrong_secret_returns_401 -- --nocapture`
- `cd infra && INTEGRATION=1 BACKEND_LIVE_GATE=1 cargo test -p api --test auth_admin internal_auth -- --nocapture`
- `cd infra && INTEGRATION=1 BACKEND_LIVE_GATE=1 cargo test -p api --test platform cross_tenant_isolation -- --nocapture`
- `cd infra && INTEGRATION=1 BACKEND_LIVE_GATE=1 cargo test -p api --test platform --features proptest-tests tenant_isolation_proptest:: -- --nocapture`
- `cd infra && INTEGRATION=1 BACKEND_LIVE_GATE=1 cargo test -p api --test platform metering_multitenant -- --nocapture`
- `cd infra && INTEGRATION=1 BACKEND_LIVE_GATE=1 cargo test -p api --test platform storage_s3_object_metering_concurrency -- --nocapture`

## Red Relationships
- none; ROADMAP.md not modified

## Not Local Relationships
- section 3 `scripts/canary/contracts/stripe_webhook_bad_signature_reject_contract.sh`: live-prod https://api.flapjack.foo webhook endpoint required
- section 3 `scripts/canary/contracts/stripe_webhook_stale_timestamp_reject_contract.sh`: live-prod https://api.flapjack.foo webhook endpoint required
- section 3 `scripts/canary/contracts/oauth_redirect_uri_contract.sh`: OAuth provider token endpoints and callback reachability required
- section 3 `scripts/canary/contracts/tenant_jwt_wrong_secret_reject_contract.sh`: live-prod https://api.flapjack.foo account endpoint required
- section 3 `scripts/canary/contracts/ec2_firewalld_contract.sh`: AWS EC2/SSM access to fjcloud-api instances required
- section 5 `infra/api/tests/integration/integration_metering_pipeline_test.rs`: local API 127.0.0.1:3099 and local flapjack 127.0.0.1:7799 unavailable: connection refused
- section 5 `infra/api/tests/integration/integration_metering_pipeline_test.rs`: local API 127.0.0.1:3099 and local flapjack 127.0.0.1:7799 unavailable: connection refused
- section 5 `scripts/launch/multi_tenant_isolation_probe.sh`: staging topology and output bundle path required

## Raw Proof
- `section3_api_key_auth.log`
- `section3_auth_lockout.log`
- `section3_internal_auth.log`
- `section3_noisy_neighbor.log`
- `section3_security_auth_rate_limit.log`
- `section3_security_s3_rate_limit.log`
- `section3_stripe_webhook_signature.log`
- `section3_tenant_wrong_secret_returns_401.log`
- `section5_cross_tenant_isolation.log`
- `section5_metering_multitenant.log`
- `section5_noisy_neighbor.log`
- `section5_storage_s3_object_metering_concurrency.log`
- `section5_tenant_isolation_proptest.log`

## Validation Outputs
- bundle validation: PASS (`bundle_validation.log`; newest bundle matched this run; automated_guard=PASS; raw_log_count=13)
- freshness validation: PASS (`freshness_validation.log`; `freshness_exit=1`; Section 3 STALE; Section 5 STALE)
