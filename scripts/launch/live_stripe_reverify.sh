#!/usr/bin/env bash
# Orchestrate live Stripe re-verification from owner summary through refund/readback.
# shellcheck disable=SC1091
set -euo pipefail

LIVE_STRIPE_REVERIFY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIVE_STRIPE_REVERIFY_REPO_ROOT="$(cd "$LIVE_STRIPE_REVERIFY_SCRIPT_DIR/../.." && pwd)"

source "$LIVE_STRIPE_REVERIFY_REPO_ROOT/scripts/lib/stripe_request.sh"
source "$LIVE_STRIPE_REVERIFY_REPO_ROOT/scripts/lib/stripe_checks.sh"
source "$LIVE_STRIPE_REVERIFY_REPO_ROOT/scripts/lib/env.sh"
source "$LIVE_STRIPE_REVERIFY_REPO_ROOT/scripts/lib/identifier_redaction.sh"

DRY_RUN="false"
TARGET_ENV=""

STRIPE_API_BASE="https://api.stripe.com"
STRIPE_SECRET_KEY_EFFECTIVE=""

LIVE_STRIPE_REVERIFY_VERSION_URL="${LIVE_STRIPE_REVERIFY_VERSION_URL:-https://api.flapjack.foo/version}"
LIVE_STRIPE_REVERIFY_OWNER_SCRIPT="${LIVE_STRIPE_REVERIFY_OWNER_SCRIPT:-$LIVE_STRIPE_REVERIFY_SCRIPT_DIR/live_card_e2e_test.sh}"
LIVE_STRIPE_REVERIFY_EVIDENCE_ROOT="${LIVE_STRIPE_REVERIFY_EVIDENCE_ROOT:-$LIVE_STRIPE_REVERIFY_REPO_ROOT/docs/runbooks/evidence/launch-rc-runs}"

RUN_CLASSIFICATION="success"
PAYMENT_INTENT_ID=""
CHARGE_ID=""
REFUND_ID=""
OWNER_SUMMARY_JSON=""
VERSION_PREFLIGHT_JSON=""
VERSION_POSTFLIGHT_JSON=""
GREEN_BUNDLE_DIR=""

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --env=*)
                TARGET_ENV="${1#--env=}"
                if [ "$TARGET_ENV" != "prod" ]; then
                    echo "ERROR: unknown env value: $TARGET_ENV" >&2
                    exit 2
                fi
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            *)
                echo "ERROR: unknown argument: $1" >&2
                exit 2
                ;;
        esac
    done

    if [ -z "$TARGET_ENV" ]; then
        echo "ERROR: missing required argument: --env=prod" >&2
        exit 2
    fi
}

fail_with_classification() {
    local classification="$1"
    local message="$2"
    RUN_CLASSIFICATION="$classification"
    echo "classification=${classification}"
    echo "$message"
    echo "classification=${classification}" >&2
    echo "$message" >&2
    exit 1
}

capture_version_probe() {
    # Single owner of /version probe failure classification: transport
    # failures (curl exit non-zero) and payload-shape failures (missing
    # required fields / non-JSON body) are distinguished here rather than
    # across a subshell boundary, so the classification reaching
    # fail_with_classification is the real cause.
    local phase="$1"
    local version_response=""
    local curl_exit=0
    local parsed_payload=""
    local parse_exit=0

    version_response="$(curl -fsS "$LIVE_STRIPE_REVERIFY_VERSION_URL" 2>&1)" || curl_exit=$?
    if [ "$curl_exit" -ne 0 ]; then
        fail_with_classification "version_probe_request_failed" "${phase} /version probe failed: ${version_response}"
    fi

    parsed_payload="$(python3 - "$phase" "$version_response" <<'PY' 2>&1
import json
import sys

phase = sys.argv[1]
payload = json.loads(sys.argv[2])
required = ["dev_sha", "mirror_sha", "synced_at", "build_time"]
for key in required:
    value = payload.get(key)
    if value is None or str(value).strip() == "":
        raise SystemExit(f"{phase} /version payload missing field: {key}")
print(
    json.dumps(
        {key: str(payload[key]).strip() for key in required},
        separators=(",", ":"),
    )
)
PY
)" || parse_exit=$?

    if [ "$parse_exit" -ne 0 ]; then
        fail_with_classification "version_probe_shape_invalid" "$parsed_payload"
    fi

    if [ "$phase" = "preflight" ]; then
        VERSION_PREFLIGHT_JSON="$parsed_payload"
    else
        VERSION_POSTFLIGHT_JSON="$parsed_payload"
    fi
}

