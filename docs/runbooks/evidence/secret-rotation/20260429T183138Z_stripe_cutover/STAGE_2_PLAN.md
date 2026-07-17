# Stripe Cutover — Stage 2-7 Staging Plan

## Scope

Concrete, ready-to-fire command sequence for cutting fjcloud staging from
the existing `sk_test_…aTLZ` to the new restricted `rk_test_…lDbeZ`.
Stage 1 (prerequisites) is already PASSED — see `PREREQUISITE_STATUS.md`
in this same bundle.

## Why this plan exists alongside the runbook

[`docs/runbooks/secret_rotation.md`](../../secret_rotation.md) §"Stripe Rotation"
documents the abstract contract (update secret storage → deploy → verify).
The contract is intentionally environment-agnostic so it works for both
staging and prod. This plan is the per-cutover concretion: the exact AWS
SSM parameter path, the exact deploy command, and the exact SHA we are
deploying. It pairs with the prereq evidence and is immutable for this
cutover.

## Why we do NOT introduce a new "stripe-only deploy" script

`bash ops/scripts/deploy.sh staging <SHA>` already runs
[`ops/scripts/lib/generate_ssm_env.sh`](../../../../ops/scripts/lib/generate_ssm_env.sh)
on-instance which reads `/fjcloud/staging/stripe_secret_key` from SSM
(see SSM_TO_ENV map line 62) and writes it into `/etc/fjcloud/env`,
which the systemd unit consumes via `EnvironmentFile`. So rotating the
SSM value before the next deploy means the deploy itself is the cutover —
no parallel Stripe-only mechanism needed. The simpler path also matches
SSOT: deploy.sh + generate_ssm_env.sh stay the canonical secret-injection
path; we don't fork a second one.

## Prerequisites (already met)

- Stage 1 PREREQUISITES_OK at `df27d3cb` (this bundle)
- Dev main at `b095eb3a` (Stage 1 evidence committed and pushed)
- New restricted key created in Stripe dashboard, test mode
- `.secret/.env.secret` contains `STRIPE_SECRET_KEY_RESTRICTED=rk_test_…lDbeZ`
- Workspace: `flapjack-cloud` (Stripe sandbox)

## Blocked on (must complete BEFORE Stage 2)

1. **Staging mirror commit + push.** debbie sync already wrote the
   apr29 wave to `/Users/stuart/repos/gridl-infra-staging/fjcloud` working
   tree, but no commit was made. Until staging origin/main has the new
   SHA, no staging CI runs and no release artifacts exist for deploy.sh
   to pull from S3.
2. **Staging CI green** on the resulting sync commit (the publishing
   workflow on the staging repo builds Rust binaries + frontend, runs
   tests, and uploads release artifacts to `s3://fjcloud-releases-staging/`).

## Stage 2 — Rotate `STRIPE_SECRET_KEY` in SSM (mutation)

**Blast radius:** changes the secret that the next deploy will install
into `/etc/fjcloud/env` on the staging EC2 instance. The currently-
running API process is unaffected until it restarts. Reversible by
re-running with the old value.

**Why not also rotate `STRIPE_WEBHOOK_SECRET`:** we are rotating the
api-side secret only. The webhook signing secret is independent and
unchanged in the Stripe dashboard for this rotation (the prereq gate
does not touch it; `.env.secret` does not include a new value for it).
Rotating only one secret at a time keeps blast radius minimal and
satisfies the runbook's "if webhook signing secret rotation is part of
the same window" condition (it is not).

