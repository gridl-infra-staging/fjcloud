#!/usr/bin/env bash
# Contract tests for checked-in Stage 1 SES boundary-proof artifacts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOUNDARY_DIR="$REPO_ROOT/docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof"
RECONCILIATION_DOC="$BOUNDARY_DIR/reconciliation_summary.md"
DRIFT_BLOCKER_DOC="$BOUNDARY_DIR/drift_blocker.md"
FIRST_SEND_RETRIEVAL_STATUS_DOC="$BOUNDARY_DIR/first_send_retrieval_status.md"
BOUNCE_SEND_RESPONSE_DOC="$BOUNDARY_DIR/bounce_send_response.json"
BOUNCE_EVENT_DOC="$BOUNDARY_DIR/bounce_event.json"
BOUNCE_BLOCKER_DOC="$BOUNDARY_DIR/bounce_blocker.txt"
COMPLAINT_SEND_RESPONSE_DOC="$BOUNDARY_DIR/complaint_send_response.json"
COMPLAINT_EVENT_DOC="$BOUNDARY_DIR/complaint_event.json"
COMPLAINT_BLOCKER_DOC="$BOUNDARY_DIR/complaint_blocker.txt"
HISTORICAL_TRANSCRIPT="$REPO_ROOT/docs/runbooks/evidence/ses-deliverability/20260423T202158Z_ses_boundary_proof_full.txt"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

json_field() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

payload_path = sys.argv[1]
path = sys.argv[2]
with open(payload_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

value = payload
for part in path.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        print("")
        raise SystemExit(0)

if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
elif value is None:
    print("")
else:
    print(str(value))
PY
}

json_array_length() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

payload_path = sys.argv[1]
path = sys.argv[2]
with open(payload_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

value = payload
for part in path.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        print("0")
        raise SystemExit(0)

if isinstance(value, list):
    print(str(len(value)))
else:
    print("0")
PY
}

json_first_present_field() {
    local payload_path="$1"
    shift

    local field_name value
    for field_name in "$@"; do
        value="$(json_field "$payload_path" "$field_name")"
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    printf '\n'
}

assert_shared_feedback_destination_blocker_contract() {
    local blocker_content="$1"
    local send_response_basename="$2"
    local artifact_label="$3"
    local require_live_discovery_command="${4:-0}"

    assert_contains "$blocker_content" "$send_response_basename" \
        "${artifact_label} blocker must reference ${send_response_basename}"
    assert_contains "$blocker_content" "bounce_live_domain_identity.json" \
        "${artifact_label} blocker must reference shared Stage 4 destination discovery artifact: bounce_live_domain_identity.json"
    assert_contains "$blocker_content" "bounce_destination_discovery.txt" \
        "${artifact_label} blocker must reference shared Stage 4 destination discovery artifact: bounce_destination_discovery.txt"
    assert_contains "$blocker_content" "domain_identity.json" \
        "${artifact_label} blocker must reference shared Stage 4 destination discovery artifact: domain_identity.json"
    assert_contains "$blocker_content" "dns_mail_from_mx.txt" \
        "${artifact_label} blocker must reference shared Stage 4 destination discovery artifact: dns_mail_from_mx.txt"
    assert_contains "$blocker_content" "reconciliation_summary.md" \
        "${artifact_label} blocker must reference shared Stage 4 destination discovery artifact: reconciliation_summary.md"
    assert_contains "$blocker_content" "20260423T202158Z_ses_boundary_proof_full.txt" \
        "${artifact_label} blocker must reference shared Stage 4 destination discovery transcript input"
    if [ "$require_live_discovery_command" -eq 1 ]; then
        assert_contains "$blocker_content" "Live discovery command:" \
            "${artifact_label} blocker must include the bounce discovery command preface"
        assert_contains "$blocker_content" "aws sesv2 get-email-identity --email-identity flapjack.foo --region us-east-1" \
            "${artifact_label} blocker must include the canonical bounce discovery command"
    fi
    assert_contains "$blocker_content" "Missing retrieval owner:" \
        "${artifact_label} blocker must identify the missing checked-in retrieval owner"
    assert_contains "$blocker_content" "No manual mailbox validation is allowed." \
        "${artifact_label} blocker must preserve the no-manual-validation stop condition"
    assert_contains "$blocker_content" "deliverability_boundaries.bounce_complaint_handling=unproven" \
        "${artifact_label} blocker must keep deliverability_boundaries.bounce_complaint_handling=unproven"
}

