# Secret Rotation Runbook

## Purpose

This runbook defines operator rotation steps for Stripe, SES, and JWT signing secrets.
Keep variable definitions in [`docs/env-vars.md`](../env-vars.md) as the single source of truth.
For SES setup and readiness details, use [`docs/runbooks/email-production.md`](email-production.md).

## Scope And Runtime Constraints

- This runbook documents current behavior only; it does not add multi-key JWT support.
- The API currently uses a single `JWT_SECRET` with no overlap window for old and new tokens.
- Rotations here are deploy-time cutovers; no live in-process secret reload is implemented.

## IAM Rotation Evidence Pointer

The IAM role/policy rotation evidence for `apr28_2pm_7_aws_scoped_iam_rotation` is immutable input from Stages 1-3 and is owned as an evidence bundle, not as procedure text in this runbook:

- `docs/runbooks/evidence/secret-rotation/20260428T192916Z_iam_rotation/`
- `docs/runbooks/evidence/secret-rotation/20260428T192916Z_iam_rotation/discovery_summary.json`
- `docs/runbooks/evidence/secret-rotation/20260428T192916Z_iam_rotation/iam_plan.json`
- `docs/runbooks/evidence/secret-rotation/20260428T192916Z_iam_rotation/stage3/simulations/summary.json`
- `docs/runbooks/evidence/secret-rotation/20260428T192916Z_iam_rotation/stage3/live_path_deploy_staging_success_62fabe596675b28023c8d374125cd4c758110f36_ssm_get_command_invocation.json`

This runbook continues to own only Stripe/SES/JWT procedure steps. IAM role/policy specifics should be read from the evidence bundle above.

## Stripe Rotation

### Contract Anchors

- Canonical key resolution and checks:
  - `scripts/lib/stripe_checks.sh::resolve_stripe_secret_key`
  - `scripts/lib/stripe_checks.sh::stripe_key_prefix_policy_allows_key`
  - `scripts/lib/stripe_checks.sh::check_stripe_key_present`
  - `scripts/lib/stripe_checks.sh::check_stripe_key_live`
  - `scripts/lib/stripe_checks.sh::check_stripe_webhook_secret_present`