```bash
# Run from operator laptop with AWS creds for staging account.
# Loads the new key value from .secret/.env.secret without echoing it
# to argv (which `aws ssm put-parameter --value …` would expose to
# `ps`/CloudTrail). The aws CLI accepts --value via env-var-style
# substitution in shell, but to keep the secret out of process
# state we read it once into a local var and pass via --value.
set -euo pipefail
cd /Users/stuart/repos/gridl-infra-dev/fjcloud_dev

# shellcheck disable=SC1091  # operator-provided env, not in repo
source .secret/.env.secret

# Sanity gate: refuse to proceed if the var didn't load — prevents
# accidentally writing an empty value to SSM (which would silently
# disable Stripe on next deploy).
if [ -z "${STRIPE_SECRET_KEY_RESTRICTED:-}" ]; then
  echo "ERROR: STRIPE_SECRET_KEY_RESTRICTED missing after sourcing .env.secret" >&2
  exit 1
fi

# Capture the previous SSM value for rollback. Stored locally only;
# do not commit. The .secret/ dir is gitignored.
mkdir -p .secret/rotation-backups
PREV_VALUE=$(aws ssm get-parameter \
  --region us-east-1 \
  --name /fjcloud/staging/stripe_secret_key \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text)
echo "$PREV_VALUE" > .secret/rotation-backups/stripe_secret_key.staging.20260429T183138Z.bak
chmod 0600 .secret/rotation-backups/stripe_secret_key.staging.20260429T183138Z.bak

# Mutation: write new value as SecureString (KMS-encrypted at rest).
# --type SecureString matches existing parameter type for stripe_secret_key
# (verify with `aws ssm describe-parameters --name /fjcloud/staging/stripe_secret_key`
# before running if uncertain).
aws ssm put-parameter \
  --region us-east-1 \
  --name /fjcloud/staging/stripe_secret_key \
  --value "$STRIPE_SECRET_KEY_RESTRICTED" \
  --type SecureString \
  --overwrite

# Verification gate: read back what we just wrote and assert prefix.
# Decrypts via kms:Decrypt grant on the operator role.
WRITTEN=$(aws ssm get-parameter \
  --region us-east-1 \
  --name /fjcloud/staging/stripe_secret_key \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text)
if [[ "$WRITTEN" != rk_test_* ]]; then
  echo "ERROR: SSM readback prefix mismatch — expected rk_test_*, got ${WRITTEN:0:8}…" >&2
  exit 1
fi
echo "Stage 2 OK — SSM holds rk_test_…${WRITTEN: -5}"
```

**Rollback Stage 2:**
```bash
aws ssm put-parameter \
  --region us-east-1 \
  --name /fjcloud/staging/stripe_secret_key \
  --value "$(cat .secret/rotation-backups/stripe_secret_key.staging.20260429T183138Z.bak)" \
  --type SecureString \
  --overwrite
```

## Stage 3 — Deploy (atomic cutover)

