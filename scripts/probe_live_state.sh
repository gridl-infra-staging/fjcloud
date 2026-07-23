#!/usr/bin/env bash
# scripts/probe_live_state.sh — fjcloud realization of Live State Discipline.
#
# Per-project read-only inventory probe. Hits every external mutable-state surface
# fjcloud touches (Stripe, AWS SNS/SSM, Cloudflare DNS/Pages, staging RDS, staging
# API health, Privacy.com) and writes a dated snapshot to docs/live-state/<ts>/
# with a SUMMARY.md downstream lanes consume.
#
# CONTRACT (read these before changing):
# - Read-only. No mutations. Exit 0 ALWAYS (data, not enforcement — per discipline).
# - Per-section errors → status=PROBE_ERROR in SUMMARY (distinct from ACTION_REQUIRED).
# - Missing creds for a section → status=SKIP_NO_CREDS (distinct from PROBE_ERROR).
# - Idempotent per UTC-second; re-runs in same second overwrite same TS dir.
# - The script ships to public mirrors (scripts/ is whitelisted in .debbie.toml).
#   Therefore: NO absolute operator-machine paths, NO hardcoded AWS account IDs, NO
#   embedded secrets. The probe's OUTPUTS land under docs/live-state/ which
#   IS excluded from public mirrors.
#
# DISCIPLINE: see ~/.matt/scrai/globals/standards/live_state_discipline.md
# This is a state-inventory probe. Behavioral assumptions (signup → token
# verification, etc.) belong in scripts/canary/contracts/ — separate concern.
#
# REUSE:
# - scripts/lib/stripe_checks.sh — check_stripe_key_live (sourced via subshell
#   only; it runs `set -euo pipefail` at top level + `exit 124` on timeout,
#   which would break this script's exit-0-always discipline if sourced directly).
# - scripts/lib/live_gate.sh — not currently sourced; live_gate_* helpers exist
#   but the probe doesn't need OK/SKIP gating semantics.
#
# OVERRIDE: FJCLOUD_SECRET_FILE may override the default ./.secret/.env.secret path.
# Default follows CLAUDE.md secrets contract (repo-local .secret/.env.secret).
#
# SUMMARY.md row format (downstream A4 + A5.3 + Wave 1 lanes parse this):
#   ### <vendor_id>
#   - status: OK|DRIFT|STALE|ACTION_REQUIRED|PROBE_ERROR|SKIP_NO_CREDS
#   - agent_executable: true|false       # filter for A5.3 automated diff
#   - finding: <one-line>
#   - raw: <relative path to raw subfile>
#
# manifest.txt lists every raw subfile this run produced — A2.3 validation
# uses the manifest (not glob) so empty-but-valid vendor responses don't false-fail.

set -uo pipefail
# NOTE: deliberately NOT `set -e` — per-vendor errors must not abort the script.
# Each section captures its own error state into the SUMMARY.

PROBE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 0. Bootstrap
# ---------------------------------------------------------------------------

SECRET_FILE="${FJCLOUD_SECRET_FILE:-./.secret/.env.secret}"
if [ ! -f "$SECRET_FILE" ]; then
  echo "FAIL_NO_SECRETS: $SECRET_FILE not found" >&2
  echo "Set FJCLOUD_SECRET_FILE or run from the dev-repo root" >&2
  exit 2
fi

load_secret_env_file() {
  local secret_file="$1"
  local parsed_exports

  if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL_NO_PYTHON: python3 required to parse $secret_file safely" >&2
    return 1
  fi

  parsed_exports="$(mktemp)" || return 1
  if ! chmod 600 "$parsed_exports"; then
    rm -f "$parsed_exports"
    return 1
  fi

  if ! python3 - "$secret_file" > "$parsed_exports" <<'PY'
import ast
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])

for line_number, raw_line in enumerate(path.read_text().splitlines(), start=1):
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue

    if line.startswith("export "):
        line = line[len("export "):].lstrip()

    match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
    if not match:
        raise SystemExit(f"{path}:{line_number}: expected KEY=VALUE entry")

    key, raw_value = match.groups()
    value = raw_value.strip()
    if value[:1] == value[-1:] and value[:1] in {"'", '"'}:
        try:
            value = ast.literal_eval(value)
        except (SyntaxError, ValueError) as exc:
            raise SystemExit(f"{path}:{line_number}: invalid quoted value for {key}: {exc}") from exc

    sys.stdout.buffer.write(f"{key}={value}".encode("utf-8") + b"\0")
PY
  then
    rm -f "$parsed_exports"
    return 1
  fi

  while IFS= read -r -d '' entry; do
    export "$entry"
  done < "$parsed_exports"

  rm -f "$parsed_exports"
}

if ! load_secret_env_file "$SECRET_FILE"; then
  echo "FAIL_INVALID_SECRETS: $SECRET_FILE could not be parsed as literal KEY=VALUE entries" >&2
  exit 2
fi

if [ -n "${FLEET_DATAPLANE_PROBE:-}" ] && [ -z "${LIVE_STATE_OUTPUT_PATH:-}" ]; then
  echo "FAIL_UNSAFE_PROBE_OVERRIDE: FLEET_DATAPLANE_PROBE requires LIVE_STATE_OUTPUT_PATH" >&2
  exit 2
fi
if [ -n "${USAGE_ROLLUP_FRESHNESS_PROBE:-}" ] && [ -z "${LIVE_STATE_OUTPUT_PATH:-}" ]; then
  echo "FAIL_UNSAFE_PROBE_OVERRIDE: USAGE_ROLLUP_FRESHNESS_PROBE requires LIVE_STATE_OUTPUT_PATH" >&2
  exit 2
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
if [ -n "${LIVE_STATE_OUTPUT_PATH:-}" ]; then
  SUMMARY="$LIVE_STATE_OUTPUT_PATH"
  OUT="$(dirname "$SUMMARY")"
else
  OUT="docs/live-state/$TS"
  SUMMARY="$OUT/SUMMARY.md"
fi
OUTPUT_PATH="$SUMMARY"
mkdir -p "$OUT"
MANIFEST="$OUT/manifest.txt"
: > "$MANIFEST"   # truncate

cat > "$SUMMARY" <<EOF
# fjcloud live-state snapshot — $TS