run_owner_and_extract_identifiers() {
    local stdout_file stderr_file owner_rc=0
    local -a owner_args=(--env=prod)
    if [ "$DRY_RUN" = "true" ]; then
        owner_args+=(--dry-run)
    fi

    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    set +e
    bash "$LIVE_STRIPE_REVERIFY_OWNER_SCRIPT" "${owner_args[@]}" >"$stdout_file" 2>"$stderr_file"
    owner_rc=$?
    set -e

    if [ "$owner_rc" -ne 0 ]; then
        local owner_stderr
        owner_stderr="$(cat "$stderr_file")"
        rm -f "$stdout_file" "$stderr_file"
        fail_with_classification "owner_script_failed" "live_card_e2e_test.sh failed: ${owner_stderr}"
    fi

    local owner_stdout
    owner_stdout="$(cat "$stdout_file")"
    rm -f "$stdout_file" "$stderr_file"

    local owner_fields
    owner_fields="$(python3 - "$owner_stdout" <<'PY'
import json
import sys

summary = json.loads(sys.argv[1])
pi_id = summary.get("payment_intent_id")
charge_id = summary.get("charge_id")
pi_text = "" if pi_id is None else str(pi_id).strip()
charge_text = "" if charge_id is None else str(charge_id).strip()
print(f"{pi_text}|{charge_text}")
print(json.dumps(summary, separators=(",", ":")))
PY
)" || fail_with_classification "owner_summary_shape_invalid" "owner summary output is not valid JSON"

    local owner_ids
    owner_ids="$(printf '%s\n' "$owner_fields" | sed -n '1p')"
    IFS='|' read -r PAYMENT_INTENT_ID CHARGE_ID <<< "$owner_ids"
    OWNER_SUMMARY_JSON="$(printf '%s\n' "$owner_fields" | sed -n '2p')"

    if [ "$DRY_RUN" != "true" ] && { [ -z "$PAYMENT_INTENT_ID" ] || [ -z "$CHARGE_ID" ]; }; then
        fail_with_classification "owner_summary_missing_stripe_ids" "owner summary is missing payment_intent_id or charge_id"
    fi
}

request_refund_with_retry() {
    local attempt=1
    local max_attempts=3
    local last_failure_message=""

    while [ "$attempt" -le "$max_attempts" ]; do
        if stripe_request POST /v1/refunds -d "charge=${CHARGE_ID}"; then
            if [ "${STRIPE_HTTP_CODE:-000}" = "200" ]; then
                REFUND_ID="$(python3 - "$STRIPE_BODY" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
refund_id = str(payload.get("id", "")).strip()
if not refund_id:
    raise SystemExit(1)
print(refund_id)
PY
)" || fail_with_classification "refund_response_shape_invalid" "Stripe refund response missing refund id"
                return 0
            fi
            last_failure_message="attempt ${attempt} HTTP ${STRIPE_HTTP_CODE}: ${STRIPE_BODY}"
        else
            last_failure_message="attempt ${attempt} transport error: ${STRIPE_BODY:-unknown transport error}"
        fi

        attempt=$((attempt + 1))
        if [ "$attempt" -le "$max_attempts" ]; then
            sleep 5
        fi
    done

    fail_with_classification "refund_failed_unrefunded_charge" "failed to refund charge_id=${CHARGE_ID}; ${last_failure_message}"
}