assert_simulator_feedback_artifact_contract() {
    local send_response_doc="$1"
    local event_doc="$2"
    local blocker_doc="$3"
    local event_notification_type="$4"
    local event_recipients_path="$5"
    local artifact_label="$6"
    local require_live_discovery_command="${7:-0}"

    local event_exists=0 blocker_exists=0
    if [ -f "$send_response_doc" ]; then
        pass "${artifact_label} send response artifact exists: $(basename "$send_response_doc")"
    else
        fail "${artifact_label} send response artifact missing: $send_response_doc"
        return
    fi

    if [ -f "$event_doc" ]; then
        event_exists=1
    fi
    if [ -f "$blocker_doc" ]; then
        blocker_exists=1
    fi

    if [ "$event_exists" -eq 1 ] && [ "$blocker_exists" -eq 0 ]; then
        pass "${artifact_label} artifacts include exactly one proof path: $(basename "$event_doc")"
    elif [ "$event_exists" -eq 0 ] && [ "$blocker_exists" -eq 1 ]; then
        pass "${artifact_label} artifacts include exactly one proof path: $(basename "$blocker_doc")"
    else
        fail "${artifact_label} artifacts must include exactly one of $(basename "$event_doc") or $(basename "$blocker_doc")"
        return
    fi

    if [ "$event_exists" -eq 1 ]; then
        local send_message_id event_message_id notification_type recipients_count
        send_message_id="$(json_first_present_field "$send_response_doc" "MessageId" "messageId")"
        notification_type="$(json_field "$event_doc" "notificationType")"
        event_message_id="$(json_field "$event_doc" "mail.messageId")"
        recipients_count="$(json_array_length "$event_doc" "$event_recipients_path")"

        assert_contains "$notification_type" "$event_notification_type" \
            "${artifact_label} event notificationType must be ${event_notification_type}"
        if [ "$recipients_count" -gt 0 ]; then
            pass "${artifact_label} event includes at least one ${event_recipients_path} entry"
        else
            fail "${artifact_label} event must include non-empty ${event_recipients_path}"
        fi
        if [ -n "$send_message_id" ] && [ "$event_message_id" = "$send_message_id" ]; then
            pass "${artifact_label} event mail.messageId matches $(basename "$send_response_doc") MessageId"
        else
            fail "${artifact_label} event mail.messageId must match $(basename "$send_response_doc") MessageId"
        fi
        return
    fi

    local blocker_content
    blocker_content="$(cat "$blocker_doc")"
    assert_shared_feedback_destination_blocker_contract \
        "$blocker_content" \
        "$(basename "$send_response_doc")" \
        "$artifact_label" \
        "$require_live_discovery_command"
}

test_boundary_directory_contains_stage1_artifacts() {
    local path
    for path in \
        "$BOUNDARY_DIR/ses_account.json" \
        "$BOUNDARY_DIR/sender_identity.json" \
        "$BOUNDARY_DIR/domain_identity.json" \
        "$BOUNDARY_DIR/readiness_probe.txt" \
        "$BOUNDARY_DIR/dns_apex_spf.txt" \
        "$BOUNDARY_DIR/dns_mail_from_mx.txt" \
        "$BOUNDARY_DIR/dns_mail_from_txt.txt" \
        "$RECONCILIATION_DOC" \
        "$DRIFT_BLOCKER_DOC" \
        "$FIRST_SEND_RETRIEVAL_STATUS_DOC"; do
        if [ -f "$path" ]; then
            pass "required Stage 1 boundary artifact exists: $(basename "$path")"
        else
            fail "required Stage 1 boundary artifact missing: $path"
        fi
    done

    local dkim_count
    dkim_count="$(ls "$BOUNDARY_DIR"/dns_dkim_*.txt 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$dkim_count" -ge 1 ]; then
        pass "boundary artifact directory includes dns_dkim_*.txt records"
    else
        fail "boundary artifact directory should include dns_dkim_*.txt records"
    fi
}