Generated by \`scripts/probe_live_state.sh\` per [Live State Discipline](~/.matt/scrai/globals/standards/live_state_discipline.md).

Row format: \`status\` ∈ {OK, DRIFT, STALE, ACTION_REQUIRED, PROBE_ERROR, SKIP_NO_CREDS};
\`agent_executable: true\` rows are fixable by the inline agent and must flip to OK
by Phase A's end (per A5.3); \`agent_executable: false\` rows go to the operator
playbook.

EOF

# Helper: append a SUMMARY row. Args: vendor_id, status, agent_executable, finding, raw_file
add_row() {
  local vendor="$1" status="$2" ae="$3" finding="$4" raw="$5"
  {
    printf '### %s\n' "$vendor"
    printf -- '- status: %s\n' "$status"
    printf -- '- agent_executable: %s\n' "$ae"
    printf -- '- finding: %s\n' "$finding"
    printf -- '- raw: %s\n\n' "$raw"
  } >> "$SUMMARY"
}

# Helper: register a raw subfile in the manifest (relative to $OUT).
register_raw() {
  printf '%s\n' "$1" >> "$MANIFEST"
}

curl_config_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

create_secure_curl_config_file() {
  local curl_config_file
  curl_config_file="$(mktemp)" || return 1
  if ! chmod 600 "$curl_config_file"; then
    rm -f "$curl_config_file"
    return 1
  fi
  printf '%s\n' "$curl_config_file"
}

append_curl_config_value() {
  local curl_config_file="$1"
  local key="$2"
  local value="$3"
  printf '%s = "%s"\n' "$key" "$(curl_config_escape "$value")" >> "$curl_config_file"
}

append_curl_header_config() {
  append_curl_config_value "$1" header "$2"
}

append_curl_user_config() {
  append_curl_config_value "$1" user "$2"
}

redact_cloudflare_pages_env_values() {
  local json_path="$1"

  if [ ! -f "$json_path" ]; then
    return
  fi

  if ! command -v python3 >/dev/null; then
    printf '{"redacted":true,"reason":"python3 unavailable before Cloudflare Pages env-var value redaction"}\n' > "$json_path"
    return
  fi

  python3 - "$json_path" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())

def redact_env_vars(node):
    if isinstance(node, dict):
        env_vars = node.get("env_vars")
        if isinstance(env_vars, dict):
            for spec in env_vars.values():
                if isinstance(spec, dict):
                    spec.pop("value", None)
        for value in node.values():
            redact_env_vars(value)
    elif isinstance(node, list):
        for value in node:
            redact_env_vars(value)

redact_env_vars(data)
path.write_text(json.dumps(data, indent=2) + "\n")
PY
}

# ---------------------------------------------------------------------------
# 1. AWS identity (gates all AWS-touching sections)
# ---------------------------------------------------------------------------
# Resolve account ID at runtime — never hardcode (the script ships to public mirrors).
# If credentials are bad, every AWS section writes SKIP_NO_CREDS rather than
# constructing a bogus ARN that gets a confusing parser error from the AWS CLI.

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
AWS_OK=0
if [ -n "$AWS_ACCOUNT_ID" ] && [ "$AWS_ACCOUNT_ID" != "None" ]; then
  AWS_OK=1
fi

# ---------------------------------------------------------------------------
# 2. Stripe — probe each key's liveness via check_stripe_key_live (sourced in subshell)
# ---------------------------------------------------------------------------
# Probe TEST-mode keys only. The RESTRICTED_LIVE key is live-mode; we do NOT
# call against live mode from an inventory probe (CLAUDE.md "Stripe testing"
# rule: test mode is free, do not invoke against live mode).
# Pairs: (label_for_SUMMARY, env-var-name-in-.env.secret)
STRIPE_PROBE_KEYS=(
  "stripe_canonical:STRIPE_SECRET_KEY"
  "stripe_restricted:STRIPE_SECRET_KEY_RESTRICTED"
)

for pair in "${STRIPE_PROBE_KEYS[@]}"; do
  label="${pair%%:*}"
  varname="${pair##*:}"
  raw_file="$OUT/${label}.txt"
  register_raw "${label}.txt"
  : > "$raw_file"

  key_val="${!varname:-}"
  if [ -z "$key_val" ]; then
    echo "SKIP_NO_CREDS: env var $varname is empty or unset" > "$raw_file"
    add_row "$label" "SKIP_NO_CREDS" "false" "env var $varname not present in .env.secret" "${label}.txt"
    continue
  fi

  # Probe via check_stripe_key_live in a subshell so its set -euo pipefail
  # and any exit calls don't infect this script.
  #
  # CRITICAL: set BACKEND_LIVE_GATE=1 inside the subshell. Without it,
  # check_stripe_key_live's failure paths call live_gate_fail_with_reason
  # which returns 0 when the gate is off — producing a SILENT FALSE POSITIVE
  # for any broken/dead key (verified empirically with a bogus key). With
  # the gate on, the function exits 1 on auth failure, the subshell exits 1,
  # and the parent probe catches it via probe_rc≠0 — terminating at the
  # actual Stripe HTTP response, not at the function's no-op exit.
  probe_rc=0
  probe_out="$(
    (
      STRIPE_SECRET_KEY="$key_val"
      BACKEND_LIVE_GATE=1
      # shellcheck disable=SC1091
      source scripts/lib/stripe_checks.sh
      check_stripe_key_live 2>&1
    )
  )" || probe_rc=$?

  {
    echo "label=$label"
    echo "env_var=$varname"
    echo "key_prefix=${key_val:0:8}..."   # never the full key
    echo "probe_exit_code=$probe_rc"
    echo "--- probe output ---"
    echo "$probe_out"
  } > "$raw_file"

  if [ "$probe_rc" -eq 0 ]; then
    add_row "$label" "OK" "false" "Stripe key authenticates against GET /v1/balance" "${label}.txt"
  else
    # check_stripe_key_live emits structured REASON: codes (see stripe_checks.sh:11-25)
    finding="Stripe key probe failed (rc=$probe_rc) — see raw"
    add_row "$label" "ACTION_REQUIRED" "false" "$finding" "${label}.txt"
  fi
done

# Stripe webhook_endpoints — enumerate per environment (test mode only)
# Confirms which webhook endpoints Stripe has registered for the test-mode account.
# Uses STRIPE_SECRET_KEY (test-mode) for the API call.
raw_file="$OUT/stripe_webhook_endpoints.txt"
register_raw "stripe_webhook_endpoints.txt"
if [ -n "${STRIPE_SECRET_KEY:-}" ]; then
  stripe_webhook_cfg="$(create_secure_curl_config_file)" || stripe_webhook_cfg=""
  if [ -n "$stripe_webhook_cfg" ]; then
    append_curl_user_config "$stripe_webhook_cfg" "${STRIPE_SECRET_KEY}:"
    http_status="$(curl -s -K "$stripe_webhook_cfg" -o "$OUT/stripe_webhook_endpoints.body.json" -w '%{http_code}' \
      --max-time 10 \
      "https://api.stripe.com/v1/webhook_endpoints?limit=20" 2>/dev/null || echo "000")"
    rm -f "$stripe_webhook_cfg"
  else
    http_status="000"
  fi
  register_raw "stripe_webhook_endpoints.body.json"
  {
    echo "http_status=$http_status"
    if [ "$http_status" = "200" ] && command -v python3 >/dev/null; then
      python3 -c '
import json
d = json.load(open("'"$OUT/stripe_webhook_endpoints.body.json"'"))
for e in d.get("data", []):
    eid = e.get("id")
    url = e.get("url")
    st = e.get("status")
    ev = len(e.get("enabled_events", []))
    print("- id={} url={} status={} events={}".format(eid, url, st, ev))
print("total: {}".format(len(d.get("data", []))))
'
    fi
  } > "$raw_file"
  if [ "$http_status" = "200" ]; then
    count=$(python3 -c 'import json;print(len(json.load(open("'"$OUT/stripe_webhook_endpoints.body.json"'")).get("data",[])))' 2>/dev/null || echo "?")
    add_row "stripe_webhook_endpoints" "OK" "false" "$count Stripe webhook endpoints registered (test mode)" "stripe_webhook_endpoints.txt"
  else
    add_row "stripe_webhook_endpoints" "PROBE_ERROR" "false" "Stripe /v1/webhook_endpoints returned HTTP $http_status" "stripe_webhook_endpoints.txt"
  fi
else
  echo "SKIP_NO_CREDS: STRIPE_SECRET_KEY unset" > "$raw_file"
  add_row "stripe_webhook_endpoints" "SKIP_NO_CREDS" "false" "STRIPE_SECRET_KEY unset" "stripe_webhook_endpoints.txt"
fi

# Webhook secret — just presence + prefix check (no live call from inventory)
raw_file="$OUT/stripe_webhook_secret.txt"
register_raw "stripe_webhook_secret.txt"
if [ -n "${STRIPE_WEBHOOK_SECRET:-}" ]; then
  prefix="${STRIPE_WEBHOOK_SECRET:0:6}"
  echo "prefix=$prefix" > "$raw_file"
  expected_webhook_secret_prefix="whsec""_"
  if [ "$prefix" = "$expected_webhook_secret_prefix" ]; then
    add_row "stripe_webhook_secret" "OK" "false" "STRIPE_WEBHOOK_SECRET present with expected webhook prefix" "stripe_webhook_secret.txt"
  else
    add_row "stripe_webhook_secret" "ACTION_REQUIRED" "false" "STRIPE_WEBHOOK_SECRET has wrong prefix" "stripe_webhook_secret.txt"
  fi
else
  echo "unset" > "$raw_file"
  add_row "stripe_webhook_secret" "SKIP_NO_CREDS" "false" "STRIPE_WEBHOOK_SECRET unset" "stripe_webhook_secret.txt"
fi

# Note: STRIPE_SECRET_KEY_RESTRICTED_LIVE is intentionally NOT probed (live-mode key).
# Record its presence only.
raw_file="$OUT/stripe_restricted_live_presence.txt"
register_raw "stripe_restricted_live_presence.txt"
if [ -n "${STRIPE_SECRET_KEY_RESTRICTED_LIVE:-}" ]; then
  echo "present (live-mode key — NOT probed against API)" > "$raw_file"
  add_row "stripe_restricted_live_presence" "OK" "false" "Live-mode restricted key present; not probed (test-mode only policy)" "stripe_restricted_live_presence.txt"
else
  echo "unset" > "$raw_file"
  add_row "stripe_restricted_live_presence" "STALE" "false" "STRIPE_SECRET_KEY_RESTRICTED_LIVE absent — may be intentional" "stripe_restricted_live_presence.txt"
fi

# Stripe account configuration — statement descriptor + business profile.
# Operator sets these in the Stripe Dashboard; this probe verifies the
# API-readable subset via GET /v1/account. Customer-Emails toggles
# (invoice receipts, dunning, expiring-card) are NOT exposed by this endpoint
# and must be operator-verified per docs/runbooks/paid_beta_rc_signoff.md
# "Stripe Dashboard Prerequisites".
#
# Account-level business_profile is mode-scoped: test mode returns
# `business_profile: null` while live mode returns the populated profile
# (Stripe maintains separate profiles per mode and `POST /v1/account` is
# rejected with `Only live keys can access this method` on test keys). For
# the gate to be meaningful we MUST probe with the live key; checking with a
# test key produces a misleading ACTION_REQUIRED on values that are correctly
# set in live mode. The live key is loaded from SSM (same source the prod
# API binary uses) with a 5s timeout; if SSM is unreachable we fall back to
# the env's test key and tag the row STALE so the noise is visible but not
# blocking.
raw_file="$OUT/stripe_account_config.txt"
register_raw "stripe_account_config.txt"
stripe_account_probe_key=""
stripe_account_probe_mode=""
if command -v aws >/dev/null 2>&1; then
  if live_key_value="$(aws ssm get-parameter \
      --name /fjcloud/prod/stripe_secret_key \
      --with-decryption \
      --query Parameter.Value \
      --output text \
      --cli-read-timeout 5 \
      --cli-connect-timeout 5 2>/dev/null)" \
     && [ -n "$live_key_value" ] \
     && [[ "$live_key_value" == sk_"live"_* ]]; then
    stripe_account_probe_key="$live_key_value"
    stripe_account_probe_mode="live"
  fi
fi
if [ -z "$stripe_account_probe_key" ] && [ -n "${STRIPE_SECRET_KEY:-}" ]; then
  stripe_account_probe_key="$STRIPE_SECRET_KEY"
  stripe_account_probe_mode="test_fallback"
fi
if [ -n "$stripe_account_probe_key" ]; then
  stripe_account_cfg="$(create_secure_curl_config_file)" || stripe_account_cfg=""
  if [ -n "$stripe_account_cfg" ]; then
    append_curl_user_config "$stripe_account_cfg" "${stripe_account_probe_key}:"
    http_status="$(curl -s -K "$stripe_account_cfg" -o "$OUT/stripe_account_config.body.json" -w '%{http_code}' \
      --max-time 10 \
      "https://api.stripe.com/v1/account" 2>/dev/null || echo "000")"
    rm -f "$stripe_account_cfg"
  else
    http_status="000"
  fi
  register_raw "stripe_account_config.body.json"
  stripe_account_config_parse_ok=0
  {
    echo "http_status=$http_status"
    echo "probe_mode=$stripe_account_probe_mode"
    if [ "$http_status" = "200" ] && command -v python3 >/dev/null; then
      if python3 -c '
import json
d = json.load(open("'"$OUT/stripe_account_config.body.json"'"))
sd = d.get("settings", {}).get("payments", {}).get("statement_descriptor", "")
bp = d.get("business_profile") or {}
support = bp.get("support_email", "")
url = bp.get("url", "")
name = bp.get("name", "")
print("statement_descriptor:", sd or "(unset)")
print("business_profile.support_email:", support or "(unset)")
print("business_profile.url:", url or "(unset)")
print("business_profile.name:", name or "(unset)")
missing = [k for k, v in [("statement_descriptor", sd), ("support_email", support), ("business_url", url), ("business_name", name)] if not v]
print("missing:", ",".join(missing) if missing else "(none)")
      ' 2>/dev/null; then
        stripe_account_config_parse_ok=1
      else
        echo "parse_error=true"
      fi
    fi
  } > "$raw_file"
  if [ "$http_status" = "200" ]; then
    missing_line="$(grep '^missing:' "$raw_file" | sed 's/^missing: //')"
    if [ "$stripe_account_config_parse_ok" -ne 1 ]; then
      add_row "stripe_account_config" "PROBE_ERROR" "false" "Stripe account config parser failed for /v1/account response (probed in $stripe_account_probe_mode mode)" "stripe_account_config.txt"
    elif [ "$missing_line" = "(none)" ]; then
      add_row "stripe_account_config" "OK" "false" "statement descriptor + business profile complete (probed in $stripe_account_probe_mode mode)" "stripe_account_config.txt"
    elif [ "$stripe_account_probe_mode" = "test_fallback" ]; then
      add_row "stripe_account_config" "STALE" "false" "Probed with test-mode key only (SSM /fjcloud/prod/stripe_secret_key unreachable). Test-mode business_profile is irrelevant for paid-beta launch; re-run with AWS creds for the live-mode gate." "stripe_account_config.txt"
    else
      add_row "stripe_account_config" "ACTION_REQUIRED" "false" "Stripe Dashboard missing in live mode: $missing_line (operator action — see docs/runbooks/paid_beta_rc_signoff.md Stripe Dashboard Prerequisites)" "stripe_account_config.txt"
    fi
  else
    add_row "stripe_account_config" "PROBE_ERROR" "false" "Stripe /v1/account returned HTTP $http_status (probed in $stripe_account_probe_mode mode)" "stripe_account_config.txt"
  fi
else
  echo "STRIPE_SECRET_KEY unset and SSM live key unavailable" > "$raw_file"
  add_row "stripe_account_config" "SKIP_NO_CREDS" "false" "Neither STRIPE_SECRET_KEY nor SSM /fjcloud/prod/stripe_secret_key available" "stripe_account_config.txt"
fi

# ---------------------------------------------------------------------------
# 2b. Stripe account status — payout/charge readiness receipt.
# Reuses the GET /v1/account body already fetched above (no second SSM lookup,
# no second curl). Distinct concern from stripe_account_config (statement
# descriptor + business profile): this row answers "is the account cleared to
# charge and pay out?" for the launch matrix "Payout schedule + bank account"
# row. Emits ONLY booleans/counts — no account id, email, or disabled_reason
# text — via check_stripe_account_status (a pure body-parser). Test-mode
# readiness is misleading (same rationale as stripe_account_config), so a
# test_fallback probe is tagged STALE rather than OK/ACTION_REQUIRED.
raw_file="$OUT/stripe_account_status.txt"
register_raw "stripe_account_status.txt"
if [ -z "$stripe_account_probe_key" ]; then
  echo "STRIPE_SECRET_KEY unset and SSM live key unavailable" > "$raw_file"
  add_row "stripe_account_status" "SKIP_NO_CREDS" "false" "Neither STRIPE_SECRET_KEY nor SSM /fjcloud/prod/stripe_secret_key available" "stripe_account_status.txt"
elif [ "${http_status:-000}" != "200" ]; then
  {
    echo "http_status=${http_status:-000}"
    echo "probe_mode=$stripe_account_probe_mode"
  } > "$raw_file"
  add_row "stripe_account_status" "PROBE_ERROR" "false" "Stripe /v1/account returned HTTP ${http_status:-000} (probed in $stripe_account_probe_mode mode)" "stripe_account_status.txt"
else
  # Parse in a subshell so stripe_checks.sh's `set -euo pipefail` and the
  # not-ready `exit 1` (BACKEND_LIVE_GATE=1 forces a real non-zero, mirroring
  # the check_stripe_key_live block above) cannot infect this exit-0 probe.
  # Function stderr is discarded so only booleans/counts land in the receipt.
  account_status_rc=0
  account_status_out="$(
    (
      BACKEND_LIVE_GATE=1
      # shellcheck disable=SC1091
      source scripts/lib/stripe_checks.sh
      check_stripe_account_status "$(cat "$OUT/stripe_account_config.body.json")" 2>/dev/null
    )
  )" || account_status_rc=$?
  printf '%s\n' "$account_status_out" > "$raw_file"
  if [ "$stripe_account_probe_mode" = "test_fallback" ]; then
    add_row "stripe_account_status" "STALE" "false" "Payout-readiness probed with test-mode key only (SSM /fjcloud/prod/stripe_secret_key unreachable). Re-run with AWS creds for the live-mode gate." "stripe_account_status.txt"
  elif [ "$account_status_rc" -eq 0 ]; then
    add_row "stripe_account_status" "OK" "false" "Stripe account payout-ready: charges/payouts/details enabled, no outstanding requirements (probed in $stripe_account_probe_mode mode)" "stripe_account_status.txt"
  elif ! grep -q '^charges_enabled=' "$raw_file"; then
    add_row "stripe_account_status" "PROBE_ERROR" "false" "Stripe account status parser failed for /v1/account response (probed in $stripe_account_probe_mode mode)" "stripe_account_status.txt"
  else
    add_row "stripe_account_status" "ACTION_REQUIRED" "false" "Stripe account not fully payout-ready — see booleans/counts in receipt (probed in $stripe_account_probe_mode mode)" "stripe_account_status.txt"
  fi
fi

# ---------------------------------------------------------------------------
# 3. AWS SNS — fjcloud-alerts subscriptions per environment
# ---------------------------------------------------------------------------

for env in staging prod; do
  raw_file="$OUT/aws_sns_${env}.txt"
  register_raw "aws_sns_${env}.txt"
  vendor_id="aws_sns_${env}"

  if [ "$AWS_OK" -eq 0 ]; then
    echo "SKIP_NO_CREDS: aws sts get-caller-identity failed" > "$raw_file"
    add_row "$vendor_id" "SKIP_NO_CREDS" "false" "AWS credentials not resolvable" "aws_sns_${env}.txt"
    continue
  fi

  topic_arn="arn:aws:sns:us-east-1:${AWS_ACCOUNT_ID}:fjcloud-alerts-${env}"
  subs_out="$(aws sns list-subscriptions-by-topic --topic-arn "$topic_arn" --output json 2>&1)"
  subs_rc=$?

  {
    echo "topic=$topic_arn"
    echo "list_exit_code=$subs_rc"
    echo "--- subscriptions ---"
    echo "$subs_out"
  } > "$raw_file"

  if [ "$subs_rc" -ne 0 ]; then
    add_row "$vendor_id" "PROBE_ERROR" "false" "aws sns list failed for $topic_arn" "aws_sns_${env}.txt"
    continue
  fi

  # Count subscriptions in various states
  total=$(echo "$subs_out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("Subscriptions",[])))' 2>/dev/null || echo "?")
  pending=$(echo "$subs_out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for s in d.get("Subscriptions",[]) if s.get("SubscriptionArn")=="PendingConfirmation"))' 2>/dev/null || echo "?")

  # Cross-check pending-confirmation endpoints against the canonical
  # declined-recipients list at decisions/2026-05-22_alert_email_recipients.md.
  # Pending-confirmation entries for explicitly-declined addresses are NOT drift
  # — the operator already decided against them; treating them as DRIFT was the
  # exact stale-claim-relay pattern Live State Discipline forbids.
  decision_file="decisions/2026-05-22_alert_email_recipients.md"
  pending_undecided=0
  if [ "$pending" != "0" ] && [ -f "$decision_file" ] && command -v python3 >/dev/null; then
    # Extract pending-confirmation emails from the subs JSON
    pending_emails="$(echo "$subs_out" | python3 -c '
import json,sys
d = json.load(sys.stdin)
for s in d.get("Subscriptions", []):
    if s.get("SubscriptionArn") == "PendingConfirmation":
        print(s.get("Endpoint",""))
' 2>/dev/null || true)"
    # Extract declined list from the decision file. The header is "## Declined ...";
    # we extract lines BETWEEN it and the next "## " heading. The naive
    # awk-range pattern would match only the header line (which itself matches
    # the terminator); use a flag-based state machine instead.
    declined_emails="$(awk '/^## Declined/{flag=1;next} /^## /{flag=0} flag' "$decision_file" | grep -oE '`[^`]+@[^`]+`' | tr -d '`')"
    for em in $pending_emails; do
      if ! echo "$declined_emails" | grep -qFx "$em"; then
        pending_undecided=$((pending_undecided + 1))
      fi
    done
  else
    pending_undecided="$pending"
  fi

  if [ "$pending" = "0" ]; then
    add_row "$vendor_id" "OK" "false" "$total subscriptions, 0 pending-confirmation" "aws_sns_${env}.txt"
  elif [ "$pending_undecided" -eq 0 ]; then
    # All pending entries are explicitly declined recipients — stale invites that
    # auto-expire in 3 days; not an operator action.
    add_row "$vendor_id" "OK" "false" "$total subscriptions, $pending pending-confirmation (all are explicitly-declined per decisions/2026-05-22_alert_email_recipients.md — auto-expire in 3 days, no action)" "aws_sns_${env}.txt"
  else
    # Genuinely-undecided pending subs (new addresses not in the decision file).
    # PendingConfirmation subs cannot be deleted via AWS CLI — operator must
    # confirm/cancel via email or wait 3-day auto-expiration.
    add_row "$vendor_id" "DRIFT" "false" "$total subscriptions, $pending pending-confirmation ($pending_undecided NOT in decision file — operator decision needed)" "aws_sns_${env}.txt"
  fi
