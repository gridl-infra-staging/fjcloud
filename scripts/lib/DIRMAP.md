<!-- [scrai:start] -->
## lib

| File | Summary |
| --- | --- |
| alert_dispatch.sh | Shared alert webhook dispatch helper.

Ownership boundary:
- This helper owns reusable critical-alert payload formatting for Slack/Discord
  and reusable webhook POST transport behavior.
- Callers own alert-specific metadata values (title/message/source/nonce/env).
TODO: Document build_slack_critical_payload. |
| billing_rehearsal_steps.sh | Shared planned-step list for staging billing preflight/rehearsal JSON output. |
| deterministic_batch_payload.sh | Stub summary for deterministic_batch_payload.sh. |
| env.sh | Shared environment file loading — single source of truth for local env parsing.

Exports:
  DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY  — shared local wrapper default.
  load_env_file <path>              — parse KEY=value lines, reject executable shell syntax.
  load_layered_env_files <path...>  — load env files in order while allowing later files to override earlier non-explicit keys.
  parse_env_assignment_line <line>  — parse one env assignment into ENV_ASSIGNMENT_* globals. |
| flapjack_binary.sh | Shared Flapjack binary discovery helpers for local/integration/chaos scripts.

Callers must define REPO_ROOT before sourcing this file.

Contract:
- Candidate repository order is fixed and bounded.
- Directory candidates come from FLAPJACK_DEV_DIR (explicit), then
  FLAPJACK_DEV_DIR_CANDIDATES (if set), then default repo-relative candidates.
- Binary preference is fixed:
  target/debug/flapjack
  target/debug/flapjack-http
  target/release/flapjack
  target/release/flapjack-http
- Restart-critical callers may fall back to PATH (`flapjack`, then
  `flapjack-http`) only after directory candidates fail. |
| flapjack_regions.sh | Shared Flapjack region-topology helpers for local seed/signoff scripts.

The local HA proof only means anything when the VM inventory and the running
Flapjack listeners describe the same topology. |
| full_backend_validation_json.sh | Stub summary for full_backend_validation_json.sh. |
| health.sh | Shared health-check helpers for shell scripts.

Callers must define:
  log "<message>". |
| http_json.sh | Shared JSON HTTP request helpers for shell scripts.

Callers provide:
- API_URL for all calls
- ADMIN_KEY for admin_call

Response contract:
- capture_json_response writes HTTP_RESPONSE_CODE and HTTP_RESPONSE_BODY globals. |
| live_gate.sh | Live gate enforcement for bash scripts.

When BACKEND_LIVE_GATE=1, precondition failures are fatal (exit 1).
When BACKEND_LIVE_GATE is unset or not "1", failures print a skip message
and return 0, preserving existing skip-and-continue behavior.

Usage:
  source scripts/lib/live_gate.sh
  live_gate_require "$some_condition" "reason for requirement". |
| metering_checks.sh | Metering validation checks for the backend launch gate.

Each check function uses live_gate_require to enforce preconditions:
  - Gate ON  (BACKEND_LIVE_GATE=1): failure = exit 1 (hard block)
  - Gate OFF: failure = [skip] message + continue

Functions:
  check_usage_records_populated  — usage_records table has rows
  check_rollup_current           — usage_daily has been rolled up recently

REASON: codes:
  db_url_missing       No database URL configured
  db_connection_timeout Database connection failed or timed out
  db_query_timeout     Database query exceeded statement_timeout
  db_query_failed      Database query failed for a non-timeout reason
  usage_records_empty  usage_records count is zero or invalid
  rollup_stale         usage_daily has no rollups within freshness window. |
| migrate.sh | Shared migration helper — applies SQL migrations from a directory.

Tracks applied migrations in a _schema_migrations table so reruns
against an existing database skip already-applied files.

Requires the caller to define: log()
Returns non-zero on failure so callers control their own error handling.

Usage: run_migrations <db_url> <migrations_dir>. |
| parse_inbound_auth_headers.py | Stub summary for parse_inbound_auth_headers.py. |
| process.sh | Stub summary for process.sh. |
| psql_path.sh | Stub summary for psql_path.sh. |
| secret_audit_parsing.sh | Stub summary for secret_audit_parsing.sh. |
| security_checks.sh | Security validation checks for the backend reliability gate.

Three automated checks:
  check_cargo_audit         — cargo audit for known vulnerable dependencies
  check_secret_scan         — scan tracked files for leaked secrets/key patterns
  check_unsafe_code_patterns — grep Rust source for SQL interpolation and unsafe Command::new

Each function prints a single JSON line to stdout and returns 0 (pass) or 1 (fail/skip).
On failure, emits REASON:<code> to stderr for structured reason extraction. |
| staging_billing_rehearsal_email_evidence.sh | Stub summary for staging_billing_rehearsal_email_evidence.sh. |
| staging_billing_rehearsal_evidence.sh | Stub summary for staging_billing_rehearsal_evidence.sh. |
| staging_billing_rehearsal_flow.sh | Flow helpers for scripts/staging_billing_rehearsal.sh. |
| staging_billing_rehearsal_impl.sh | Stub summary for staging_billing_rehearsal_impl.sh. |
| staging_billing_rehearsal_live_mutation.sh | Live mutation execution helpers for staging billing rehearsal. |
| staging_billing_rehearsal_reset.sh | Reset-path helpers for staging billing rehearsal. |
| stripe_account.sh | Shared explicit-account secret-key resolver for Stripe shell scripts.

Contract:
  - --account <name> resolves STRIPE_SECRET_KEY_<name>.
  - Resolved key is exported to canonical STRIPE_SECRET_KEY only for the
    current script invocation.
  - Without --account, canonical STRIPE_SECRET_KEY must already be present. |
| stripe_checks.sh | Stripe validation checks for the backend launch gate.

Each check function uses live_gate_require to enforce preconditions:
  - Gate ON  (BACKEND_LIVE_GATE=1): failure = exit 1 (hard block)
  - Gate OFF: failure = [skip] message + continue

Functions:
  resolve_stripe_secret_key      — resolves effective key (canonical first, alias fallback)
  check_stripe_key_present       — effective key is set with sk_test_ prefix
  check_stripe_key_live          — Key authenticates against Stripe GET /v1/balance
  check_stripe_webhook_secret_present — STRIPE_WEBHOOK_SECRET is set with whsec_ prefix
  check_stripe_webhook_forwarding     — `stripe listen` process is running

REASON: codes:
  stripe_key_unset                STRIPE_SECRET_KEY missing (alias fallback allowed)
  stripe_key_bad_prefix           Effective Stripe key does not start with sk_test_
  stripe_api_timeout              Stripe API call timed out (connect or overall)
  stripe_auth_failed              Stripe returned authentication_error for key
  stripe_key_http_error           Stripe key live check returned non-200 HTTP
  stripe_webhook_secret_unset     STRIPE_WEBHOOK_SECRET missing
  stripe_webhook_secret_bad_prefix STRIPE_WEBHOOK_SECRET does not start with whsec_
  stripe_listen_not_running       No running "stripe listen" process. |
| stripe_request.sh | Stub summary for stripe_request.sh. |
| validation_json.sh | Shared JSON/timing helpers for validation scripts.
Sourced by validate-stripe.sh, local-signoff-commerce.sh, and others. |
| web_runtime.sh | Shared local web runtime prerequisite checks. |
<!-- [scrai:end] -->
