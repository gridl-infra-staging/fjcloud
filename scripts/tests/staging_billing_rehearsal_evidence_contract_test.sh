#!/usr/bin/env bash
# Focused contract tests for Stage 3 rehearsal evidence artifact payloads.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/staging_billing_rehearsal_harness.sh
source "$SCRIPT_DIR/lib/staging_billing_rehearsal_harness.sh"

json_file_transition_invoice_id() {
    local json_path="$1"
    local transition="$2"
    python3 - "$json_path" "$transition" <<'PY' 2>/dev/null || true
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)
transition = sys.argv[2]
value = ((payload.get("payload") or {}).get("transition_invoice_ids") or {}).get(transition, "")
if value is None:
    value = ""
print(str(value))
PY
}

assert_transition_invoice_map() {
    local json_path="$1" artifact_label="$2"

    assert_eq "$(json_file_transition_invoice_id "$json_path" "failed")" "inv_stage3_a" \
        "$artifact_label payload should emit failed transition invoice ID"
    assert_eq "$(json_file_transition_invoice_id "$json_path" "suspended")" "inv_stage3_b" \
        "$artifact_label payload should emit suspended transition invoice ID"
    assert_eq "$(json_file_transition_invoice_id "$json_path" "recovered")" "inv_stage3_a" \
        "$artifact_label payload should emit recovered transition invoice ID"
}

test_rehearsal_artifacts_emit_transition_invoice_ids_contract() {
    setup_workspace
    wrap_preflight_owner_with_call_log

    run_rehearsal --args "--env-file $TEST_WORKSPACE/inputs/staging_rehearsal.explicit.env --month 2026-03 --confirm-live-mutation"
    assert_rehearsal_succeeds

    local artifact_dir
    artifact_dir="$(find_artifact_dir)"
    assert_stage3_evidence_artifacts_exist "$artifact_dir"

    assert_transition_invoice_map "$artifact_dir/invoice_rows.json" "invoice_rows"
    assert_transition_invoice_map "$artifact_dir/webhook.json" "webhook"
}

echo "=== staging_billing_rehearsal evidence contract tests ==="
test_rehearsal_artifacts_emit_transition_invoice_ids_contract
run_test_summary
