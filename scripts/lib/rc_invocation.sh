#!/usr/bin/env bash
# Shared RC wrapper data helpers. Source-only: no live probes or delegated execution.

RC_PAID_BETA_ARGV=()
RC_SECTION1_MANIFEST_VALIDATION_OUTPUT=""
RC_STEP_SECTION_ENTRIES=(
    "browser_signup_paid:1"
    "browser_portal_cancel:1"
    "cargo_workspace_tests:2"
    "staging_billing_rehearsal:2"
    "stripe_webhook_signature_matrix_idempotency:2"
    "test_clock:2"
    "ses_readiness:3"
    "ses_inbound:3"
    "terraform_static_guardrails:4"
    "admin_broadcast:4"
    "billing_health_last_activity:4"
    "audit_timeline:4"
    "tenant_isolation:4"
    "signup_abuse:4"
    "backend_launch_gate:6"
    "local_signoff:6"
    "browser_preflight:6"
    "browser_auth_setup:6"
    "staging_runtime_smoke:6"
    "status_runtime:6"
    "canary_customer_loop:6"
    "canary_outside_aws:6"
    "prod_full_vm_lifecycle:6"
)

rc_section_for_step_name() {
    local step_name="$1"
    local entry mapped_name mapped_section
    for entry in "${RC_STEP_SECTION_ENTRIES[@]}"; do
        mapped_name="${entry%%:*}"
        if [ "$mapped_name" = "$step_name" ]; then
            mapped_section="${entry##*:}"
            printf '%s\n' "$mapped_section"
            return 0
        fi
    done
    return 1
}

rc_is_valid_sha() {
    local sha="$1"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
}

rc_is_valid_billing_month() {
    local billing_month="$1"
    [[ "$billing_month" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]]
}

rc_is_valid_ami_id() {
    local ami_id="$1"
    [[ "$ami_id" =~ ^ami-[0-9a-f]{8}([0-9a-f]{9})?$ ]]
}

rc_validate_section1_manifest() {
    local manifest_path="$1"
    local sha="$2"
    local billing_month="$3"
    local artifact_dir="$4"
    local validation_output="$artifact_dir/section1_manifest_validation.json"

    mkdir -p "$artifact_dir"
    if ! python3 "$REPO_ROOT/scripts/lib/ses_coverage_a1_integrity.py" validate \
            "--manifest=$manifest_path" \
            "--sha=$sha" \
            "--billing-month=$billing_month" \
            "--validation-output=$validation_output"; then
        echo "ERROR: section1 manifest validation failed: $manifest_path" >&2
        return 1
    fi

    # shellcheck disable=SC2034 # Sourced callers read this after validation.
    RC_SECTION1_MANIFEST_VALIDATION_OUTPUT="$validation_output"
}

rc_load_credential_env_file() {
    local credential_env_file="$1"

    if [ ! -f "$credential_env_file" ] || [ ! -r "$credential_env_file" ]; then
        echo "ERROR: credential env file is not readable: $credential_env_file" >&2
        exit 1
    fi
    if ! declare -F _for_each_env_assignment >/dev/null 2>&1; then
        echo "ERROR: rc_load_credential_env_file requires scripts/lib/env.sh" >&2
        exit 1
    fi

    if grep -Eq '^[[:space:]]*(export[[:space:]]+)?AWS_ACCESS_KEY_ID=' "$credential_env_file"; then
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE
    fi

    # shellcheck disable=SC2329 # _for_each_env_assignment invokes callbacks by name.
    _rc_load_credential_action() {
        printf -v "$ENV_ASSIGNMENT_KEY" '%s' "$ENV_ASSIGNMENT_VALUE"
        export "${ENV_ASSIGNMENT_KEY?}"
    }

    _for_each_env_assignment "$credential_env_file" _rc_load_credential_action || exit 1
}

rc_bridge_restricted_stripe_secret_key() {
    if [ -z "${STRIPE_SECRET_KEY:-}" ] && [ -n "${STRIPE_SECRET_KEY_RESTRICTED:-}" ]; then
        export STRIPE_SECRET_KEY="$STRIPE_SECRET_KEY_RESTRICTED"
    fi
}