done

# ---------------------------------------------------------------------------
# 4. AWS SSM — critical parameter freshness + AMI pointer capture
# ---------------------------------------------------------------------------

# Verified at probe-build time against `aws ssm get-parameters-by-path --recursive`:
# the actual param name is `stripe_webhook_secret` (NOT `stripe_webhook_signing_secret`).
# All listed params exist on both staging and prod.
SSM_PARAMS=(
  "jwt_secret"
  "stripe_secret_key"
  "stripe_webhook_secret"
  "google_oauth_client_secret"
  "github_oauth_client_secret"
  "app_base_url"
  "algolia_migration_enabled"
)

SSM_AMI_POINTER_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-us-east-1}}"
SSM_STAGING_AWS_AMI_POINTER_OUTCOME=""
SSM_STAGING_AWS_AMI_POINTER_VALUE=""
SSM_PROD_AWS_AMI_POINTER_OUTCOME=""
SSM_PROD_AWS_AMI_POINTER_VALUE=""

for env in staging prod; do
  raw_file="$OUT/aws_ssm_${env}.txt"
  register_raw "aws_ssm_${env}.txt"
  vendor_id="aws_ssm_${env}"
  : > "$raw_file"

  if [ "$AWS_OK" -eq 0 ]; then
    echo "SKIP_NO_CREDS: aws sts get-caller-identity failed" > "$raw_file"
    add_row "$vendor_id" "SKIP_NO_CREDS" "false" "AWS credentials not resolvable" "aws_ssm_${env}.txt"
    continue
  fi

  param_errors=0
  param_count=0
  for param in "${SSM_PARAMS[@]}"; do
    param_count=$((param_count + 1))
    full_name="/fjcloud/${env}/${param}"
    # Capture Version + LastModifiedDate only; never Value (security).
    meta="$(aws ssm get-parameter --name "$full_name" --query 'Parameter.{Version:Version,LastModifiedDate:LastModifiedDate}' --output json 2>&1)"
    meta_rc=$?
    {
      echo "=== $full_name ==="
      if [ "$meta_rc" -eq 0 ]; then
        echo "$meta"
      else
        echo "ERROR (rc=$meta_rc): $meta"
        param_errors=$((param_errors + 1))
      fi
    } >> "$raw_file"
  done

  pointer_name="/fjcloud/${env}/aws_ami_id"
  pointer_value="$(aws ssm get-parameter --region "$SSM_AMI_POINTER_REGION" --name "$pointer_name" --query 'Parameter.Value' --output text 2>&1)"
  pointer_rc=$?
  {
    echo "=== $pointer_name ==="
    if [ "$pointer_rc" -eq 0 ]; then
      echo "aws_ami_id=$pointer_value"
    else
      echo "ERROR (rc=$pointer_rc): $pointer_value"
      param_errors=$((param_errors + 1))
    fi
  } >> "$raw_file"

  pointer_outcome="failed"
  if [ "$pointer_rc" -eq 0 ]; then
    if [ -n "$pointer_value" ] && [ "$pointer_value" != "None" ]; then
      pointer_outcome="ok"
    else
      pointer_outcome="missing"
    fi
  elif [[ "$pointer_value" == *"ParameterNotFound"* ]]; then
    pointer_outcome="missing"
  fi
  pointer_owner_value=""
  if [ "$pointer_outcome" = "ok" ]; then
    pointer_owner_value="$pointer_value"
  fi
  case "$env" in
    staging)
      SSM_STAGING_AWS_AMI_POINTER_OUTCOME="$pointer_outcome"
      SSM_STAGING_AWS_AMI_POINTER_VALUE="$pointer_owner_value"
      ;;
    prod)
      SSM_PROD_AWS_AMI_POINTER_OUTCOME="$pointer_outcome"
      SSM_PROD_AWS_AMI_POINTER_VALUE="$pointer_owner_value"
      ;;
  esac

  total_checks=$((param_count + 1))
  if [ "$param_errors" -eq 0 ]; then
    add_row "$vendor_id" "OK" "false" "all $total_checks SSM checks readable (metadata + aws_ami_id pointer)" "aws_ssm_${env}.txt"
  else
    add_row "$vendor_id" "DRIFT" "false" "$param_errors of $total_checks SSM checks failed (missing, unauthorized, or pointer unreadable)" "aws_ssm_${env}.txt"
  fi
