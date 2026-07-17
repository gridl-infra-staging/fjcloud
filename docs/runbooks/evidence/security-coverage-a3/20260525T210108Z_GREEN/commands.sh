#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EVDIR="${EVDIR:-$SCRIPT_DIR}"
mkdir -p "$EVDIR"

REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
UTC_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GIT_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"

CARGO_LOG="$EVDIR/cargo_api_section3.log"
OAUTH_LOG="$EVDIR/oauth_redirect_uri_contract_staging.log"
EC2_LOG="$EVDIR/ec2_firewalld_contract.log"
BAD_SIG_LOG="$EVDIR/stripe_webhook_bad_signature_reject_contract.log"
STALE_TS_LOG="$EVDIR/stripe_webhook_stale_timestamp_reject_contract.log"
WRONG_SECRET_LOG="$EVDIR/tenant_jwt_wrong_secret_reject_contract.log"
STATUS_LINES="$EVDIR/live_prod_status_lines.txt"
STATUS_ASSERTIONS="$EVDIR/live_prod_status_assertions.log"

assert_safe_artifact_path() {
  local output_path="$1"

  if [[ -L "$output_path" ]]; then
    printf 'FAIL: refusing to overwrite symlink artifact %s\n' "$output_path" >&2
    return 1
  fi

  if [[ -e "$output_path" && ! -f "$output_path" ]]; then
    printf 'FAIL: refusing to overwrite non-regular artifact %s\n' "$output_path" >&2
    return 1
  fi
}

assert_http_status_code() {
  local response_file="$1"
  local expected_code="$2"
  local status_line

  status_line="$(head -n 1 "$response_file" | tr -d '\r')"
  if [[ ! "$status_line" =~ ^HTTP/[0-9.]+[[:space:]]+$expected_code([[:space:]]*)$ ]]; then
    printf 'FAIL: %s expected HTTP status %s but got "%s"\n' \
      "$response_file" "$expected_code" "$status_line" >&2
    return 1
  fi

  printf 'PASS: %s matched HTTP status %s ("%s")\n' \
    "$response_file" "$expected_code" "$status_line"
  }

for artifact_path in \
  "$CARGO_LOG" \
  "$OAUTH_LOG" \
  "$EC2_LOG" \
  "$BAD_SIG_LOG" \
  "$STALE_TS_LOG" \
  "$WRONG_SECRET_LOG" \
  "$STATUS_LINES" \
  "$STATUS_ASSERTIONS" \
  "$EVDIR/owner_manifest.txt" \
  "$EVDIR/SUMMARY.md"; do
  assert_safe_artifact_path "$artifact_path"
done

cat >"$EVDIR/owner_manifest.txt" <<EOF
Stage goal: fresh Section-3 evidence bundle proving existing matrix rows are enforced.
UTC timestamp: $UTC_NOW
Git HEAD: $GIT_HEAD

Rust owners:
- stripe_webhook_signature_test
- security_test
- noisy_neighbor_test
- auth_lockout_test
- api_key_auth_test
- internal_auth_test
- auth_test

Shell probe owners:
- oauth_redirect_uri_contract.sh staging
- ec2_firewalld_contract.sh
- stripe_webhook_bad_signature_reject_contract.sh
- stripe_webhook_stale_timestamp_reject_contract.sh
- tenant_jwt_wrong_secret_reject_contract.sh
EOF

pushd "$REPO_ROOT" >/dev/null

export FJCLOUD_SECRET_FILE=/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret
source scripts/lib/env.sh
load_env_file "$FJCLOUD_SECRET_FILE"
export APP_BASE_URL_STAGING=https://cloud.staging.flapjack.foo

(
  cd infra
  cargo test -p api --test stripe_webhook_signature_test --test security_test --test noisy_neighbor_test --test auth_lockout_test --test api_key_auth_test --test internal_auth_test --test auth_test
) 2>&1 | tee "$CARGO_LOG"

bash scripts/canary/contracts/oauth_redirect_uri_contract.sh staging 2>&1 | tee "$OAUTH_LOG"

set +e
bash scripts/canary/contracts/ec2_firewalld_contract.sh 2>&1 | tee "$EC2_LOG"
ec2_exit=$?
set -e

if [[ $ec2_exit -eq 0 ]]; then
  ec2_verdict="PASS"