rc_build_paid_beta_argv() {
    local sha="$1"
    local artifact_dir="$2"
    local credential_env_file="$3"
    local billing_month="$4"
    local staging_smoke_api_ami_id="$5"
    local staging_smoke_flapjack_ami_id="$6"
    local section1_manifest="${7:-}"
    local only_steps="${8:-}"

    # shellcheck disable=SC2034
    RC_PAID_BETA_ARGV=(
        --paid-beta-rc
        "--sha=$sha"
        "--artifact-dir=$artifact_dir"
        "--credential-env-file=$credential_env_file"
        "--billing-month=$billing_month"
        "--staging-smoke-api-ami-id=$staging_smoke_api_ami_id"
        "--staging-smoke-flapjack-ami-id=$staging_smoke_flapjack_ami_id"
    )
    if [ -n "$section1_manifest" ]; then
        RC_PAID_BETA_ARGV+=("--section1-manifest=$section1_manifest")
    fi
    if [ -n "$only_steps" ]; then
        RC_PAID_BETA_ARGV+=("--only-steps=$only_steps")
    fi
}

rc_write_run_receipt() {
    local receipt_path="$1"
    local artifact_dir="$2"
    local wrapper_exit="$3"
    local coordinator_exit="$4"
    local summary_path="$5"
    local section1_validation_path="$6"
    local sha="$7"
    local billing_month="$8"
    shift 8

    mkdir -p "$(dirname "$receipt_path")"
    python3 - "$receipt_path" "$artifact_dir" "$wrapper_exit" "$coordinator_exit" "$summary_path" "$section1_validation_path" "$sha" "$billing_month" "$@" <<'PY'
import hashlib
import json
import os
import sys

receipt_path, artifact_dir, wrapper_exit, coordinator_exit, summary_path, section1_validation_path, sha, billing_month = sys.argv[1:9]
argv = sys.argv[9:]

def digest_file(path):
    if not path or not os.path.isfile(path):
        return None
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()

def sanitize_arg(arg):
    if arg.startswith("--credential-env-file="):
        return "--credential-env-file=<redacted>"
    if arg.startswith("--artifact-dir="):
        return "--artifact-dir=<artifact_dir>"
    if arg.startswith("--section1-manifest="):
        return "--section1-manifest=<section1_manifest>"
    return arg

with open(section1_validation_path, "r", encoding="utf-8") as fh:
    section1_validation = json.load(fh)

payload = {
    "artifact_dir": "<artifact_dir>",
    "argv": [sanitize_arg(arg) for arg in argv],
    "billing_month": billing_month,
    "coordinator_exit": None if coordinator_exit == "" else int(coordinator_exit),
    "section1_manifest_digest": section1_validation.get("manifest_digest"),
    "sha": sha,
    "summary_digest": digest_file(summary_path),
    "wrapper_exit": int(wrapper_exit),
}
with open(receipt_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

rc_validate_run_receipt() {
    local receipt_path="$1"
    local sha="$2"
    local billing_month="$3"
    local section1_manifest="$4"
    local summary_path="${5:-}"

    python3 - "$receipt_path" "$sha" "$billing_month" "$section1_manifest" "$summary_path" <<'PY'
import hashlib
import json
import os
import sys

receipt_path, sha, billing_month, section1_manifest, summary_path = sys.argv[1:6]

def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)

def digest_file(path):
    if not path or not os.path.isfile(path):
        fail(f"path is not readable: {path}")
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()

with open(receipt_path, "r", encoding="utf-8") as fh:
    receipt = json.load(fh)

if receipt.get("sha") != sha:
    fail("run receipt SHA does not match")
if receipt.get("billing_month") != billing_month:
    fail("run receipt billing month does not match")
if receipt.get("section1_manifest_digest") != digest_file(section1_manifest):
    fail("section1 manifest digest does not match run receipt")
receipt_summary_digest = receipt.get("summary_digest")
if summary_path:
    if receipt_summary_digest != digest_file(summary_path):
        fail("summary digest does not match run receipt")
elif receipt_summary_digest:
    fail("summary is required when run receipt records a summary digest")
print("validated")
PY
}

# Validate an existing verdict by comparing it with this library's canonical
# classifier output. The timestamp is intentionally excluded because it records
# when classification ran, while every decision-bearing field must match.
rc_validate_verdict_for_summary() {
    local verdict_path="$1"
    local summary_path="$2"
    local section1_validation_path="$3"
    local expected_verdict
    expected_verdict="$(mktemp "${TMPDIR:-/tmp}/fjcloud_rc_expected_verdict.XXXXXX")"

    local classify_exit=0
    rc_write_verdict_for_summary "$summary_path" "$expected_verdict" "$section1_validation_path" || classify_exit=$?
    if [ "$classify_exit" -ne 0 ]; then
        rm -f "$expected_verdict"
        return "$classify_exit"
    fi

    local compare_exit=0
    python3 - "$verdict_path" "$expected_verdict" <<'PY' || compare_exit=$?
import json
import sys

verdict_path, expected_path = sys.argv[1:3]
with open(verdict_path, "r", encoding="utf-8") as fh:
    actual = json.load(fh)
with open(expected_path, "r", encoding="utf-8") as fh:
    expected = json.load(fh)
if not isinstance(actual.get("timestamp"), str) or not actual["timestamp"]:
    print("ERROR: verdict is missing its classification timestamp", file=sys.stderr)
    raise SystemExit(1)
actual.pop("timestamp")
expected.pop("timestamp")
if actual != expected:
    print("ERROR: verdict does not match canonical RC classification", file=sys.stderr)
    raise SystemExit(1)
PY
    rm -f "$expected_verdict"
    return "$compare_exit"
}

rc_write_validation_receipt() {
    local output_path="$1"
    local sha="$2"
    local section1_validation_path="$3"
    local verdict_path="$4"

    mkdir -p "$(dirname "$output_path")"
    python3 - "$output_path" "$sha" "$section1_validation_path" "$verdict_path" <<'PY'
import hashlib
import json
import sys

output_path, sha, section1_validation_path, verdict_path = sys.argv[1:5]

def digest_file(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()

with open(section1_validation_path, "r", encoding="utf-8") as fh:
    section1_validation = json.load(fh)
if section1_validation.get("status") != "validated":
    print("ERROR: Section 1 receipt is not validated", file=sys.stderr)
    raise SystemExit(1)
payload = {
    "section1_manifest_digest": section1_validation.get("manifest_digest"),
    "sha": sha,
    "status": "validated",
    "verdict_digest": digest_file(verdict_path),
}
with open(output_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

rc_write_verdict_for_summary() {
    local summary_path="$1"
    local verdict_path="$2"
    local section1_validation_path="${3:-}"
    local sections_encoded
    sections_encoded="$(printf '%s\x1f' "${RC_STEP_SECTION_ENTRIES[@]}")"
    RC_STEP_SECTIONS="$sections_encoded" python3 - "$summary_path" "$verdict_path" "$section1_validation_path" <<'PY'
import json
import os
import sys
import hashlib
from datetime import datetime, timezone
summary_path, verdict_path, section1_validation_path = sys.argv[1:4]
SUMMARY_DIR = os.path.dirname(os.path.abspath(summary_path))
EXPECTED_SECTION1_PROBES = {
    "verify_email_clickthrough",
    "password_reset_clickthrough",
    "dunning_email_inbox",
    "ses_bounce",
    "ses_complaint",
    "staging_dunning_delivery",
}
STEP_SECTIONS = {}
for entry in filter(None, os.environ.get("RC_STEP_SECTIONS", "").split("\x1f")):
    name, section = entry.rsplit(":", 1)
    STEP_SECTIONS[name] = int(section)
MODE_SKIP_REASONS = {
    "local_signoff_not_applicable_in_paid_beta_rc_mode",
    "staging_only_production_surface",
}
REQUIRED_STEP_NAMES = set(STEP_SECTIONS)
with open(summary_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)
steps = payload.get("steps")
if not isinstance(steps, list):
    raise SystemExit(f"ERROR: summary steps must be an array: {summary_path}")

def read_file_if_present(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""

def find_error_contexts(lane_dir):
    contexts = []
    for root, _dirs, files in os.walk(lane_dir):
        if "error-context.md" in files:
            contexts.append(read_file_if_present(os.path.join(root, "error-context.md")))
    return contexts

def browser_lane_result_logs(lane_dir):
    try:
        names = os.listdir(lane_dir)
    except FileNotFoundError:
        return []
    return sorted(
        name for name in names
        if name.endswith(".txt") and name != "git_sha.txt" and os.path.isfile(os.path.join(lane_dir, name))
    )

def browser_result_log_failed(content):
    failure_markers = (
        "Error:",
        "FAIL:",
        " failed",
        "failed ",
        "Timed out",
        "Timeout ",
    )
    return any(marker in content for marker in failure_markers)

def failed_browser_result_logs(lane_dir):
    return [
        name for name in browser_lane_result_logs(lane_dir)
        if browser_result_log_failed(read_file_if_present(os.path.join(lane_dir, name)))
    ]

def load_section1_manifest_result(receipt_path):
    if not receipt_path:
        return {
            "state": "legacy_unbound",
            "impact": "partial",
            "probe_count": None,
            "all_green": False,
            "all_probes_pass": False,
            "complete_red": False,
            "provenance_match": False,
            "manifest_digest": None,
        }
    with open(receipt_path, "r", encoding="utf-8") as fh:
        receipt = json.load(fh)
    manifest_path = receipt.get("manifest_path")
    if not isinstance(manifest_path, str) or not manifest_path:
        raise SystemExit(f"ERROR: section1 validation receipt missing manifest_path: {receipt_path}")
    with open(manifest_path, "rb") as fh:
        manifest_bytes = fh.read()
    manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
    manifest = json.loads(manifest_bytes)
    probes = manifest.get("probes")
    if probes is None:
        probes = manifest.get("rows")
    if not isinstance(probes, list):
        probes = []
    probe_ids = [probe.get("probe_id") for probe in probes if isinstance(probe, dict)]
    probe_count = len(probes)
    exact_six = probe_count == 6 and set(probe_ids) == EXPECTED_SECTION1_PROBES
    all_green = manifest.get("all_green") is True
    all_probes_pass = exact_six and all(
        isinstance(probe, dict)
        and probe.get("pass") is True
        and int(probe.get("rc", -1)) == 0
        for probe in probes
    )
    complete_red = exact_six and all(
        isinstance(probe, dict)
        and probe.get("pass") is False
        and int(probe.get("rc", 0)) != 0
        for probe in probes
    )
    provenance_match = (
        receipt.get("status") == "validated"
        and receipt.get("manifest_digest") == manifest_digest
        and receipt.get("sha") == manifest.get("source_sha")
        and receipt.get("billing_month") == manifest.get("billing_month")
    )
    if provenance_match and exact_six and all_green and all_probes_pass:
        state, impact = "green", "green"
    elif provenance_match and complete_red:
        state, impact = "complete_red", "red"
    else:
        state, impact = "structural_gap", "structural_gap"
    return {
        "state": state,
        "impact": impact,
        "probe_count": probe_count,
        "all_green": all_green,
        "all_probes_pass": all_probes_pass,
        "complete_red": complete_red,
        "provenance_match": provenance_match,
        "manifest_digest": manifest_digest,
    }

def browser_portal_card_selector_mismatch_has_rendered_form(step):
    if step.get("name") != "browser_portal_cancel":
        return False
    if step.get("status") != "fail" or step.get("reason", "") != "browser_portal_cancel_failed":
        return False
    lane_dir = os.path.join(SUMMARY_DIR, "browser_portal_cancel")
    if failed_browser_result_logs(lane_dir) != ["billing_portal_payment_method_update.txt"]:
        return False
    failure_log = read_file_if_present(os.path.join(lane_dir, "billing_portal_payment_method_update.txt"))
    waited_for_card_method_button = (
        "getByRole('button', { name: /^Card$/i })" in failure_log
        and "Error: element(s) not found" in failure_log
    )
    if not waited_for_card_method_button:
        return False
    required_rendered_markers = (
        'heading "Add Payment Method"',
        'textbox "Card number"',
        'textbox "Expiration date',
        'textbox "Security code"',
        'textbox "ZIP code"',
        'button "Save payment method"',
    )
    return any(all(marker in context for marker in required_rendered_markers) for context in find_error_contexts(lane_dir))

def classify(step):
    name = step.get("name")
    status = step.get("status")
    reason = step.get("reason", "")
    if not isinstance(name, str) or name not in STEP_SECTIONS:
        raise SystemExit(f"ERROR: non-pass RC step has no stable section mapping: {name!r}")
    if status in {"external_secret_missing", "live_evidence_gap"}:
        return "env_gap"
    if name == "staging_billing_rehearsal" and reason == "billing_run_no_created_invoices":
        return "env_gap"
    if browser_portal_card_selector_mismatch_has_rendered_form(step):
        return "harness_gap"
    if status == "skipped" and reason in MODE_SKIP_REASONS:
        return "mode_skip"
    if status == "setup_infra":
        return "setup_infra"
    if status == "investigate":
        return "investigate"
    return "other_real"

def summary_required_set_result():
    names = [step.get("name") for step in steps if isinstance(step.get("name"), str)]
    complete = len(names) == len(REQUIRED_STEP_NAMES) and set(names) == REQUIRED_STEP_NAMES
    all_pass = complete and all(step.get("status") == "pass" for step in steps)
    coordinator_green = payload.get("ready") is True and payload.get("verdict") == "pass"
    return complete, all_pass and coordinator_green

rows = []
for step in steps:
    status = step.get("status")
    if status == "pass":
        continue
    name = step.get("name")
    rows.append({
        "name": name,
        "status": status,
        "reason": step.get("reason", ""),
        "section": STEP_SECTIONS.get(name),
        "classification": classify(step),
    })
other_real_count = sum(1 for row in rows if row["classification"] == "other_real")
summary_required_set_complete, summary_required_set_passing = summary_required_set_result()
section1_manifest = load_section1_manifest_result(section1_validation_path)
section_impact = {str(section): "green" for section in range(1, 7)}
for row in rows:
    if row["classification"] == "other_real":
        section_impact[str(row["section"])] = "partial"
section_impact["1"] = section1_manifest["impact"]
if other_real_count > 0:
    verdict, pre_authorized_shape_match = "NOT-READY-real-defects", False
elif section1_manifest["state"] == "green" and summary_required_set_passing:
    verdict, pre_authorized_shape_match = "LAUNCH-READY", True
elif section1_manifest["state"] == "complete_red":
    verdict, pre_authorized_shape_match = "NOT-READY-on-section-1", True
else:
    verdict, pre_authorized_shape_match = "NOT-READY", False

def describe_classification_rows(classification):
    matching = [row for row in rows if row["classification"] == classification]
    if not matching:
        return f"{classification} rows: none"
    details = ", ".join(f"{row['name']}({row['status']}:{row['reason'] or 'no_reason'})" for row in matching)
    return f"{classification} rows: {details}"

rationale = " ".join((
    f"{len(rows)} non-pass steps; other_real_count={other_real_count}.",
    describe_classification_rows("env_gap") + ".",
    describe_classification_rows("harness_gap") + ".",
    describe_classification_rows("mode_skip") + ".",
    describe_classification_rows("setup_infra") + ".",
    describe_classification_rows("investigate") + ".",
    describe_classification_rows("other_real") + ".",
    "Section 1 follows docs/launch_verification_matrix.md when no real defect supersedes it.",
))
verdict_payload = {
    "verdict": verdict,
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "summary_source": "summary.json",
    "non_pass_steps": rows,
    "section_impact": section_impact,
    "section1_manifest": section1_manifest,
    "summary_required_set_complete": summary_required_set_complete,
    "summary_required_set_passing": summary_required_set_passing,
    "other_real_count": other_real_count,
    "pre_authorized_shape_match": pre_authorized_shape_match,
    "rationale": rationale,
}
output_dir = os.path.dirname(verdict_path)
if output_dir:
    os.makedirs(output_dir, exist_ok=True)
with open(verdict_path, "w", encoding="utf-8") as fh:
    json.dump(verdict_payload, fh, indent=2)
    fh.write("\n")
PY
}