done

# ---------------------------------------------------------------------------
# 5. Cloudflare DNS — check key hosts resolve
# ---------------------------------------------------------------------------

raw_file="$OUT/cloudflare_dns.txt"
register_raw "cloudflare_dns.txt"
: > "$raw_file"

dns_hosts=(
  "api.flapjack.foo"
  "api.staging.flapjack.foo"
  "cloud.flapjack.foo"
  "cloud.staging.flapjack.foo"
)
dns_errors=0
for host in "${dns_hosts[@]}"; do
  result="$(dig +short A "$host" @1.1.1.1 2>&1)"
  {
    echo "=== $host ==="
    echo "$result"
  } >> "$raw_file"
  if [ -z "$result" ]; then
    dns_errors=$((dns_errors + 1))
  fi
done
if [ "$dns_errors" -eq 0 ]; then
  add_row "cloudflare_dns" "OK" "false" "all 4 hosts resolve" "cloudflare_dns.txt"
else
  add_row "cloudflare_dns" "DRIFT" "false" "$dns_errors of 4 hosts failed to resolve" "cloudflare_dns.txt"
fi

# ---------------------------------------------------------------------------
# 6. Cloudflare Pages — list env vars + deployment provenance (no values)
# ---------------------------------------------------------------------------
# Uses the global-key + email auth that fjcloud's .env.secret carries
# (CLOUDFLARE_GLOBAL_API_KEY + CLOUDFLARE_EMAIL). If absent → SKIP_NO_CREDS.

raw_file="$OUT/cloudflare_pages.txt"
register_raw "cloudflare_pages.txt"
: > "$raw_file"

if [ -z "${CLOUDFLARE_GLOBAL_API_KEY:-}" ] || [ -z "${CLOUDFLARE_EMAIL:-}" ]; then
  echo "SKIP_NO_CREDS: CLOUDFLARE_GLOBAL_API_KEY and/or CLOUDFLARE_EMAIL missing" > "$raw_file"
  add_row "cloudflare_pages" "SKIP_NO_CREDS" "false" "Cloudflare credentials missing in .env.secret" "cloudflare_pages.txt"
else
  cloudflare_cfg="$(create_secure_curl_config_file)" || cloudflare_cfg=""
  if [ -z "$cloudflare_cfg" ]; then
    echo "PROBE_ERROR: failed to create Cloudflare curl config" > "$raw_file"
    add_row "cloudflare_pages" "PROBE_ERROR" "false" "failed to create secure Cloudflare auth config" "cloudflare_pages.txt"
  else
    append_curl_header_config "$cloudflare_cfg" "X-Auth-Email: $CLOUDFLARE_EMAIL"
    append_curl_header_config "$cloudflare_cfg" "X-Auth-Key: $CLOUDFLARE_GLOBAL_API_KEY"
  # Step 1: resolve account ID via list-accounts.
    acct_http="$(curl -s -K "$cloudflare_cfg" -o "$OUT/cf_accounts.json" -w '%{http_code}' \
      https://api.cloudflare.com/client/v4/accounts)"
  register_raw "cf_accounts.json"

  # Capture the FIRST account id (Cloudflare returns paginated; we want one).
  acct_id=""
  if [ "$acct_http" = "200" ] && command -v python3 >/dev/null; then
    acct_id="$(python3 -c '
import json
d = json.load(open("'"$OUT/cf_accounts.json"'"))
ids = [a["id"] for a in d.get("result", [])]
print(ids[0] if ids else "")
' 2>/dev/null || true)"
  fi

  {
    echo "list_accounts_http_status=$acct_http"
    echo "account_id_resolved=${acct_id:-NONE}"
  } > "$raw_file"

  if [ -z "$acct_id" ]; then
    add_row "cloudflare_pages" "PROBE_ERROR" "false" "Cloudflare list-accounts returned HTTP $acct_http or yielded no account_id" "cloudflare_pages.txt"
  else
    # Step 2: list Pages projects under this account.
    proj_http="$(curl -s -K "$cloudflare_cfg" -o "$OUT/cf_pages_projects.json" -w '%{http_code}' \
      "https://api.cloudflare.com/client/v4/accounts/${acct_id}/pages/projects")"
    redact_cloudflare_pages_env_values "$OUT/cf_pages_projects.json"
    register_raw "cf_pages_projects.json"

    if [ "$proj_http" = "200" ] && command -v python3 >/dev/null; then
      # The projects list endpoint does not consistently expose deployment
      # provenance fields. Fetch each project detail and emit the canonical
      # provenance tuple from latest_deployment in the same cloudflare_pages
      # section output.
      project_names="$(python3 -c '
import json
d = json.load(open("'"$OUT/cf_pages_projects.json"'"))
for project in d.get("result", []):
    name = project.get("name")
    if isinstance(name, str) and name:
        print(name)
