# app.flapjack.foo Retirement Gate Evidence

Captured at: 2026-05-21T17:17:50Z
Run directory: docs/runbooks/evidence/app_domain_retirement/20260521T171119Z_app_domain_retirement

Default decision summary:
- `L12_DECISION` default: `retire`
- `retire_default_allowed`: `true`
- `gate_blocked`: `false`

## Stage 3 branch note (2026-05-21)
- Chosen branch: `retire` (no newer operator override evidence was present).
- Owner-file reconciliation completed for retire policy:
  - `ops/runbooks/site_takedown_20260503/restore.sh` now restores only canonical `cloud.flapjack.foo` (no `app.flapjack.foo` restore step).
  - `ops/runbooks/site_takedown_20260503/STATUS.md` keeps `app.flapjack.foo` only as historical incident context and marks it retired.
  - `docs/decisions/2026-05-02_adapter_cloudflare_migration.md` now labels `app.flapjack.foo` as a historical alias.
  - `scripts/tests/configure_billing_portal_test.sh` fixture/readback expectations now use `https://cloud.flapjack.foo/...`.

## Evidence highlights
- Owner seams confirmed in `owner_confirmations.md` for Pages naming, DNS intent, Cloudflare X-Auth auth path, and Stripe `default_return_url` readback ownership.
- Cloudflare Pages custom domains include `app.flapjack.foo` as active (`cloudflare_pages_domains_raw.json`).
- Cloudflare zone DNS has active `app.flapjack.foo` CNAME targeting `flapjack-cloud.pages.dev` (`cloudflare_dns_app_raw.json`).
- Reachability probes show `https://app.flapjack.foo/` returned HTTP 200, and both public resolvers returned non-empty answers (`dig_app_1_1_1_1.txt`, `dig_app_8_8_8_8.txt`).
- Cloudflare analytics host-scoped 30d read was attempted twice via the existing X-Auth seam; both attempts returned GraphQL argument errors, recorded as unavailable (`cloudflare_analytics_raw.json`, `cloudflare_analytics_raw_alt.json`).
- Stripe readback via existing script succeeded for canonical and live-account paths; both returned `default_return_url: null` (no `app.flapjack.foo` blocking URL).

## Sources
- `web/wrangler.toml:23-36`
- `docs/NOW.md:15`
- `ops/terraform/dns/main.tf:1-39`
- `ops/runbooks/site_takedown_20260503/restore.sh:16-38`
- `docs/design/stripe_customer_portal_contract.md:21-29`
- `scripts/lib/stripe_account.sh:1-51`
- `scripts/stripe/configure_billing_portal.sh:115-179`
- `cloudflare_pages_domains_raw.json`
- `cloudflare_dns_app_raw.json`
- `http_app_headers.txt`
- `dig_app_1_1_1_1.txt`
- `dig_app_8_8_8_8.txt`
- `cloudflare_analytics_raw.json`
- `cloudflare_analytics_raw_alt.json`
- `stripe_portal_default_stdout.json`
- `stripe_portal_live_stdout.json`

## Open questions
- What is the exact Cloudflare GraphQL field/filter contract for host-scoped 30-day traffic on this account/key shape? Current best-effort readbacks failed with `unknown arg` errors.
- `scripts/stripe/configure_billing_portal.sh` performs update/create writes before returning readback JSON. Stage 1 used this mandated seam; confirm if a read-only mode should be added in a follow-up stage.
