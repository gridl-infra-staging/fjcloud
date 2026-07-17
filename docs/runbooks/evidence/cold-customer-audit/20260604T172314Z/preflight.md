# Cold Customer Algolia-Refugee Audit Stage 1 Preflight

Created: 2026-06-04T17:23:14Z

## Purpose

Stage 1 establishes a fresh evidence root and direct proof of what staging is running before later CLI or browser results are interpreted. This stage did not run the customer quickstart validator, the cold-customer CLI walkthrough, or the browser journey.

## Evidence Root

- Canonical rerun root: `docs/runbooks/evidence/cold-customer-audit/20260604T172314Z`
- CLI evidence subdirectory reserved for Stage 2: `docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/cli`
- Browser evidence subdirectory reserved for Stage 3: `docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/browser`
- Dev checkout used for branch truth and ancestry gates: `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev`

## Runtime Identity

Captured with:

```bash
curl -fsS https://api.staging.flapjack.foo/version | tee "$EVIDENCE_ROOT/version.json"
```

Live `/version` payload:

```json
{"build_time":"2026-06-04T16:06:20Z","dev_sha":"c62287ada3f7662305032263766441fa4388ac98","mirror_sha":"bf8c41a27035ebb1950fdcdde12a84f62e5a265a","synced_at":"2026-06-04T15:57:33Z"}
```

Machine parse result:

- `STAGING_SHA=c62287ada3f7662305032263766441fa4388ac98`
- Required fields present and non-empty: `dev_sha`, `build_time`, `mirror_sha`, `synced_at`

Runtime proof surface owners:

- `infra/api/src/routes/version.rs:7` returns `dev_sha`, `mirror_sha`, `synced_at`, and `build_time` from build-time environment values.
- `infra/api/src/router/route_assembly.rs:106-109` registers unauthenticated `GET /version`.
- `scripts/deploy_status.sh:69-118` is an existing comparison seam for probing `/version` and computing history gaps; it was not used as a substitute for the exact Stage 1 capture and ancestry commands.

## Dev Checkout State

Captured after:

```bash
git -C "$DEV_CHECKOUT" fetch origin main --quiet
git -C "$DEV_CHECKOUT" rev-parse HEAD
git -C "$DEV_CHECKOUT" rev-parse origin/main
git -C "$DEV_CHECKOUT" status --short
```

Result:

```text
HEAD=c62287ada3f7662305032263766441fa4388ac98
origin_main=c62287ada3f7662305032263766441fa4388ac98
status_short_begin
status_short_end
```

The intended dev checkout was clean, and `HEAD` matched fetched `origin/main`.

## Ancestry Gates

Before ancestry checks, the deployed SHA was proved present in the fetched local object store:

```bash
git -C "$DEV_CHECKOUT" rev-parse -q --verify "${STAGING_SHA}^{commit}"
```

Result:

```text
object_rc=0
object_output=c62287ada3f7662305032263766441fa4388ac98
```

Search Preview fix gate:

```bash
git -C "$DEV_CHECKOUT" merge-base --is-ancestor e940f08f9 "$STAGING_SHA"
```

Result:

```text
search_preview_rc=0
search_preview_output=<no stdout/stderr>
```

Conclusion: staging contains `e940f08f9`.

Current-main gate:

```bash
git -C "$DEV_CHECKOUT" merge-base --is-ancestor "$STAGING_SHA" origin/main
```

Result:

```text
staging_on_origin_main_rc=0
staging_on_origin_main_output=<no stdout/stderr>
```

Conclusion: staging `dev_sha` is still on current fetched `origin/main`.

## Later-Stage Reuse Seams

Stage 2 and Stage 3 should extend the existing owners below instead of replacing them:

- `scripts/validate_customer_quickstart.sh:24-37` owns `MARKER_CASES`, the ordered customer quickstart and migration marker inventory.
- `scripts/validate_customer_quickstart.sh:217` owns `validate_doc_marker_contracts`.
- `scripts/validate_customer_quickstart.sh:699-781` owns `run_quickstart_and_migration_sequence` and `run_signup_verify_search_flow`.
- `scripts/canary/contracts/cold_customer_journey_walkthrough.sh:147-197` owns `cold_customer_parse_args` and `cold_customer_prepare_environment`.
- `web/playwright.config.contract.ts:626-722` owns `REMOTE_TARGET_OPT_IN_ENV`, `requireLoopbackHttpUrl`, and `resolveFixtureEnv`.
- `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts:347-397` owns the staging cold-customer journey test body.

Canonical later-stage bootstrap commands to record, not execute in Stage 1:

```bash
scripts/canary/contracts/cold_customer_journey_walkthrough.sh \
  --env staging \
  --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret \
  --evidence-dir "$EVIDENCE_ROOT/cli"
```

```bash
source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)
export E2E_ADMIN_KEY="$ADMIN_KEY"
export PLAYWRIGHT_TARGET_REMOTE=1
```

## Open Questions

None for Stage 1. The baseline has enough direct evidence for later stages to interpret CLI and browser failures against the deployed staging identity.