' 2>/dev/null || true)"

      project_count=0
      detail_errors=0
      missing_provenance_count=0
      for project_name in $project_names; do
        project_count=$((project_count + 1))
        safe_project_name="$(printf '%s' "$project_name" | sed 's/[^A-Za-z0-9_]/_/g')"
        detail_json="$OUT/cf_pages_project_${safe_project_name}.json"
        detail_raw_name="cf_pages_project_${safe_project_name}.json"
        detail_http="$(curl -s -K "$cloudflare_cfg" -o "$detail_json" -w '%{http_code}' \
          "https://api.cloudflare.com/client/v4/accounts/${acct_id}/pages/projects/${project_name}")"
        redact_cloudflare_pages_env_values "$detail_json"
        register_raw "$detail_raw_name"

        {
          echo "- project=${project_name} detail_http_status=${detail_http}"
        } >> "$raw_file"

        if [ "$detail_http" != "200" ]; then
          detail_errors=$((detail_errors + 1))
          continue
        fi

        detail_lines="$(python3 -c '
import json, sys
detail_path = sys.argv[1]
project_name = sys.argv[2]
data = json.load(open(detail_path))
result = data.get("result", {})
latest = result.get("latest_deployment") or {}
branch = (((latest.get("deployment_trigger") or {}).get("metadata") or {}).get("branch") or latest.get("production_branch") or "")
deployment_id = latest.get("id") or ""
created_on = latest.get("created_on") or ""
deployment_url = latest.get("url") or ""
deployment_status = ((latest.get("latest_stage") or {}).get("status")) or ""
missing = []
if not branch:
    missing.append("branch")
if not deployment_id:
    missing.append("deployment_id")
if not created_on:
    missing.append("created_on")
if not deployment_url:
    missing.append("url")
if not deployment_status:
    missing.append("status")
print("  deployment_branch={}".format(branch if branch else "NONE"))
print("  deployment_id={}".format(deployment_id if deployment_id else "NONE"))
print("  deployment_created_on={}".format(created_on if created_on else "NONE"))
print("  deployment_url={}".format(deployment_url if deployment_url else "NONE"))
print("  deployment_status={}".format(deployment_status if deployment_status else "NONE"))
print("  missing_fields=" + (",".join(missing) if missing else "none"))
envs = result.get("deployment_configs", {})
for env in ("production", "preview"):
    vars_obj = (envs.get(env, {}) or {}).get("env_vars") or {}
    names = sorted(vars_obj.keys()) if isinstance(vars_obj, dict) else []
    print(f"  env={env} var_count={len(names)} names={names}")
' "$detail_json" "$project_name" 2>/dev/null || true)"
        if [ -z "$detail_lines" ]; then
          detail_errors=$((detail_errors + 1))
          continue
        fi
        printf '%s\n' "$detail_lines" >> "$raw_file"
        if ! printf '%s\n' "$detail_lines" | grep -q 'missing_fields=none'; then
          missing_provenance_count=$((missing_provenance_count + 1))
        fi
      done

      if [ "$detail_errors" -gt 0 ]; then
        add_row "cloudflare_pages" "PROBE_ERROR" "false" "Cloudflare Pages detail fetch failed for $detail_errors of $project_count projects" "cloudflare_pages.txt"
      elif [ "$project_count" -eq 0 ]; then
        add_row "cloudflare_pages" "DRIFT" "false" "Cloudflare Pages projects list returned zero projects" "cloudflare_pages.txt"
      elif [ "$missing_provenance_count" -gt 0 ]; then
        add_row "cloudflare_pages" "DRIFT" "false" "Cloudflare Pages missing provenance fields for $missing_provenance_count of $project_count projects" "cloudflare_pages.txt"
      else
        add_row "cloudflare_pages" "OK" "false" "Cloudflare Pages deployment provenance + env-var names enumerated (values NOT captured)" "cloudflare_pages.txt"
      fi
    else
      add_row "cloudflare_pages" "PROBE_ERROR" "false" "Pages projects list returned HTTP $proj_http" "cloudflare_pages.txt"
    fi
  fi
  rm -f "$cloudflare_cfg"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Staging API + prod API health
# ---------------------------------------------------------------------------

raw_file="$OUT/api_health.txt"
register_raw "api_health.txt"
: > "$raw_file"

# Use `|` as separator (URLs contain `:`, so `${pair##*:}` would mangle them).
api_hosts=(
  "staging|https://api.staging.flapjack.foo/health"
  "prod|https://api.flapjack.foo/health"
)
api_errors=0
for pair in "${api_hosts[@]}"; do
  env="${pair%%|*}"
  url="${pair##*|}"
  body_file="$OUT/api_health_${env}.body"
  register_raw "api_health_${env}.body"
  http_status="$(curl -s -o "$body_file" -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true)"
  [ -n "$http_status" ] || http_status="000"
  {
    echo "=== $env $url ==="
    echo "http_status=$http_status"
    if [ -f "$body_file" ]; then
      echo "body_bytes=$(wc -c < "$body_file" | tr -d ' ')"
    fi
  } >> "$raw_file"
  if [ "$http_status" != "200" ]; then
    api_errors=$((api_errors + 1))
  fi
done

if [ "$api_errors" -eq 0 ]; then
  add_row "api_health" "OK" "false" "both staging + prod /health return 200" "api_health.txt"
else
  add_row "api_health" "ACTION_REQUIRED" "false" "$api_errors of 2 /health endpoints not 200" "api_health.txt"
fi

# ---------------------------------------------------------------------------
# 7b. Managed EC2 fleet + data-plane
# ---------------------------------------------------------------------------

fleet_dataplane_probe_valid_classification() {
  local output="$1" rc="$2"
  local token_line status
  case "$output" in
    *$'\n'*)
      return 1
      ;;
  esac
  token_line="$output"
  if [ -z "$token_line" ]; then
    return 1
  fi
  if ! printf '%s\n' "$token_line" | grep -Eq '^FLEET_STATUS: (OK|DRIFT|STALE|ACTION_REQUIRED|PROBE_ERROR) reason=[a-z0-9_]+$'; then
    return 1
  fi
  status="$(printf '%s\n' "$token_line" | sed -n 's/^FLEET_STATUS: \([A-Z_]*\) reason=[a-z0-9_]*$/\1/p')"
  case "$status:$rc" in
    OK:0|DRIFT:1|STALE:1|ACTION_REQUIRED:1|PROBE_ERROR:1)
      printf '%s\n' "$token_line"
      ;;
    *)
      return 1
      ;;
  esac
}

fleet_dataplane_read_classifier_stdout() {
  local stdout_path="$1"
  read_single_utf8_classifier_line "$stdout_path"
}

read_single_utf8_classifier_line() {
  local stdout_path="$1"
  python3 - "$stdout_path" <<'PY'
import sys
from pathlib import Path

try:
    data = Path(sys.argv[1]).read_bytes()
except OSError:
    raise SystemExit(1)

if data.endswith(b"\n"):
    data = data[:-1]

if not data or b"\n" in data:
    raise SystemExit(1)

try:
    sys.stdout.write(data.decode("utf-8"))
except UnicodeDecodeError:
    raise SystemExit(1)
PY
}

fleet_dataplane_probe_row_status() {
  local output="$1" rc="$2" token_line
  if ! token_line="$(fleet_dataplane_probe_valid_classification "$output" "$rc")"; then
    printf 'PROBE_ERROR\n'
    return
  fi
  printf '%s\n' "$token_line" | sed -n 's/^FLEET_STATUS: \([A-Z_]*\) reason=[a-z0-9_]*$/\1/p'
}

fleet_dataplane_probe_reason() {
  local output="$1" rc="$2" token_line
  if ! token_line="$(fleet_dataplane_probe_valid_classification "$output" "$rc")"; then
    printf 'classifier_output_invalid\n'
    return
  fi
  printf '%s\n' "$token_line" | sed -n 's/^FLEET_STATUS: [A-Z_]* reason=\([a-z0-9_]*\)$/\1/p'
}

fleet_dataplane_write_missing_credentials_evidence() {
  local evidence_path="$1" observed_at_epoch="$2"
  python3 - "$evidence_path" "$observed_at_epoch" <<'PY'
import json
import sys

path, observed_at_epoch = sys.argv[1], int(sys.argv[2])
with open(path, "w", encoding="utf-8") as fh:
    json.dump(
        {
            "schema_version": 1,
            "observed_at_epoch": observed_at_epoch,
            "credential_state": "missing",
            "environments": [],
            "regions": [],
        },
        fh,
        indent=2,
        sort_keys=True,
    )
    fh.write("\n")
PY
}

fleet_dataplane_collect_evidence() {
  local evidence_path="$1" observed_at_epoch="$2" reused_ami_pointers="$3"
  python3 - "$evidence_path" "$observed_at_epoch" "$reused_ami_pointers" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from urllib.parse import urlparse

EVIDENCE_PATH = sys.argv[1]
OBSERVED_AT = int(sys.argv[2])
REUSED_AMI_POINTERS = json.loads(sys.argv[3])


def canonical_api_url_for_env(env_name):
    generic = os.environ.get("API_URL") or ""
    if not generic:
        return ""
    host = urlparse(generic).hostname or ""
    if env_name == "staging" and "staging" in host:
        return generic
    if env_name == "prod" and "staging" not in host:
        return generic
    return ""


def env_config(env_name, default_url):
    upper = env_name.upper()
    canonical_api_url = canonical_api_url_for_env(env_name)
    fleet_api_url = os.environ.get(f"FLEET_{upper}_API_URL") or ""
    env_api_url = os.environ.get(f"{upper}_API_URL") or ""
    base_url = fleet_api_url or env_api_url or canonical_api_url or default_url
    base_url_from_canonical_api_url = bool(canonical_api_url and not fleet_api_url and not env_api_url)
    admin_key = (
        os.environ.get(f"FLEET_{upper}_ADMIN_KEY")
        or os.environ.get(f"{upper}_ADMIN_KEY")
        or (os.environ.get("ADMIN_KEY") if base_url_from_canonical_api_url else "")
        or ""
    )
    return env_name, base_url, admin_key


ENVIRONMENTS = [
    env_config("staging", "https://api.staging.flapjack.foo"),
    env_config("prod", "https://api.flapjack.foo"),
]


def run_command(args, timeout=15):
    try:
        proc = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return 124, "", ""
    return proc.returncode, proc.stdout, proc.stderr


def write_curl_config(headers):
    cfg = tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False)
    try:
        os.chmod(cfg.name, 0o600)
        for header in headers:
            cfg.write('header = "{}"\n'.format(header.replace("\\", "\\\\").replace('"', '\\"')))
        return cfg.name
    finally:
        cfg.close()


