<!-- [scrai:start] -->
## lib

| File | Summary |
| --- | --- |
| alert_dispatch.sh | Shared alert webhook dispatch helper.

Ownership boundary:
- This helper owns reusable critical-alert payload formatting for Slack/Discord
  and reusable webhook POST transport behavior.
- Callers own alert-specific metadata values (title/message/source/nonce/env). |
| aws_identity.sh | The AWS_IDENTITY_* globals below are this library's caller-facing output
contract (read by scripts that source it), so shellcheck's "appears unused"
does not apply to them.
shellcheck disable=SC2034

Shared AWS caller-identity triage — single source of truth for the question
"is a valid AWS identity available right now, and if not, WHY?".

WHY THIS EXISTS (root-caused 2026-07-08)
----------------------------------------
For ~5 weeks the support-inbox synthetic canary, the SES clickthrough/dunning
probes, and the paid-beta RC all classified every `aws sts get-caller-identity`
failure as a dead-credential environment gap and SKIPPED — without ever trying
the repo's canonical secret file. |
| billing_rehearsal_steps.sh | Shared planned-step list for staging billing preflight/rehearsal JSON output. |
| clickthrough_probe_common.sh | Shared helpers for auth-email clickthrough probes that prove the inbox path. |
| customer_lifecycle_steps.sh | Shared customer lifecycle steps reused by canary and VM lifecycle orchestrator.

Caller-owned prerequisites:
- log function
- flow globals: FLOW_FAILED, FLOW_FAILURE_STEP, FLOW_FAILURE_DETAIL
- HTTP seams from scripts/lib/http_json.sh
- inbox seams from scripts/lib/test_inbox_helpers.sh for verify-email
- env vars/state variables used below (CANARY_* namespace). |
| debbie_cli.sh | Shared debbie CLI resolver. |
| deployable_currency.sh | Classify whether a deployed SHA is stale in ways that can actually change the
API release artifact. |
| docker.sh | docker.sh — Probe docker-daemon reachability before scripts try to drive it.

Why this exists (anchored 2026-06-02): scripts/local_demo.sh and
scripts/local-dev-up.sh used `command -v docker` as their docker
precondition. |
| env.sh | Shared environment file loading — single source of truth for local env parsing.

Exports:
  DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY  — shared local wrapper default.
  load_env_file <path>              — parse KEY=value lines, reject executable shell syntax.
  load_layered_env_files <path...>  — load env files in order while allowing later files to override earlier non-explicit keys.
  parse_env_assignment_line <line>  — parse one env assignment into ENV_ASSIGNMENT_* globals.
shellcheck disable=SC2034. |
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
  `flapjack-http`) only after directory candidates fail.
Canonical fjcloud engine dependency. |
| flapjack_regions.sh | Shared Flapjack region-topology helpers for local seed/signoff scripts.

The local HA proof only means anything when the VM inventory and the running
Flapjack listeners describe the same topology. |
| health.sh | Shared health-check helpers for shell scripts.

Callers must define:
  log "<message>". |
| http_json.sh | Shared JSON HTTP request helpers for shell scripts.
shellcheck disable=SC2034

Callers provide:
- API_URL for all calls
- ADMIN_KEY for admin_call

Response contract:
- capture_json_response writes HTTP_RESPONSE_CODE, HTTP_RESPONSE_BODY, and
  HTTP_RESPONSE_EXIT_STATUS globals. |
| hydrate_staging_env.sh | hydrate_staging_env.sh — shared helpers to hydrate staging-targeted
environment variables from SSM.

Single canonical owner for the three hydration primitives. |
| identifier_redaction.sh | Shared identifier-redaction helper.

Stripe/Privacy.com object IDs are not credentials in the secret-key sense
but they are PII-adjacent live-mode identifiers. |
| live_gate.sh | Live gate enforcement for bash scripts.

When BACKEND_LIVE_GATE=1, precondition failures are fatal (exit 1).
When BACKEND_LIVE_GATE is unset or not "1", failures print a skip message
and return 0, preserving existing skip-and-continue behavior.

Usage:
  source scripts/lib/live_gate.sh
  live_gate_require "$some_condition" "reason for requirement". |
| local_db_access.sh | Shared local Postgres access helpers for sourceable local-dev scripts. |
| local_seed_contract.sh | Canonical local seed data contract shared by seed and audit scripts.

This file is source-only: it defines stable values and tuple builders, and
must not touch API, Flapjack, Docker, or Postgres when loaded. |
| local_stack_contract.sh | Compatibility checks for independently running local stack services. |
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
| mocked_spec_contract_parser.py | Stub summary for mocked_spec_contract_parser.py. |
| parse_inbound_auth_headers.py | Stub summary for parse_inbound_auth_headers.py. |
| persist_capture_artifact.py | Normalize capture artifacts into a consistent JSON structure. |
| privacy_com_client.sh | Privacy.com transport owner for create/get/list/close card flows.
shellcheck disable=SC1091,SC2034. |
| rc_invocation.sh | Shared RC wrapper data helpers. |
| security_checks.sh | Security validation checks for the backend reliability gate.

