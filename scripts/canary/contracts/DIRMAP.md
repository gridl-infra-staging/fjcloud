<!-- [scrai:start] -->
## contracts

| File | Summary |
| --- | --- |
| ec2_firewalld_contract.sh | EC2 firewalld port-coverage contract. |
| lambda_canary_invoke_contract.sh | Lambda canary invocation contract. |
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
| oauth_redirect_uri_contract.sh | Stub summary for oauth_redirect_uri_contract.sh. |
| web_api_base_url_contract.sh | Stub summary for web_api_base_url_contract.sh. |
| web_form_login_contract.sh | Stub summary for web_form_login_contract.sh. |
| web_server_load_api_url_contract.sh | Web frontend SERVER-LOAD API URL contract probe. |
<!-- [scrai:end] -->