def curl_json(url, headers=None, method="GET", payload=None):
    headers = headers or []
    with tempfile.TemporaryDirectory() as tmp:
        body_path = os.path.join(tmp, "body.json")
        args = ["curl", "-sS", "-o", body_path, "-w", "%{http_code}", "--max-time", "10"]
        cfg_path = ""
        data_path = ""
        if headers:
            cfg_path = write_curl_config(headers)
            args.extend(["-K", cfg_path])
        if method != "GET":
            args.extend(["--request", method])
        if payload is not None:
            data_path = os.path.join(tmp, "request.json")
            with open(data_path, "w", encoding="utf-8") as fh:
                json.dump(payload, fh, separators=(",", ":"))
            args.extend(["--data", f"@{data_path}"])
            if not any(header.lower().startswith("content-type:") for header in headers):
                args.extend(["-H", "Content-Type: application/json"])
        args.append(url)
        rc, stdout, _ = run_command(args)
        if cfg_path:
            try:
                os.unlink(cfg_path)
            except OSError:
                pass
        if rc != 0 or not stdout.strip().isdigit():
            return "failed", None, None
        status = int(stdout.strip()[-3:])
        try:
            with open(body_path, "r", encoding="utf-8") as fh:
                body = json.load(fh)
        except (OSError, json.JSONDecodeError):
            body = None
        return ("ok" if status == 200 and body is not None else "failed"), status, body


def aws_json(args):
    rc, stdout, _ = run_command(args)
    if rc != 0:
        return "failed", None
    try:
        return "ok", json.loads(stdout or "{}")
    except json.JSONDecodeError:
        return "failed", None


def aws_text(args):
    rc, stdout, stderr = run_command(args)
    if rc != 0:
        if "ParameterNotFound" in stdout or "ParameterNotFound" in stderr:
            return "missing", None
        return "failed", None
    value = stdout.strip()
    if not value or value == "None":
        return "missing", None
    return "ok", value


def public_regions(body):
    rows = body.get("regions") if isinstance(body, dict) else None
    if not isinstance(rows, list):
        return []
    regions = []
    for row in rows:
        if not isinstance(row, dict) or row.get("provider") != "aws":
            continue
        logical_id = row.get("region") or row.get("id") or row.get("display_name")
        aws_region = row.get("provider_location")
        if isinstance(logical_id, str) and logical_id and isinstance(aws_region, str) and aws_region:
            regions.append({"id": logical_id, "aws_region": aws_region})
    return regions


def find_demo_customer_id(body):
    rows = body if isinstance(body, list) else body.get("tenants") if isinstance(body, dict) else None
    if not isinstance(rows, list):
        return None
    for row in rows:
        if not isinstance(row, dict) or row.get("status") != "active":
            continue
        if row.get("name") == "demo-shared-free" or row.get("email") == "demo-shared-free@synthetic-seed.invalid":
            customer_id = row.get("id")
            return customer_id if isinstance(customer_id, str) and customer_id else None
    return None


def object_count(body):
    hits = body.get("hits") if isinstance(body, dict) else None
    if not isinstance(hits, list):
        return 0
    return sum(1 for hit in hits if isinstance(hit, dict) and hit.get("objectID") == "doc-0")


def collect_data_plane(base_url, admin_key):
    if not base_url or not admin_key:
        return {"identity_outcome": "missing", "request_outcome": "indeterminate", "http_status": None, "matching_object_count": None}
    headers = [f"x-admin-key: {admin_key}"]
    outcome, status, tenants = curl_json(f"{base_url.rstrip('/')}/admin/tenants", headers=headers)
    customer_id = find_demo_customer_id(tenants) if outcome == "ok" else None
    if not customer_id:
        return {"identity_outcome": "missing" if outcome == "ok" else "failed", "request_outcome": "indeterminate", "http_status": status, "matching_object_count": None}
    token_payload = {"customer_id": customer_id, "expires_in_secs": 60, "purpose": "admin"}
    outcome, status, token_body = curl_json(f"{base_url.rstrip('/')}/admin/tokens", headers=headers, method="POST", payload=token_payload)
    token = token_body.get("token") if isinstance(token_body, dict) else None
    if outcome != "ok" or not isinstance(token, str) or not token:
        return {"identity_outcome": "ok", "request_outcome": "failed", "http_status": status, "matching_object_count": None}
    browse_headers = [f"Authorization: Bearer {token}"]
    browse_payload = {"attributesToRetrieve": ["objectID"], "hitsPerPage": 100}
    outcome, status, browse_body = curl_json(f"{base_url.rstrip('/')}/indexes/demo-shared-free/browse", headers=browse_headers, method="POST", payload=browse_payload)
    count = object_count(browse_body) if outcome == "ok" else None
    return {"identity_outcome": "ok", "request_outcome": "ok" if outcome == "ok" else "failed", "http_status": status, "matching_object_count": count}


def collect_pointer(env_name, aws_region, pointer_name):
    outcome, value = aws_text([
        "aws", "ssm", "get-parameter",
        "--region", aws_region,
        "--name", f"/fjcloud/{env_name}/{pointer_name}",
        "--query", "Parameter.Value",
        "--output", "text",
    ])
    return {"outcome": outcome, "value": value}


def collect_ami_pointer(env_name, aws_region):
    reused = REUSED_AMI_POINTERS.get(env_name, {}).get(aws_region)
    if isinstance(reused, dict):
        if reused.get("outcome") == "missing":
            return {"outcome": "missing", "value": None}
        if reused.get("outcome") == "ok" and isinstance(reused.get("value"), str):
            return {"outcome": "ok", "value": reused["value"]}
    return collect_pointer(env_name, aws_region, "aws_ami_id")