test_boundary_surface_has_no_parallel_machine_summary_owner() {
    local boundary_summary="$BOUNDARY_DIR/summary.json"
    local drift_content
    drift_content="$(cat "$DRIFT_BLOCKER_DOC")"

    if [ -f "$boundary_summary" ]; then
        fail "stage1 boundary-proof directory should not include a checked-in summary.json owner"
    else
        pass "stage1 boundary-proof directory has no checked-in summary.json owner"
    fi
    assert_contains "$drift_content" "MailFromDomainStatus=PENDING" \
        "drift blocker should preserve the stale checked-in claim that triggered the blocker"
    assert_contains "$drift_content" "reconciliation_summary.md" \
        "drift blocker should point to reconciliation_summary.md as the checked-in reconciliation owner"
    assert_contains "$drift_content" "Do not run send-capable owners." \
        "drift blocker should preserve fail-closed Stage 1 stop conditions"
    assert_not_contains "$drift_content" "summary.json" \
        "drift blocker should not introduce a checked-in machine-readable summary owner"
}

test_reconciliation_summary_preserves_historical_and_unproven_boundaries() {
    local reconciliation_content
    reconciliation_content="$(cat "$RECONCILIATION_DOC")"

    assert_contains "$reconciliation_content" "MailFromDomainStatus=SUCCESS" \
        "reconciliation summary should capture MailFromDomainStatus=SUCCESS from live evidence"
    assert_contains "$reconciliation_content" '`drift`' \
        "reconciliation summary should keep MAIL FROM mismatch marked as drift"
    assert_contains "$reconciliation_content" "20260423T202158Z_ses_boundary_proof_full.txt" \
        "reconciliation summary should reference the preserved transcript path"
    assert_contains "$reconciliation_content" "historical context and not as a competing source of truth" \
        "reconciliation summary should treat preserved transcript as historical-only context"
    assert_contains "$reconciliation_content" "still unproven" \
        "reconciliation summary should keep remaining deliverability boundaries unproven"
    assert_contains "$reconciliation_content" "SPF/MAIL FROM/bounce/complaint/first-send/inbox evidence" \
        "reconciliation summary should list the remaining unproven deliverability boundaries"
    assert_contains "$reconciliation_content" "/Users/stuart/.matt/projects/fjcloud_dev-cd6902f9/apr23_am_1_ses_deliverability_refined.md-4c6ea1bd/artifacts/stage_04_ses_deliverability/fjcloud_ses_deliverability_evidence_20260423T063739Z_63867" \
        "reconciliation summary should cite the canonical Stage 4 wrapper run directory"
    assert_contains "$reconciliation_content" "first_send_retrieval_status.md" \
        "reconciliation summary should cite the Stage 3 first-send retrieval companion artifact"
    if [[ "$reconciliation_content" == *"bounce_blocker.txt"* ]] || [[ "$reconciliation_content" == *"bounce_event.json"* ]]; then
        pass "reconciliation summary cites a Stage 4 bounce companion artifact path"
    else
        fail "reconciliation summary should cite either bounce_blocker.txt or bounce_event.json as the Stage 4 bounce companion artifact"
    fi
    if [[ "$reconciliation_content" == *"complaint_blocker.txt"* ]] || [[ "$reconciliation_content" == *"complaint_event.json"* ]]; then
        pass "reconciliation summary cites a Stage 5 complaint companion artifact path"
    else
        fail "reconciliation summary should cite either complaint_blocker.txt or complaint_event.json as the Stage 5 complaint companion artifact"
    fi
    assert_not_contains "$reconciliation_content" "proof complete" \
        "reconciliation summary should not claim proof-complete wording while boundaries remain open"
    assert_not_contains "$reconciliation_content" "proof captured" \
        "reconciliation summary should not claim proof-captured wording while boundaries remain open"
    assert_not_contains "$reconciliation_content" "proof-complete" \
        "reconciliation summary should not claim proof-complete marker wording while boundaries remain open"
    assert_not_contains "$reconciliation_content" "proof-captured" \
        "reconciliation summary should not claim proof-captured marker wording while boundaries remain open"
}

test_historical_transcript_preserves_original_pending_observation() {
    local transcript_content
    transcript_content="$(cat "$HISTORICAL_TRANSCRIPT")"

    assert_contains "$transcript_content" "MailFromDomainStatus\": \"PENDING\"" \
        "historical transcript should preserve the original PENDING status observation"
}