verify_payment_intent_readback() {
    stripe_request GET "/v1/payment_intents/${PAYMENT_INTENT_ID}" || fail_with_classification "stripe_readback_request_failed" "payment_intent readback request failed"
    if [ "${STRIPE_HTTP_CODE:-000}" != "200" ]; then
        fail_with_classification "stripe_readback_http_error" "payment_intent readback returned HTTP ${STRIPE_HTTP_CODE}"
    fi

    local payment_intent_validation
    payment_intent_validation="$(python3 - "$STRIPE_BODY" "$CHARGE_ID" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
expected_charge_id = sys.argv[2]
status = str(payload.get("status", "")).strip()
latest_charge = str(payload.get("latest_charge", "")).strip()
if status != "succeeded":
    raise SystemExit(f"payment_intent status mismatch: {status}")
if latest_charge != expected_charge_id:
    raise SystemExit(f"payment_intent latest_charge mismatch: {latest_charge}")
PY
)" || fail_with_classification "stripe_readback_validation_failed" "$payment_intent_validation"
}

verify_refund_readback() {
    stripe_request GET "/v1/refunds/${REFUND_ID}" || fail_with_classification "stripe_readback_request_failed" "refund readback request failed"
    if [ "${STRIPE_HTTP_CODE:-000}" != "200" ]; then
        fail_with_classification "stripe_readback_http_error" "refund readback returned HTTP ${STRIPE_HTTP_CODE}"
    fi

    local refund_validation
    refund_validation="$(python3 - "$STRIPE_BODY" "$CHARGE_ID" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
expected_charge_id = sys.argv[2]
status = str(payload.get("status", "")).strip()
charge_id = str(payload.get("charge", "")).strip()
if status != "succeeded":
    raise SystemExit(f"refund status mismatch: {status}")
if charge_id != expected_charge_id:
    raise SystemExit(f"refund charge mismatch: {charge_id}")
PY
)" || fail_with_classification "stripe_readback_validation_failed" "$refund_validation"
}

assert_version_no_drift() {
    local drift_result
    drift_result="$(python3 - "$VERSION_PREFLIGHT_JSON" "$VERSION_POSTFLIGHT_JSON" <<'PY'
import json
import sys

preflight = json.loads(sys.argv[1])
postflight = json.loads(sys.argv[2])
if preflight["dev_sha"] != postflight["dev_sha"]:
    raise SystemExit(f"dev_sha drifted: {preflight['dev_sha']} -> {postflight['dev_sha']}")
if preflight["mirror_sha"] != postflight["mirror_sha"]:
    raise SystemExit(f"mirror_sha drifted: {preflight['mirror_sha']} -> {postflight['mirror_sha']}")
print("ok")
PY
)" || fail_with_classification "version_drift_detected" "$drift_result"
}

render_runtime_summary_json() {
    # Stripe object IDs are routed through redact_identifier before serializing
    # because the GREEN bundle this output lands in is publicly synced via
    # .debbie.toml [[sync.dirs]] for docs/runbooks/. Raw IDs are retained
    # in-memory ($PAYMENT_INTENT_ID, $CHARGE_ID, $REFUND_ID) for refund and
    # readback calls — the redaction is on the persisted-evidence path only.
    local redacted_pi redacted_charge redacted_refund
    redacted_pi="$(redact_identifier "$PAYMENT_INTENT_ID")"
    redacted_charge="$(redact_identifier "$CHARGE_ID")"
    redacted_refund="$(redact_identifier "$REFUND_ID")"

    python3 - \
        "$DRY_RUN" \
        "$TARGET_ENV" \
        "$RUN_CLASSIFICATION" \
        "$OWNER_SUMMARY_JSON" \
        "$redacted_pi" \
        "$redacted_charge" \
        "$redacted_refund" \
        "$VERSION_PREFLIGHT_JSON" \
        "$VERSION_POSTFLIGHT_JSON" \
        "$GREEN_BUNDLE_DIR" <<'PY'
import json
import sys

REDACTED_OWNER_FIELDS = ("payment_intent_id", "charge_id")


def redact_owner_summary(owner):
    # The wrapper bundle is publicly synced; the embedded owner_summary
    # gets the same Stripe-ID redaction treatment as the top-level fields
    # so raw IDs cannot leak through the nested copy.
    if isinstance(owner, dict):
        for field in REDACTED_OWNER_FIELDS:
            if owner.get(field):
                owner[field] = "[REDACTED]"
    return owner


dry_run = sys.argv[1] == "true"
summary = {
    "dry_run": dry_run,
    "env": sys.argv[2],
    "classification": sys.argv[3],
    "owner_summary": redact_owner_summary(json.loads(sys.argv[4])),
    "payment_intent_id": sys.argv[5] or None,
    "charge_id": sys.argv[6] or None,
    "refund_id": sys.argv[7] or None,
    "version_preflight": json.loads(sys.argv[8]) if sys.argv[8] else None,
    "version_postflight": json.loads(sys.argv[9]) if sys.argv[9] else None,
    "green_bundle_dir": sys.argv[10] or None,
}
print(json.dumps(summary, separators=(",", ":")))
PY
}