def normalize_epoch(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return int(parsed.astimezone(timezone.utc).timestamp())
        except ValueError:
            return None
    return None


def collect_region(aws_region):
    instances = []
    ec2_outcome = "ok"
    next_token = ""
    while True:
        args = [
            "aws", "ec2", "describe-instances",
            "--region", aws_region,
            "--filters", "Name=tag:managed-by,Values=fjcloud",
            "--output", "json",
            "--max-items", "1000",
        ]
        if next_token:
            args.extend(["--starting-token", next_token])
        outcome, body = aws_json(args)
        if outcome != "ok":
            ec2_outcome = "failed"
            instances = []
            break
        for reservation in body.get("Reservations", []):
            for instance in reservation.get("Instances", []):
                tags = {tag.get("Key"): tag.get("Value") for tag in instance.get("Tags", []) if isinstance(tag, dict)}
                instances.append({
                    "instance_id": instance.get("InstanceId"),
                    "state": (instance.get("State") or {}).get("Name"),
                    "image_id": instance.get("ImageId"),
                    "subnet_id": instance.get("SubnetId"),
                    "tags": {
                        "Name": tags.get("Name"),
                        "customer_id": tags.get("customer_id"),
                        "node_id": tags.get("node_id"),
                        "managed-by": tags.get("managed-by"),
                    },
                })
        next_token = body.get("NextToken") or ""
        if not next_token:
            break

    ssm_outcome, ssm_body = aws_json([
        "aws", "ssm", "describe-instance-information",
        "--region", aws_region,
        "--output", "json",
    ])
    ssm_instances = []
    if ssm_outcome == "ok":
        for row in ssm_body.get("InstanceInformationList", []):
            ssm_instances.append({
                "instance_id": row.get("InstanceId"),
                "ping_status": row.get("PingStatus"),
                "last_ping_epoch": normalize_epoch(row.get("LastPingDateTime")),
            })

    return {
        "aws_region": aws_region,
        "ec2": {"outcome": ec2_outcome, "instances": instances},
        "ssm": {"outcome": ssm_outcome, "instances": ssm_instances},
    }


def collect():
    environments = []
    regions_to_read = []
    for env_name, base_url, admin_key in ENVIRONMENTS:
        outcome, _, body = curl_json(f"{base_url.rstrip('/')}/public/infrastructure")
        aws_regions = public_regions(body) if outcome == "ok" else []
        discovery_outcome = "ok" if aws_regions else "missing"
        if outcome != "ok":
            discovery_outcome = "failed"
        for row in aws_regions:
            if row["aws_region"] not in regions_to_read:
                regions_to_read.append(row["aws_region"])
        pointers = []
        for row in aws_regions:
            aws_region = row["aws_region"]
            pointers.append({
                "aws_region": aws_region,
                "subnet": collect_pointer(env_name, aws_region, "aws_subnet_id"),
                "ami": collect_ami_pointer(env_name, aws_region),
            })
        environments.append({
            "name": env_name,
            "region_discovery": {"outcome": discovery_outcome, "aws_regions": aws_regions},
            "pointers": pointers,
            "data_plane": collect_data_plane(base_url, admin_key),
        })
    return {
        "schema_version": 1,
        "observed_at_epoch": OBSERVED_AT,
        "credential_state": "available",
        "environments": environments,
        "regions": [collect_region(region) for region in regions_to_read],
    }


with open(EVIDENCE_PATH, "w", encoding="utf-8") as fh:
    json.dump(collect(), fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

raw_file="$OUT/fleet_dataplane.json"
register_raw "fleet_dataplane.json"
observed_at_epoch="$(date -u +%s)"
fleet_reused_ami_pointers="$(python3 - \
  "$SSM_AMI_POINTER_REGION" \
  "$SSM_STAGING_AWS_AMI_POINTER_OUTCOME" \
  "$SSM_STAGING_AWS_AMI_POINTER_VALUE" \
  "$SSM_PROD_AWS_AMI_POINTER_OUTCOME" \
  "$SSM_PROD_AWS_AMI_POINTER_VALUE" <<'PY'
import json
import sys

region = sys.argv[1]
raw = {
    "staging": {"outcome": sys.argv[2], "value": sys.argv[3]},
    "prod": {"outcome": sys.argv[4], "value": sys.argv[5]},
}
result = {}
for env_name, pointer in raw.items():
    if not region:
        continue
    if pointer["outcome"] == "ok" and pointer["value"]:
        result[env_name] = {region: {"outcome": "ok", "value": pointer["value"]}}
    elif pointer["outcome"] == "missing":
        result[env_name] = {region: {"outcome": "missing", "value": None}}
print(json.dumps(result, separators=(",", ":")))
PY
)"

if [ "$AWS_OK" -eq 0 ]; then
  fleet_dataplane_write_missing_credentials_evidence "$raw_file" "$observed_at_epoch"
else
  if ! fleet_dataplane_collect_evidence "$raw_file" "$observed_at_epoch" "$fleet_reused_ami_pointers"; then
    printf '{}\n' > "$raw_file"
  fi
fi

fleet_probe="${FLEET_DATAPLANE_PROBE:-scripts/probe_fleet_dataplane.sh}"
fleet_output=""
fleet_rc=0
if [ ! -x "$fleet_probe" ]; then
  fleet_output="FLEET_STATUS: PROBE_ERROR reason=classifier_output_invalid"
  fleet_rc=1
else
  fleet_stdout_file="$(mktemp)"
  if [ -z "$fleet_stdout_file" ]; then
    fleet_output=""
    fleet_rc=1
  else
    "$fleet_probe" --evidence "$raw_file" > "$fleet_stdout_file" 2>/dev/null
    fleet_rc=$?
    if ! fleet_output="$(fleet_dataplane_read_classifier_stdout "$fleet_stdout_file")"; then
      fleet_output=""
    fi
    rm -f "$fleet_stdout_file"
  fi
fi
fleet_status="$(fleet_dataplane_probe_row_status "$fleet_output" "$fleet_rc")"
fleet_reason="$(fleet_dataplane_probe_reason "$fleet_output" "$fleet_rc")"
add_row "fleet_dataplane" "$fleet_status" "false" "fleet/data-plane classifier reason=${fleet_reason:-classifier_output_invalid}" "fleet_dataplane.json"

# ---------------------------------------------------------------------------
# 7c. Flapjack engine build identity (staging + prod)
# ---------------------------------------------------------------------------
# Inspects the INSTALLED engine bytes plus the runtime /health identity via the
# canonical build-identity probe, then classifies through the Stage 1 identity
# owners. Expected build comparison data comes ONLY from the Stage 1
# manifest/env identity contract (the FJCLOUD_FLAPJACK_* variables the probe
# reads); this section never treats Packer custom data, S3 ETags/object
# versions, or AMI tags as the deployment oracle.

raw_file="$OUT/flapjack_build_identity.txt"
register_raw "flapjack_build_identity.txt"
: > "$raw_file"

flapjack_probe="${FLAPJACK_BUILD_IDENTITY_PROBE:-scripts/probe_flapjack_build_identity.sh}"

# Single source of truth translating a probe classification+reason into the
# live-state row vocabulary. This is the only place the mapping happens.
flapjack_build_identity_row_status() {
  local classification="$1" reason="$2"
  case "$classification" in
    pass) printf 'OK\n' ;;
    real_defect) printf 'ACTION_REQUIRED\n' ;;
    setup_infra)
      # Missing access/creds/host → SKIP_NO_CREDS; any other broken prerequisite
      # we could otherwise reach → PROBE_ERROR.
      case "$reason" in
        ssm_unreachable|missing_ssm_exec|missing_local_binary|missing_expected_identity)
          printf 'SKIP_NO_CREDS\n' ;;
        *) printf 'PROBE_ERROR\n' ;;
      esac ;;
    *) printf 'PROBE_ERROR\n' ;;
  esac
}

flapjack_build_identity_status_rank() {
  case "$1" in
    OK) printf '0\n' ;;
    SKIP_NO_CREDS) printf '1\n' ;;
    PROBE_ERROR) printf '2\n' ;;
    ACTION_REQUIRED) printf '3\n' ;;
    *) printf '2\n' ;;
  esac
}

if [ ! -x "$flapjack_probe" ]; then
  echo "SKIP_NO_CREDS: $flapjack_probe missing or not executable" >> "$raw_file"
  add_row "flapjack_build_identity" "SKIP_NO_CREDS" "false" "build-identity probe unavailable" "flapjack_build_identity.txt"
else
  flapjack_worst_status="OK"
  for fj_env in staging prod; do
    echo "=== $fj_env ===" >> "$raw_file"
    fj_probe_json="$("$flapjack_probe" --env "$fj_env" 2>>"$raw_file")"
    printf '%s\n' "$fj_probe_json" >> "$raw_file"
    fj_fields="$(printf '%s' "$fj_probe_json" | python3 -c '
import json, sys
lines = [l for l in sys.stdin.read().splitlines() if l.strip()]
try:
    obj = json.loads(lines[-1]) if lines else {}
except (json.JSONDecodeError, IndexError):
    obj = {}
print(obj.get("classification", "investigate"), obj.get("reason", ""))')"
    fj_classification="${fj_fields%% *}"
    fj_reason="${fj_fields#* }"
    fj_status="$(flapjack_build_identity_row_status "$fj_classification" "$fj_reason")"
    echo "(classification=$fj_classification reason=$fj_reason status=$fj_status)" >> "$raw_file"
    if [ "$(flapjack_build_identity_status_rank "$fj_status")" -gt "$(flapjack_build_identity_status_rank "$flapjack_worst_status")" ]; then
      flapjack_worst_status="$fj_status"
    fi
  done
  add_row "flapjack_build_identity" "$flapjack_worst_status" "false" "installed-byte + runtime engine identity (staging+prod) — see raw" "flapjack_build_identity.txt"
fi

# ---------------------------------------------------------------------------
# 7d. Usage-rollup freshness (staging + prod)
# ---------------------------------------------------------------------------

usage_rollup_freshness_valid_classification() {
  local output="$1" rc="$2"
  case "$output:$rc" in
    "USAGE_ROLLUP_FRESHNESS_STATUS: OK reason=fresh_rollups_present:0" \
    |"USAGE_ROLLUP_FRESHNESS_STATUS: ACTION_REQUIRED reason=no_rollups:1" \
    |"USAGE_ROLLUP_FRESHNESS_STATUS: ACTION_REQUIRED reason=rollups_stale:1" \
    |"USAGE_ROLLUP_FRESHNESS_STATUS: PROBE_ERROR reason=query_failed:1" \
    |"USAGE_ROLLUP_FRESHNESS_STATUS: PROBE_ERROR reason=malformed_evidence:1")
      printf '%s\n' "$output"
      ;;
    *)
      return 1
      ;;
  esac
}

usage_rollup_freshness_row_status() {
  local output="$1" rc="$2" token_line
  if ! token_line="$(usage_rollup_freshness_valid_classification "$output" "$rc")"; then
    printf 'PROBE_ERROR\n'
    return
  fi
  printf '%s\n' "$token_line" \
    | sed -n 's/^USAGE_ROLLUP_FRESHNESS_STATUS: \([A-Z_]*\) reason=[a-z0-9_]*$/\1/p'
}

usage_rollup_freshness_reason() {
  local output="$1" rc="$2" token_line
  if ! token_line="$(usage_rollup_freshness_valid_classification "$output" "$rc")"; then
    printf 'classifier_output_invalid\n'
    return
  fi
  printf '%s\n' "$token_line" \
    | sed -n 's/^USAGE_ROLLUP_FRESHNESS_STATUS: [A-Z_]* reason=\([a-z0-9_]*\)$/\1/p'
}

usage_rollup_write_failed_evidence() {
  local evidence_path="$1"
  printf '%s\n' '{"schema_version":1,"query_outcome":"failed"}' > "$evidence_path"
}