else
  if rg -q "AuthFailure|Unable to locate credentials|InvalidClientTokenId|ExpiredToken" "$EC2_LOG"; then
    ec2_verdict="BLOCKED: AWS AuthFailure or invalid credentials at execution time"
  else
    echo "FAIL: ec2_firewalld_contract.sh failed for non-credential reason (exit=$ec2_exit)" >&2
    exit "$ec2_exit"
  fi
fi

EVDIR="$EVDIR" bash scripts/canary/contracts/stripe_webhook_bad_signature_reject_contract.sh 2>&1 | tee "$BAD_SIG_LOG"
EVDIR="$EVDIR" bash scripts/canary/contracts/stripe_webhook_stale_timestamp_reject_contract.sh 2>&1 | tee "$STALE_TS_LOG"
EVDIR="$EVDIR" bash scripts/canary/contracts/tenant_jwt_wrong_secret_reject_contract.sh 2>&1 | tee "$WRONG_SECRET_LOG"

awk 'FNR==1 { sub(/\r$/, ""); print }' \
  "$EVDIR/live_prod_stripe_webhook_bad_signature_reject.response" \
  "$EVDIR/live_prod_stripe_webhook_stale_timestamp_reject.response" \
  "$EVDIR/live_prod_tenant_jwt_wrong_secret_reject.response" > "$STATUS_LINES"
{
  assert_http_status_code "$EVDIR/live_prod_stripe_webhook_bad_signature_reject.response" 400
  assert_http_status_code "$EVDIR/live_prod_stripe_webhook_stale_timestamp_reject.response" 400
  assert_http_status_code "$EVDIR/live_prod_tenant_jwt_wrong_secret_reject.response" 401
} >"$STATUS_ASSERTIONS" 2>&1

cat >"$EVDIR/SUMMARY.md" <<EOF
# Section-3 Security Coverage Evidence Bundle

- Stage goal: refresh all existing Section-3 owners/probes into one reproducible evidence bundle.
- Bundle directory: $EVDIR
- UTC timestamp (summary finalized): $UTC_NOW
- Git HEAD: $GIT_HEAD

## Invocation Contract
- \`$EVDIR/commands.sh\`
- Env-loading seam for staging commands: \`source scripts/lib/env.sh\`, \`load_env_file "\$FJCLOUD_SECRET_FILE"\`, \`APP_BASE_URL_STAGING=https://cloud.staging.flapjack.foo\`

## Owner Manifest
- \`$EVDIR/owner_manifest.txt\`

## Coverage Results
| Coverage | Owner | Artifact(s) | Verdict |
| --- | --- | --- | --- |
| Rust test boundary | \`cargo test -p api --test stripe_webhook_signature_test --test security_test --test noisy_neighbor_test --test auth_lockout_test --test api_key_auth_test --test internal_auth_test --test auth_test\` | \`cargo_api_section3.log\` | PASS |
| Staging OAuth redirect URI contract | \`oauth_redirect_uri_contract.sh staging\` | \`oauth_redirect_uri_contract_staging.log\` | PASS |
| EC2 firewalld contract | \`ec2_firewalld_contract.sh\` | \`ec2_firewalld_contract.log\` | $ec2_verdict |
| Live prod reject probe | \`stripe_webhook_bad_signature_reject_contract.sh\` | \`stripe_webhook_bad_signature_reject_contract.log\`, \`live_prod_stripe_webhook_bad_signature_reject.response\` | PASS (HTTP 400) |
| Live prod reject probe | \`stripe_webhook_stale_timestamp_reject_contract.sh\` | \`stripe_webhook_stale_timestamp_reject_contract.log\`, \`live_prod_stripe_webhook_stale_timestamp_reject.response\` | PASS (HTTP 400) |
| Live prod reject probe | \`tenant_jwt_wrong_secret_reject_contract.sh\` | \`tenant_jwt_wrong_secret_reject_contract.log\`, \`live_prod_tenant_jwt_wrong_secret_reject.response\` | PASS (HTTP 401) |
| Live prod status assertion roll-up | status lines per artifact first line | \`live_prod_status_lines.txt\`, \`live_prod_status_assertions.log\` | PASS |

## Notes
- The three live-prod probes write full HTTP transcripts to \`live_prod_*.response\`; status verification is based on the status code in each artifact first line.
- EC2 contract verdict is PASS only when the shell owner exits 0; credential auth failures are explicitly reported as BLOCKED.
EOF

popd >/dev/null