- Validation command: `scripts/validate-stripe.sh`
- Launch gate context: [`docs/runbooks/launch-backend.md`](launch-backend.md)
- Variable contract: [`docs/env-vars.md#stripe`](../env-vars.md#stripe)

`STRIPE_SECRET_KEY` is the canonical operator variable. `STRIPE_TEST_SECRET_KEY` is a compatibility fallback only when `STRIPE_SECRET_KEY` is unset.

### Stage 1 Prerequisite Gate (non-mutating)

Before any Stripe cutover mutation steps, run:

```bash
FJCLOUD_SECRET_FILE="${FJCLOUD_SECRET_FILE:-.secret/.env.secret}" \
  bash scripts/stripe_cutover_prereqs.sh
```

The gate must pass before proceeding. It writes a redacted prerequisite bundle to `docs/runbooks/evidence/secret-rotation/<UTC-stamp>_stripe_cutover/` by default and exits non-zero with `REASON: prerequisite_missing` when required inputs are missing.

Required Stage 1 inputs in the secret source:

- `STRIPE_SECRET_KEY_RESTRICTED=rk_test_...`
- `# STRIPE_RESTRICTED_KEY_ID=<id_visible_in_dashboard>`
- `# STRIPE_OLD_KEY_ID=<id_visible_in_dashboard>`

### Stripe Live Cutover

Wave 2 live cutover stays anchored to existing Stripe check owners only:
`check_stripe_key_present`, `check_stripe_key_live`, and `stripe_live_cutover_enabled`
in `scripts/lib/stripe_checks.sh`.

- Live-prefix contract: sk_live_/rk_live_ prefixes are rejected unless STRIPE_LIVE_CUTOVER=1 is set.
- Validation boundary: bash scripts/validate-stripe.sh remains test-mode validation and is not the live-cutover verifier.
- Non-goal boundary: `scripts/stripe_cutover_prereqs.sh` is marker/presence-only and does not validate live key values.
- Non-goal boundary: operator comment markers are metadata only and are not runtime config values.
- Probe-phase boundary: live invoice proof is deferred to a separate probe phase outside Stage 3.

Wave 2 pre-rotation capture has two distinct concerns and both are required:

1. Runtime Stripe value metadata in SSM for values that are actually consumed at runtime:
   `/fjcloud/staging/stripe_secret_key` and webhook-secret parameter metadata (if webhook rotation is in scope).
2. Existing secret-source comment markers for operator rollback context:
   `# STRIPE_RESTRICTED_KEY_ID` and `# STRIPE_OLD_KEY_ID`.

Wave 2 mutation flow (runtime SSM values only):

1. Update SSM runtime value for `STRIPE_SECRET_KEY` (`/fjcloud/staging/stripe_secret_key`) to the new live key.
2. If included in the same window, update the webhook runtime SSM value that maps to `STRIPE_WEBHOOK_SECRET`.
3. Regenerate remote environment from SSM and restart backend services that consume Stripe env.
4. Do not mutate `# STRIPE_RESTRICTED_KEY_ID` or `# STRIPE_OLD_KEY_ID` as part of runtime cutover; they are comment metadata.

Post-cutover checks and evidence capture:

1. Capture remote env confirmation with redacted prefix-only evidence for Stripe runtime keys.
2. Run existing launch-validation Stripe check path with `STRIPE_LIVE_CUTOVER=1` so `check_stripe_key_present` and `check_stripe_key_live` enforce the canonical live-cutover contract.
3. Capture command output and reason-code outcomes under the current secret-rotation evidence directory.

Rollback (runtime values only):

1. Use SSM parameter history rollback (version restore) for runtime Stripe values.
2. Regenerate remote environment and restart services to load the restored runtime values.
3. Re-run the same Stripe check owners with `STRIPE_LIVE_CUTOVER=1` and treat failures using their canonical reason terms.

### Prechecks

1. Confirm the new Stripe key is available as `STRIPE_SECRET_KEY` and starts with `sk_test_` or `rk_test_` for non-live validation contexts.
2. Confirm `STRIPE_WEBHOOK_SECRET` is available and starts with `whsec_`.
3. Confirm the current shell/environment does not rely on `STRIPE_TEST_SECRET_KEY` unless explicitly using compatibility fallback behavior.
4. For live cutover invocation, confirm the resolved `STRIPE_SECRET_KEY` is a live key (`sk_live_` or `rk_live_`) and keep the prior known-good key available for immediate rollback.

### Validation Invocation Contract (exact commands)

Default-deny validation (routine path, rejects live keys by design):

```bash
bash scripts/validate-stripe.sh
```

Explicit live cutover validation (accepts live keys only when both controls are present):

```bash
STRIPE_LIVE_CUTOVER=1 \
  bash scripts/validate-stripe.sh --live-cutover
```

If `--live-cutover` is passed without `STRIPE_LIVE_CUTOVER=1`, validation fails at JSON step `require_live_cutover_control`.

### Cutover

1. Update secret storage/session-manager entries so `STRIPE_SECRET_KEY` points to the new value.
2. Update `STRIPE_WEBHOOK_SECRET` if webhook signing secret rotation is part of the same window.
3. Deploy/restart API processes that consume Stripe env vars.
4. Keep `STRIPE_TEST_SECRET_KEY` unset unless a compatibility-only automation path still requires it temporarily.

### Rollback Expectations

1. Restore the previous known-good `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` values.
2. Deploy/restart API processes to reload the previous values.
3. Re-run the validation command that matches the restored key mode:

If rollback restores a live key, rerun explicit live cutover validation:

```bash
STRIPE_LIVE_CUTOVER=1 \
  bash scripts/validate-stripe.sh --live-cutover
```

If rollback restores a test key, rerun default-deny validation:

```bash
bash scripts/validate-stripe.sh
```

### Post-rotation verification

1. Load the rotated `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` into the current shell from your approved secret source. Do not paste literal secret values into the command line because shell history and process inspection can expose them.
2. Run the invocation that matches your intended mode:

```bash
# Routine/default-deny validation:
bash scripts/validate-stripe.sh

# Explicit live cutover validation:
STRIPE_LIVE_CUTOVER=1 \
  bash scripts/validate-stripe.sh --live-cutover
```

3. Confirm output JSON reports `"passed": true`.
4. If launch validation is in scope, run the relevant Stripe checks from [`docs/runbooks/launch-backend.md`](launch-backend.md).

## SES Rotation

### Contract Anchors

- Startup validation path: `infra/api/src/services/email.rs::SesConfig::from_reader`
- Readiness script: `scripts/validate_ses_readiness.sh`
- Canonical SES runbook: [`docs/runbooks/email-production.md`](email-production.md)
- Variable contract: [`docs/env-vars.md#email-ses`](../env-vars.md#email-ses)

This runbook keeps SES rotation narrow to `SES_FROM_ADDRESS` and `SES_REGION`. AWS credential chain behavior remains owned by [`docs/runbooks/email-production.md`](email-production.md) under its "AWS credential chain" section.

### Prechecks

1. Confirm target `SES_FROM_ADDRESS` identity is verified in the target account/region.
2. Confirm target `SES_REGION` matches where the identity is verified.
3. Confirm the AWS credential chain context required by the email-production runbook is healthy before cutover.

### Cutover

1. Update `SES_FROM_ADDRESS` and/or `SES_REGION` in the runtime secret source.
2. Deploy/restart API processes so startup re-runs `SesConfig::from_reader` against updated values.
3. If startup fails, treat that as a contract failure (missing/empty SES envs) and roll back immediately.

### Rollback Expectations

1. Restore the previous `SES_FROM_ADDRESS`/`SES_REGION` pair.
2. Deploy/restart API processes to restore known-good startup configuration.
3. Do not define alternate SES secret contracts in this runbook; continue to use env-vars + email-production docs.

### Post-rotation verification

1. Run:

```bash
SES_FROM_ADDRESS=noreply@example.com SES_REGION=us-east-1 \
  bash scripts/validate_ses_readiness.sh --identity noreply@example.com --region us-east-1
```

2. Confirm readiness output reports identity verified and no blocking errors.
3. For deeper SES readiness and non-goals, continue with [`docs/runbooks/email-production.md`](email-production.md).

## JWT Rotation

### Contract Anchors

- Startup config load: `infra/api/src/config.rs::Config::from_reader`
- Startup wiring (single loaded secret at process start): `infra/api/src/main.rs`, `infra/api/src/state.rs`
- Sign path: `infra/api/src/routes/auth.rs::issue_jwt`
- Verify paths:
  - `infra/api/src/auth/tenant.rs::AuthenticatedTenant::from_request_parts`
  - `infra/api/src/router/middleware.rs::extract_tenant_id_from_jwt`
  - `infra/api/src/middleware/request_logging.rs::RequestSpan::extract_tenant_id`

The current design uses a single JWT_SECRET value loaded at startup. The same secret signs and verifies tokens. Rotation is not seamless because there is no multi-key overlap support.

### Prechecks

1. Announce maintenance impact: rotation will invalidate outstanding bearer tokens after cutover.
2. Ensure client-facing teams are ready for forced re-authentication.
3. Prepare a rollback value for `JWT_SECRET` before changing production config.

### Cutover

1. Update `JWT_SECRET` in runtime secret storage.
2. Deploy/restart API processes so the new secret is loaded by `Config::from_reader` into `AppState`.
3. Expect existing bearer tokens minted before deploy/restart to fail verification immediately after cutover.

### Rollback Expectations

1. Restore prior `JWT_SECRET` value.
2. Deploy/restart API processes to resume verification with the prior key.
3. Tokens issued under the failed new key will become invalid after rollback because sign/verify stays single-key.

### Post-rotation verification

1. Authenticate to obtain a fresh token (new sign path via `issue_jwt`).
2. Call at least one protected endpoint with the new token and confirm success.
3. Confirm old pre-rotation tokens fail, which proves expected single-key cutover behavior.

## Internal Auth Token Rotation

`INTERNAL_AUTH_TOKEN` (SSM `/fjcloud/<env>/internal_auth_token`) gates the API's
`/internal/*` routes. Both the fjcloud API process AND every Flapjack VM's
`fj-metering-agent` use this same value (the agent reads it as `INTERNAL_KEY`
in `/etc/flapjack/metering-env`). The API regenerates its env from SSM on
every deploy/restart; the metering agent's env file is generated at AMI bake
time or on a one-off basis and does NOT auto-refresh on rotation.

### The class of bug this section exists to prevent

On 2026-04-29 a rotation of `/fjcloud/staging/internal_auth_token` silently
broke the metering pipeline for ~3 days. The API picked up the new value via
its env-from-SSM regen path; the Flapjack VM's `/etc/flapjack/metering-env`
kept the old value. Every `/internal/tenant-map` and `/internal/storage`
call from the agent returned HTTP 401, the agent's tenant-map cache stayed
empty, and zero `usage_records` rows were written until an operator
manually regenerated the env file and restarted the agent. The agent's
auth-failure logs were also silenced post-restart, so journald gave no
hint either. Evidence:
`docs/runbooks/evidence/staging-metering/20260501T213000Z_lb8_fixed_GREEN/`.

### Cutover (minimum required steps)

1. Update SSM `/fjcloud/<env>/internal_auth_token` to the new value.
2. Restart the fjcloud API process so the API loads the new value.
3. **For every Flapjack VM**: regenerate `/etc/flapjack/metering-env` from
   current SSM and restart `fj-metering-agent`. Do not pass the decrypted token
   as a `sed` replacement or `curl -H` argument because command-line arguments
   can be exposed through process inspection:

```bash
# Per-VM, via SSM exec:
NEW_KEY="$(aws ssm get-parameter --region us-east-1 \
  --name /fjcloud/<env>/internal_auth_token \
  --with-decryption --query Parameter.Value --output text)"

printf '%s' "$NEW_KEY" | sudo python3 -c '
import sys
from pathlib import Path

key = sys.stdin.read().rstrip("\n")
path = Path("/etc/flapjack/metering-env")
lines = path.read_text().splitlines()
updated = False
out = []
for line in lines:
    if line.startswith("INTERNAL_KEY="):
        out.append(f"INTERNAL_KEY={key}")
        updated = True
    else:
        out.append(line)
if not updated:
    out.append(f"INTERNAL_KEY={key}")
path.write_text("\n".join(out) + "\n")
'
sudo systemctl restart fj-metering-agent
```

### Post-rotation verification

1. From the Flapjack VM, probe with a curl config on stdin so the internal key
   stays out of argv/process listings:

```bash
HTTP_CODE="$(
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' --config - <<EOF
header = "x-internal-key: $INTERNAL_KEY"
url = "$TENANT_MAP_URL"
EOF
)"
test "$HTTP_CODE" = "200"
```

   HTTP 200 (NOT 401) is the canary for stale-key drift.
2. Within 60-120 s of agent restart, confirm `usage_records` rows are flowing:
   `SELECT count(*), MAX(recorded_at) FROM usage_records WHERE recorded_at > now() - interval '5 minutes';`
   should return non-zero count and a `recorded_at` within the last minute.

### Durable cures (recommended, not yet implemented)

Pick one of:
- **`ExecStartPre=` in fj-metering-agent systemd unit** that regenerates the
  env from SSM on every restart. Means a simple `systemctl restart` is enough
  — no manual sed required. Requires a permanent regen script on every
  Flapjack VM, baked into the AMI.
- **Drift alert**: a probe that compares SSM `/fjcloud/<env>/internal_auth_token`
  against the value the agent is using (detectable via a 401 from the agent's
  own probe of `/internal/tenant-map`), pages on drift > 1 hour.
- **Fix the agent's silenced logging** so the next time auth fails, journald
  shows `tracing::error!("storage poll failed: {:#}")` again. This was working
  pre-Apr 26 and broke at the restart; root cause unknown.

## Sequencing Guidance Across Secret Families

1. Rotate Stripe and SES first when possible; these changes are isolated from bearer-token continuity.
2. Rotate JWT last because it has immediate session impact.
3. **`internal_auth_token` requires the per-Flapjack-VM regen step described above** — do NOT rotate it without the VM-side cutover or metering will silently break for as long as the drift persists.
4. Run post-rotation verification after each family before proceeding to the next.
5. Launch-close sequencing owner remains `LAUNCH.md`: capture fresh evidence bundles first, then close Stage 6/status docs; this runbook owns secret cutover mechanics only.