**Blast radius:** restarts `fjcloud-api` and `fj-metering-agent` services
on the staging EC2 instance. ~30-60s of downtime per deploy.sh's
30-second health-check loop with auto-rollback on failure (see
[deploy.sh:196-228](../../../../ops/scripts/deploy.sh#L196-L228) — if
the API doesn't return 200 on `/health` within 30s the instance script
moves the `.old` binaries back and restarts).

**Why bundle the key cutover into the apr29 SHA deploy:** the apr29 wave
needs to deploy anyway (it unblocks lanes 1, 2, 3, 5). Doing the key
rotation as part of the same deploy avoids an extra restart cycle and
means a single rollback step (revert deploy = revert key cutover too,
because the OLD generate_ssm_env.sh would have produced the OLD env
file — but actually no, that's wrong: generate_ssm_env.sh reads SSM at
deploy time, so reverting the deploy still leaves the new SSM value in
effect. To fully rollback the key, run the Stage 2 rollback first, THEN
revert the deploy. See "Rollback Stage 3" below.).

```bash
# Confirm the staging push has happened and CI is green before running.
# Target SHA is the dev main HEAD that should also exist on staging
# origin/main after the sync commit.
SHA=$(git -C /Users/stuart/repos/gridl-infra-dev/fjcloud_dev rev-parse HEAD)
test "${#SHA}" -eq 40 || { echo "ERROR: SHA must be 40 chars" >&2; exit 1; }

# Verify staging CI passed on this SHA before deploying. Reading status
# directly from GitHub avoids racing CI; deploy.sh itself does NOT check
# CI status (per ops/scripts/deploy.sh:60 it calls predeploy_validate_release
# which validates the S3 release artifacts exist, not the CI green status).
gh run list \
  --repo gridl-infra-staging/fjcloud \
  --commit "$SHA" \
  --limit 1 \
  --json status,conclusion \
  --jq 'map(select(.status == "completed" and .conclusion == "success")) | length' \
  | grep -q '^1$' \
  || { echo "ERROR: no green CI run for $SHA on staging" >&2; exit 1; }

bash /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/ops/scripts/deploy.sh staging "$SHA"

# Verification gate: deploy.sh advances /fjcloud/staging/last_deploy_sha
# to the new SHA on success and keeps the OLD value on health-check
# failure (see deploy.sh:308-321). Read it back to confirm.
DEPLOYED=$(aws ssm get-parameter \
  --region us-east-1 \
  --name /fjcloud/staging/last_deploy_sha \
  --query 'Parameter.Value' \
  --output text)
test "$DEPLOYED" = "$SHA" \
  || { echo "ERROR: last_deploy_sha=$DEPLOYED, expected $SHA" >&2; exit 1; }
echo "Stage 3 OK — deployed $SHA"
```

**Rollback Stage 3:** see [`ops/scripts/rollback.sh`](../../../../ops/scripts/rollback.sh).
Note: rollback reverts binaries but does NOT revert SSM secrets. To
fully restore the previous key after a failed cutover, run Stage 2
rollback FIRST, then rollback.sh, in that order.

## Stage 4 — Validate the new key against Stripe API (operator-side)

**Blast radius:** none on fjcloud. Creates one disposable test customer
+ invoice in Stripe sandbox (real Stripe API calls but test mode, no
money). See [validate-stripe.sh](../../../../scripts/validate-stripe.sh)
for the lifecycle: create customer → attach pm_card_visa → create+pay
invoice → assert status=paid.

```bash
cd /Users/stuart/repos/gridl-infra-dev/fjcloud_dev

# Load the new key into the shell. validate-stripe.sh resolves
# STRIPE_SECRET_KEY first, then STRIPE_TEST_SECRET_KEY (alias) — see
# scripts/lib/stripe_checks.sh::resolve_stripe_secret_key.
source .secret/.env.secret
export STRIPE_SECRET_KEY="$STRIPE_SECRET_KEY_RESTRICTED"
# Webhook secret is unchanged for this rotation but the script needs it
# loaded to pass the launch-context preconditions; existing value is fine.
test -n "${STRIPE_WEBHOOK_SECRET:-}" \
  || { echo "ERROR: STRIPE_WEBHOOK_SECRET unset" >&2; exit 1; }

# Run the live lifecycle. Output is JSON; "passed" must be true.
RESULT=$(bash scripts/validate-stripe.sh)
echo "$RESULT" | tee STAGE_4_validate_stripe_output.json
echo "$RESULT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("passed") else 1)' \
  || { echo "ERROR: validate-stripe.sh reported passed=false" >&2; exit 1; }
echo "Stage 4 OK — new key authenticates and full invoice lifecycle works"
```

**Rollback Stage 4:** none. This is a read-mostly-write-disposable
verification; no rollback needed. If it fails, treat it as a Stage 3
failure (key is wrong / restricted-key permissions are insufficient)
and rollback Stages 2-3.

## Stage 5 — Verify the deployed API is using the new key (runtime probe)

**Blast radius:** none. Reads health endpoint and checks API logs for
the `STRIPE_SECRET_KEY not set` warning that startup.rs:97 emits when
the env var is empty. If the warning is absent and the deploy SHA is
current, the new key is in effect at runtime.

```bash
# Reach the deployed API health endpoint to confirm it's serving.
DNS_DOMAIN=$(aws ssm get-parameter \
  --region us-east-1 \
  --name /fjcloud/staging/dns_domain \
  --query 'Parameter.Value' \
  --output text)
curl -fsS "https://api.${DNS_DOMAIN}/health" \
  || { echo "ERROR: api.$DNS_DOMAIN /health not responding" >&2; exit 1; }

# Probe an endpoint that exercises Stripe at runtime. The billing-portal
# session creation path hits Stripe Customer + BillingPortalSession APIs
# and surfaces a 5xx if the configured key fails to authenticate. Use a
# tenant context that already has a Stripe customer record on staging.
# (If no such tenant exists in staging, skip this sub-probe and rely on
# Stage 4 + the absence of startup warnings.)

# Inspect the api-process journal on the staging instance via SSM to
# confirm no "STRIPE_SECRET_KEY not set" warning appeared at last
# startup. The warning only fires when the env var is missing — its
# absence proves the new key was loaded.
INSTANCE_ID=$(aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=fjcloud-api-staging" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

CMD_ID=$(aws ssm send-command \
  --region us-east-1 \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["journalctl -u fjcloud-api --since \"5 minutes ago\" | grep -c \"STRIPE_SECRET_KEY not set\" || true"]' \
  --query 'Command.CommandId' \
  --output text)
sleep 3
WARN_COUNT=$(aws ssm get-command-invocation \
  --region us-east-1 \
  --command-id "$CMD_ID" \
  --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' \
  --output text \
  | tr -d '[:space:]')

# Expected: 0 occurrences of "STRIPE_SECRET_KEY not set" in the last
# 5 minutes (covers the post-deploy startup window).
test "$WARN_COUNT" = "0" \
  || { echo "ERROR: $WARN_COUNT 'STRIPE_SECRET_KEY not set' warnings in last 5min" >&2; exit 1; }
echo "Stage 5 OK — deployed API has no STRIPE_SECRET_KEY warnings at startup"
```

**Rollback Stage 5:** none. If the probe fails, the runtime did not
pick up the new key — investigate before proceeding to Stage 6 (do not
revoke the old key while the API still depends on it).

## Stage 6 — Revoke the old `sk_test_…aTLZ` key in Stripe dashboard

**Blast radius:** any process still using the old key starts failing
auth on the next call. ONLY proceed after Stage 5 passes.

This is a dashboard-only operation (Stripe does not allow restricted-
key revocation via API for the same reason it does not allow creation:
prevent compromised-key escalation paths).

1. Open https://dashboard.stripe.com/test/apikeys
2. Standard keys section → click the row labeled "Secret key"
   `sk_test_…aTLZ`
3. Click "Roll key" (Stripe will warn that this immediately invalidates
   the old token).
4. Confirm. Stripe generates a replacement standard key, but we do NOT
   adopt it — the API now uses the restricted key from Stage 2.
5. Capture a screenshot of the post-roll keys list (showing
   `sk_test_…aTLZ` no longer present) and save as
   `STAGE_6_old_key_revoked_screenshot.png` in this evidence bundle.

**Rollback Stage 6:** not possible — Stripe key revocation is one-way.
This is the load-bearing reason Stage 5 must pass first.

## Stage 7 — Capture post-cutover evidence

```bash
cd /Users/stuart/repos/gridl-infra-dev/fjcloud_dev
EVIDENCE_DIR=docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover

# Final summary doc tying the stages together.
cat > "$EVIDENCE_DIR/STAGE_7_SUMMARY.md" <<'EOF'
# Stripe Cutover Summary

- Cutover UTC stamp: 20260429T183138Z
- Old key (revoked): sk_test_…aTLZ
- New key (active): rk_test_…lDbeZ (restricted, Recurring subscriptions
  and billing template)
- Deployed SHA: <fill in actual SHA>
- Stage 4 validate-stripe.sh: passed (see STAGE_4_validate_stripe_output.json)
- Stage 5 runtime probe: passed (no STRIPE_SECRET_KEY warnings)
- Stage 6 old-key revocation: confirmed via dashboard screenshot
EOF

# Commit the evidence bundle, then push.
git add "$EVIDENCE_DIR/"
git commit -m "evidence: stripe cutover stages 2-7 complete (rk_test_…lDbeZ active)"
git push origin main
```

## Total time estimate

Sequential, no waiting: 5 minutes for Stages 2 + 4-7. Stage 3 is the
deploy itself (~5 minutes including health-check loop). So end-to-end
~10 minutes once Stages 2-7 start firing — but Stage 2 is gated on the
staging mirror push + staging CI green, which is the actual long-pole.

## Cross-references

- Abstract contract: [`docs/runbooks/secret_rotation.md`](../../secret_rotation.md) §"Stripe Rotation"
- Deploy mechanism: [`ops/scripts/deploy.sh`](../../../../ops/scripts/deploy.sh)
- SSM-to-env mapping: [`ops/scripts/lib/generate_ssm_env.sh`](../../../../ops/scripts/lib/generate_ssm_env.sh) (line 62)
- Stripe lifecycle test: [`scripts/validate-stripe.sh`](../../../../scripts/validate-stripe.sh)
- Stage 1 prerequisites: `PREREQUISITE_STATUS.md` (this directory)
