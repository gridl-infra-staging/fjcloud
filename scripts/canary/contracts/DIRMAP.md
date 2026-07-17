<!-- [scrai:start] -->
## contracts

| File | Summary |
| --- | --- |
| algolia_invalid_credentials_contract.sh | Shared Algolia migration contract helpers.

Usage:
  algolia_invalid_credentials_contract.sh [--self-test|staging|prod]

Live invalid-credentials probing of the customer migration POST route is retired.
Use scripts/algolia_migration_safety_probe.sh for the current read-only safety
oracle.

Optional env:
  FJCLOUD_SECRET_FILE                        Defaults to repo-local .secret/.env.secret.
  ALGOLIA_INVALID_CREDENTIALS_APP_ID         Defaults to the public Algolia demo app "latency".
  ALGOLIA_INVALID_CREDENTIALS_API_KEY        Defaults to an intentionally invalid key.
  ALGOLIA_INVALID_CREDENTIALS_EVIDENCE_ROOT  Overrides evidence output root for tests. |
| cold_customer_journey_walkthrough.sh | One-shot cold-customer journey CLI probe for the Algolia-refugee audit lane.

The transport seam intentionally stays at `curl()` because scripts/lib/http_json.sh
calls curl directly. |
| customer_loop_admin_cleanup_live_contract.sh | Live prod contract probe: does /fjcloud/prod/admin_key satisfy
DELETE /admin/tenants/00000000-0000-0000-0000-000000000000 on api.flapjack.foo?. |
| customer_metrics_endpoint_authenticated_probe.sh | Probe the customer-facing `/indexes/{name}/metrics` endpoint end-to-end using
a transient staging signup. |
| ec2_firewalld_contract.sh | EC2 firewalld port-coverage contract. |
| index_export_browser_path_probe.sh | Canonical browser-path probe for the Overview export/import contract.
Runs the focused Playwright owner and records a machine-readable verdict at:
  docs/runbooks/evidence/index-export-clientside/<UTC>/summary.json. |
| lambda_canary_invoke_contract.sh | Lambda canary invocation contract. |
| live_prod_reject_probe_lib.sh | Shared helper for live prod reject-contract probes. |
| mocked_spec_contract.sh | Mocked-spec drift contract for chromium:mocked Playwright payload owners.

Scope:
  - Parse shape-map keys from inline route.fulfill(...) payloads in
    web/tests/e2e-ui/mocked/auth_trust_states.spec.ts.
  - Assert live wire payload keys for the two deterministic auth cases:
      1) forgot-password resend success
      2) reset-password invalid token
  - Assert source-side payload fields for the two un-triggerable auth cases
    (cooldown 429 + delivery_failure 503) directly in forgot-password server
    source.
  - Assert live billing page-load wire still exposes the BillingPageData
    top-level keys upgradeStatus and paymentMethods.
  - Assert +page.server.ts::load source still owns the nested fixture-rides-on-this
    identifiers has_default_payment_method, upgrade_ready, paymentMethods,
    and upgradeStatus.
  - Assert UpgradeTestFixtureState fields/statuses still have matching backing
    usage in UpgradeButton.svelte.

IMPORTANT: This intentionally parses TypeScript/Svelte source using bash + a
narrow Python helper to avoid introducing a second manifest/fixture owner.
The coupling is explicit so reviewers can validate it. |
| multi_tenant_isolation_probe_contract.sh | Contract tests for scripts/launch/multi_tenant_isolation_probe.sh. |
| oauth_redirect_uri_contract.sh | OAuth redirect_uri contract probe. |
| stripe_webhook_bad_signature_reject_contract.sh | Live prod fail-closed contract: Stripe webhook rejects bad signature (HTTP 400). |
| stripe_webhook_stale_timestamp_reject_contract.sh | Live prod fail-closed contract: Stripe webhook rejects stale timestamp (HTTP 400). |
| tenant_jwt_wrong_secret_reject_contract.sh | Live prod fail-closed contract: tenant route rejects JWT signed with wrong secret (HTTP 401). |
| web_api_base_url_contract.sh | Web frontend API_BASE_URL contract probe. |
| web_form_login_contract.sh | Web form-login contract probe for deployed fjcloud web actions.
Required env:
  FJCLOUD_SECRET_FILE (optional path; defaults to repo-local .secret/.env.secret)
Usage:
  web_form_login_contract.sh [--self-test|prod|staging|all]. |
| web_server_load_api_url_contract.sh | Web frontend SERVER-LOAD API URL contract probe. |
<!-- [scrai:end] -->