test_first_send_retrieval_status_contract() {
    local status_content
    status_content="$(cat "$FIRST_SEND_RETRIEVAL_STATUS_DOC")"

    assert_contains "$status_content" "Wrapper run directory:" \
        "first_send retrieval status should record wrapper run directory"
    assert_contains "$status_content" "Chosen recipient class:" \
        "first_send retrieval status should record recipient class"
    if [[ "$status_content" == *"Supplemental retrieval owner path:"* ]]; then
        assert_contains "$status_content" "Inbox/header evidence path:" \
            "first_send retrieval status should link inbox/header evidence when retrieval owner exists"
    elif [[ "$status_content" == *"Missing retrieval owner:"* ]]; then
        assert_contains "$status_content" "External dependency:" \
            "first_send retrieval blocker should name the explicit external dependency blocking automation"
        assert_contains "$status_content" "Minimum unblocking change:" \
            "first_send retrieval blocker should name the minimum unblocking change needed to automate retrieval"
        assert_contains "$status_content" "No manual mailbox validation is allowed." \
            "first_send retrieval status should enforce no-manual-validation stop condition when retrieval owner is missing"
        assert_contains "$status_content" "deliverability_boundaries.first_send_evidence=unproven" \
            "first_send retrieval blocker should keep first_send_evidence boundary unproven"
        assert_contains "$status_content" "deliverability_boundaries.inbox_receipt_proof=unproven" \
            "first_send retrieval blocker should keep inbox_receipt_proof boundary unproven"
    else
        fail "first_send retrieval status must choose either supplemental retrieval ownership or missing-owner blocker path"
    fi
}

test_bounce_artifact_contract() {
    assert_simulator_feedback_artifact_contract \
        "$BOUNCE_SEND_RESPONSE_DOC" \
        "$BOUNCE_EVENT_DOC" \
        "$BOUNCE_BLOCKER_DOC" \
        "Bounce" \
        "bounce.bouncedRecipients" \
        "bounce" \
        "1"

    if [ -f "$BOUNCE_EVENT_DOC" ]; then
        local bounce_type
        bounce_type="$(json_field "$BOUNCE_EVENT_DOC" "bounce.bounceType")"
        if [ -n "$bounce_type" ]; then
            pass "bounce event includes bounce.bounceType"
        else
            fail "bounce event must include non-empty bounce.bounceType"
        fi
    elif [ -f "$BOUNCE_BLOCKER_DOC" ]; then
        local bounce_blocker_content
        bounce_blocker_content="$(cat "$BOUNCE_BLOCKER_DOC")"
        assert_contains "$bounce_blocker_content" "Bounce retrieval owner gap:" \
            "bounce blocker should name the concrete bounce retrieval-owner gap"
        assert_contains "$bounce_blocker_content" "Minimum unblocking change:" \
            "bounce blocker should name the smallest acceptable unblocking change"
    fi
}

test_complaint_artifact_contract() {
    assert_simulator_feedback_artifact_contract \
        "$COMPLAINT_SEND_RESPONSE_DOC" \
        "$COMPLAINT_EVENT_DOC" \
        "$COMPLAINT_BLOCKER_DOC" \
        "Complaint" \
        "complaint.complainedRecipients" \
        "complaint"

    if [ -f "$COMPLAINT_BLOCKER_DOC" ]; then
        local complaint_blocker_content
        complaint_blocker_content="$(cat "$COMPLAINT_BLOCKER_DOC")"
        assert_contains "$complaint_blocker_content" "Recipient disambiguation policy:" \
            "complaint blocker should name the complaint recipient-disambiguation policy when proof is blocked"
        assert_contains "$complaint_blocker_content" "Minimum unblocking change:" \
            "complaint blocker should name the smallest acceptable unblocking change"
    fi
}

echo "=== ses_boundary_proof_artifact contract tests ==="
test_boundary_directory_contains_stage1_artifacts
test_boundary_surface_has_no_parallel_machine_summary_owner
test_reconciliation_summary_preserves_historical_and_unproven_boundaries
test_historical_transcript_preserves_original_pending_observation
test_first_send_retrieval_status_contract
test_bounce_artifact_contract
test_complaint_artifact_contract
run_test_summary