Three automated checks:
  check_cargo_audit         — cargo audit for known vulnerable dependencies
  check_secret_scan         — scan tracked files for leaked secrets/key patterns
  check_unsafe_code_patterns — grep Rust source for SQL interpolation and unsafe Command::new

Each function prints a single JSON line to stdout and returns 0 (pass) or 1 (fail/skip).
On failure, emits REASON:<code> to stderr for structured reason extraction. |
| ses_coverage_a1_integrity.py | Canonical §1 SES coverage integrity checker for the six-probe in-VPC bundle.

Validates a completed evidence bundle by cross-checking probe_results.tsv rows
against saved log files, per-probe JSON sidecars, all_green.txt, and
failure_classifications.json. |
| staging_billing_rehearsal_deployable_summary.sh | Deployable-currency summary helpers for staging billing rehearsal. |
| staging_billing_rehearsal_evidence.sh | Evidence convergence helpers for staging billing rehearsal.
shellcheck source=staging_billing_rehearsal_cross_check.sh. |
| staging_billing_rehearsal_flow.sh | Flow helpers for scripts/staging_billing_rehearsal.sh. |
| staging_billing_rehearsal_impl.sh | shellcheck source=psql_path.sh. |
| staging_billing_rehearsal_live_mutation.sh | Live mutation execution helpers for staging billing rehearsal. |
| staging_billing_rehearsal_metering.sh | Metering evidence helpers for staging billing rehearsal. |
| staging_billing_rehearsal_reset.sh | Reset-path helpers for staging billing rehearsal. |
| staging_db.sh | staging_db.sh — Run SQL against staging/prod RDS via AWS SSM RunShellScript.

RDS is VPC-private and unreachable directly from a developer machine.
This helper discovers the fjcloud-api EC2 instance via Name tag and
executes psql on it using SSM so SQL can reach the database.

Usage (source this file, then call staging_db_run_sql):

  source scripts/lib/staging_db.sh
  staging_db_run_sql "$DATABASE_URL" "SELECT COUNT(*) FROM customers"

Environment:
  DATABASE_URL_SSM_PARAM  — used to auto-detect staging vs prod
                            (e.g. |
| stale_fixture_contract.sh | Source-only stale fixture contract shared by Playwright fixtures and local DB cleanup.

These prefixes are the fixture-owned index/tenant names that may be cleaned
after a failed local E2E run. |
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
  check_stripe_key_present       — effective key is set with sk_test_ or rk_test_ prefix
  check_stripe_key_live          — Key authenticates against Stripe GET /v1/balance
  check_stripe_account_status    — Pure parser of a GET /v1/account body: emits
                                   payout/charge readiness booleans + requirement counts
  check_stripe_webhook_secret_present — STRIPE_WEBHOOK_SECRET is set with whsec_ prefix
  check_stripe_webhook_forwarding     — `stripe listen` process is running

REASON: codes:
  stripe_key_unset                STRIPE_SECRET_KEY missing (alias fallback allowed)
  stripe_key_bad_prefix           Effective Stripe key does not start with sk_test_ or rk_test_
  stripe_api_timeout              Stripe API call timed out (connect or overall)
  stripe_auth_failed              Stripe returned authentication_error for key
  stripe_key_http_error           Stripe key live check returned non-200 HTTP
  stripe_account_not_ready        Account not fully payout-ready (charges/payouts/details
                                  not all enabled, or outstanding requirements/disabled_reason)
  stripe_account_parse_error      GET /v1/account body could not be parsed as JSON
  stripe_webhook_secret_unset     STRIPE_WEBHOOK_SECRET missing
  stripe_webhook_secret_bad_prefix STRIPE_WEBHOOK_SECRET does not start with whsec_
  stripe_listen_not_running       No running "stripe listen" process. |
| stripe_payment_methods.sh | Shared Stripe payment-method attach/default/detach helpers.
shellcheck disable=SC2034

Caller-owned prerequisites:
- stripe_request from scripts/lib/stripe_request.sh

Exports:
- STRIPE_ATTACHED_PAYMENT_METHOD_ID
- STRIPE_PAYMENT_METHOD_ERROR_MESSAGE. |
| stripe_request.sh | Shared Stripe request transport helper.

Callers provide:
- STRIPE_SECRET_KEY_EFFECTIVE
- STRIPE_API_BASE

Response contract:
- stripe_request writes STRIPE_HTTP_CODE, STRIPE_BODY, and STRIPE_REQUEST_ID. |
| validation_json.sh | Shared JSON/timing helpers for validation scripts.
Sourced by validate-stripe.sh, local-signoff-commerce.sh, and others. |
| web_runtime.sh | Shared local web runtime prerequisite checks. |
<!-- [scrai:end] -->