write_green_bundle() {
    local timestamp summary_path summary_md_path summary_json
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    GREEN_BUNDLE_DIR="$LIVE_STRIPE_REVERIFY_EVIDENCE_ROOT/${timestamp}_phase_g_live_probe_GREEN"
    mkdir -p "$GREEN_BUNDLE_DIR"

    summary_json="$(render_runtime_summary_json)"
    summary_path="$GREEN_BUNDLE_DIR/summary.json"
    summary_md_path="$GREEN_BUNDLE_DIR/SUMMARY.md"
    printf '%s\n' "$summary_json" > "$summary_path"

    python3 - "$summary_path" <<'PY' > "$summary_md_path"
import json
import pathlib
import sys

summary_path = pathlib.Path(sys.argv[1])
summary = json.loads(summary_path.read_text(encoding="utf-8"))

print(f"# Phase G live stripe reverify — GREEN ({summary_path.parent.name})")
print("")
print("## Result")
print(f"- classification: `{summary['classification']}`")
print(f"- env: `{summary['env']}`")
print(f"- payment_intent_id: `{summary['payment_intent_id']}`")
print(f"- charge_id: `{summary['charge_id']}`")
print(f"- refund_id: `{summary['refund_id']}`")
print("")
print("## Version snapshots")
print(f"- preflight dev_sha: `{summary['version_preflight']['dev_sha']}`")
print(f"- preflight mirror_sha: `{summary['version_preflight']['mirror_sha']}`")
print(f"- postflight dev_sha: `{summary['version_postflight']['dev_sha']}`")
print(f"- postflight mirror_sha: `{summary['version_postflight']['mirror_sha']}`")
PY
}

main() {
    parse_args "$@"

    STRIPE_SECRET_KEY_EFFECTIVE="$(resolve_stripe_secret_key)" || fail_with_classification "stripe_key_unset" "unable to resolve stripe secret key"

    capture_version_probe "preflight"
    run_owner_and_extract_identifiers

    if [ "$DRY_RUN" = "true" ]; then
        printf '%s\n' "$(render_runtime_summary_json)"
        return 0
    fi

    request_refund_with_retry
    verify_payment_intent_readback
    verify_refund_readback
    capture_version_probe "postflight"
    assert_version_no_drift
    write_green_bundle
    printf '%s\n' "$(render_runtime_summary_json)"
}

if [ -n "${LIVE_STRIPE_REVERIFY_TEST_SHIM:-}" ]; then
    if [ "${LIVE_STRIPE_REVERIFY_ALLOW_TEST_SHIM:-0}" != "1" ]; then
        echo "ERROR: LIVE_STRIPE_REVERIFY_TEST_SHIM requires LIVE_STRIPE_REVERIFY_ALLOW_TEST_SHIM=1" >&2
        exit 64
    fi
    # shellcheck source=/dev/null
    source "$LIVE_STRIPE_REVERIFY_TEST_SHIM"
fi

main "$@"