usage_rollup_normalize_sql_output() {
  local sql_output_path="$1" evidence_path="$2"
  python3 - "$sql_output_path" "$evidence_path" <<'PY'
import json
import sys
from pathlib import Path

source_path, destination_path = map(Path, sys.argv[1:])
try:
    document = json.loads(source_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(document, dict):
    raise SystemExit(1)
destination_path.write_text(
    json.dumps(document, separators=(",", ":"), sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

usage_rollup_classify_evidence() {
  local evidence_path="$1" probe="$2"
  local stdout_file output rc
  if [ ! -x "$probe" ]; then
    printf '%s|%s\n' "" "1"
    return
  fi

  stdout_file="$(mktemp)" || {
    printf '%s|%s\n' "" "1"
    return
  }
  "$probe" --evidence "$evidence_path" > "$stdout_file" 2>/dev/null
  rc=$?
  if ! output="$(read_single_utf8_classifier_line "$stdout_file")"; then
    output=""
  fi
  rm -f "$stdout_file"
  printf '%s|%s\n' "$output" "$rc"
}

# Source the private-RDS execution owner directly. Metering checks set shell
# options at load time, so obtain their canonical SQL in an isolated subshell.
# shellcheck source=lib/staging_db.sh
source "$PROBE_SCRIPT_DIR/lib/staging_db.sh"
usage_rollup_sql="$(
  (
    # shellcheck source=lib/metering_checks.sh
    source "$PROBE_SCRIPT_DIR/lib/metering_checks.sh"
    metering_rollup_freshness_evidence_sql
  )
)" || usage_rollup_sql=""
usage_rollup_probe="${USAGE_ROLLUP_FRESHNESS_PROBE:-$PROBE_SCRIPT_DIR/probe_usage_rollup_freshness.sh}"

for env in staging prod; do
  usage_rollup_raw_name="usage_rollup_freshness_${env}.json"
  usage_rollup_raw="$OUT/$usage_rollup_raw_name"
  register_raw "$usage_rollup_raw_name"
  usage_rollup_param="/fjcloud/${env}/database_url"

  if [ "$AWS_OK" -eq 0 ]; then
    usage_rollup_write_failed_evidence "$usage_rollup_raw"
    add_row "usage_rollup_freshness_${env}" "SKIP_NO_CREDS" "false" \
      "usage-rollup freshness skipped because AWS credentials are unavailable" \
      "$usage_rollup_raw_name"
    continue
  fi

  usage_rollup_db_url="$(
    aws ssm get-parameter \
      --name "$usage_rollup_param" \
      --with-decryption \
      --query Parameter.Value \
      --output text \
      --region "${AWS_DEFAULT_REGION:-us-east-1}" 2>/dev/null
  )" || usage_rollup_db_url=""
  usage_rollup_query_output="$(mktemp)" || usage_rollup_query_output=""
  usage_rollup_query_ok=0
  if [ -n "$usage_rollup_db_url" ] \
    && [ "$usage_rollup_db_url" != "None" ] \
    && [ -n "$usage_rollup_sql" ] \
    && [ -n "$usage_rollup_query_output" ]; then
    if DATABASE_URL_SSM_PARAM="$usage_rollup_param" \
      staging_db_run_sql "$usage_rollup_db_url" "$usage_rollup_sql" \
      > "$usage_rollup_query_output" 2>/dev/null \
      && usage_rollup_normalize_sql_output "$usage_rollup_query_output" "$usage_rollup_raw" \
      2>/dev/null; then
      usage_rollup_query_ok=1
    fi
  fi
  if [ -n "$usage_rollup_query_output" ]; then
    rm -f "$usage_rollup_query_output"
  fi
  unset usage_rollup_db_url

  if [ "$usage_rollup_query_ok" -ne 1 ]; then
    usage_rollup_write_failed_evidence "$usage_rollup_raw"
  fi

  usage_rollup_classification="$(usage_rollup_classify_evidence "$usage_rollup_raw" "$usage_rollup_probe")"
  usage_rollup_rc="${usage_rollup_classification##*|}"
  usage_rollup_output="${usage_rollup_classification%|*}"
  usage_rollup_status="$(usage_rollup_freshness_row_status "$usage_rollup_output" "$usage_rollup_rc")"
  usage_rollup_reason="$(usage_rollup_freshness_reason "$usage_rollup_output" "$usage_rollup_rc")"
  add_row "usage_rollup_freshness_${env}" "$usage_rollup_status" "false" \
    "usage-rollup freshness classifier reason=${usage_rollup_reason}" \
    "$usage_rollup_raw_name"
done

# ---------------------------------------------------------------------------
# 8. Staging RDS — customer count + test-pattern emails
# ---------------------------------------------------------------------------
# Shells out to scripts/launch/ssm_exec_staging.sh (the existing SSM-exec
# pattern used by web/tests/fixtures/staging_db_lookup.ts).

raw_file="$OUT/staging_rds.txt"
register_raw "staging_rds.txt"
: > "$raw_file"

ssm_exec="scripts/launch/ssm_exec_staging.sh"
if [ "${LIVE_STATE_SKIP_STAGING_RDS:-0}" = "1" ]; then
  echo "SKIP_BY_ENV: LIVE_STATE_SKIP_STAGING_RDS=1" > "$raw_file"
  add_row "staging_rds" "SKIP_NO_CREDS" "false" "staging RDS probe skipped by LIVE_STATE_SKIP_STAGING_RDS=1" "staging_rds.txt"
elif [ ! -x "$ssm_exec" ]; then
  echo "SKIP_NO_CREDS: $ssm_exec missing or not executable" > "$raw_file"
  add_row "staging_rds" "SKIP_NO_CREDS" "false" "ssm_exec_staging.sh not available" "staging_rds.txt"
elif [ "$AWS_OK" -eq 0 ]; then
  echo "SKIP_NO_CREDS: AWS credentials missing (ssm_exec requires AWS access)" > "$raw_file"
  add_row "staging_rds" "SKIP_NO_CREDS" "false" "AWS credentials not resolvable" "staging_rds.txt"
else
  # ssm_exec_staging.sh receives a shell command (not raw SQL); it runs that
  # command on the staging API EC2 instance where DATABASE_URL is reachable.
  # Wrap each query in the canonical `source /etc/fjcloud/env && psql ... -tAc "..."`
  # pattern that `web/tests/fixtures/staging_db_lookup.ts::buildSsmStagingPsqlCommand`
  # uses — verified at probe-build time against the actual deployed env layout.
  #
  # macOS does not ship GNU `timeout`. Use bash background + sleep + kill so the
  # probe is portable across macOS + Linux CI environments.
  q1='source /etc/fjcloud/env && psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAc "SELECT COUNT(*) FROM customers WHERE status != '"'"'deleted'"'"'"'
  q2='source /etc/fjcloud/env && psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -tAc "SELECT COUNT(*) FROM customers WHERE (email LIKE '"'"'signup-paid-%@%'"'"' OR email LIKE '"'"'%-test@flapjack-test.example'"'"') AND status != '"'"'deleted'"'"'"'

  # Helper: run a shell command with a wall-clock timeout, capture all output.
  # Returns the command's exit code, or 124 on timeout.
  run_with_timeout() {
    local timeout_sec="$1"; shift
    local out
    out="$("$@" 2>&1 &
      bgpid=$!
      ( sleep "$timeout_sec" && kill -9 $bgpid 2>/dev/null ) &
      watcher=$!
      wait $bgpid 2>/dev/null
      rc=$?
      kill $watcher 2>/dev/null
      exit $rc
    )"
    local rc=$?
    printf '%s\n' "$out"
    return $rc
  }

  q1_out=""
  q2_out=""
  q1_rc=0
  q2_rc=0
  {
    echo "=== total customers (status != deleted) ==="
    q1_out="$(run_with_timeout 60 bash "$ssm_exec" "$q1")" || q1_rc=$?
    echo "$q1_out"
    echo "(q1 exit=$q1_rc)"
    echo ""
    echo "=== test-pattern customers ==="
    q2_out="$(run_with_timeout 60 bash "$ssm_exec" "$q2")" || q2_rc=$?
    echo "$q2_out"
    echo "(q2 exit=$q2_rc)"
  } > "$raw_file"

  # Only mark OK if both queries succeeded AND output contains digit (a count).
  if [ "$q1_rc" -eq 0 ] && [ "$q2_rc" -eq 0 ] && \
     echo "$q1_out" | grep -qE '[0-9]' && \
     echo "$q2_out" | grep -qE '[0-9]'; then
    add_row "staging_rds" "OK" "false" "staging RDS counts captured (see raw)" "staging_rds.txt"
  else
    add_row "staging_rds" "PROBE_ERROR" "false" "ssm_exec failed (q1_rc=$q1_rc, q2_rc=$q2_rc) — see raw" "staging_rds.txt"
  fi
fi

# ---------------------------------------------------------------------------
# 9. Privacy.com — list one card via API key
# ---------------------------------------------------------------------------

raw_file="$OUT/privacy_com.txt"
register_raw "privacy_com.txt"
if [ -z "${PRIVACY_PRODUCTION_API_KEY:-}" ]; then
  echo "SKIP_NO_CREDS: PRIVACY_PRODUCTION_API_KEY unset" > "$raw_file"
  add_row "privacy_com" "SKIP_NO_CREDS" "false" "Privacy.com API key not present" "privacy_com.txt"
else
  privacy_cfg="$(create_secure_curl_config_file)" || privacy_cfg=""
  if [ -n "$privacy_cfg" ]; then
    append_curl_header_config "$privacy_cfg" "Authorization: api-key $PRIVACY_PRODUCTION_API_KEY"
    http_status="$(curl -s -K "$privacy_cfg" -o /dev/null -w '%{http_code}' --max-time 10 \
      "https://api.privacy.com/v1/cards?page_size=1" 2>&1 || echo "000")"
    rm -f "$privacy_cfg"
  else
    http_status="000"
  fi
  {
    echo "endpoint=https://api.privacy.com/v1/cards?page_size=1"
    echo "http_status=$http_status"
    echo "(body NOT captured — Privacy.com responses contain cardholder PAN tails)"
  } > "$raw_file"
  if [ "$http_status" = "200" ]; then
    add_row "privacy_com" "OK" "false" "Privacy.com key authenticates" "privacy_com.txt"
  elif [ "$http_status" = "401" ]; then
    add_row "privacy_com" "ACTION_REQUIRED" "false" "Privacy.com key returned 401 — revoked?" "privacy_com.txt"
  else
    add_row "privacy_com" "PROBE_ERROR" "false" "Privacy.com returned HTTP $http_status" "privacy_com.txt"
  fi
fi

# ---------------------------------------------------------------------------
# 10. Footer
# ---------------------------------------------------------------------------

{
  echo "---"
  echo "Probe complete. Raw subfiles listed in manifest.txt."
  echo "Run: \`bash scripts/probe_live_state.sh\` again to refresh; new timestamp dir per run."
} >> "$SUMMARY"

echo "$OUTPUT_PATH"
exit 0
