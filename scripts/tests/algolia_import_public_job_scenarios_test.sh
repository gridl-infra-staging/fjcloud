#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
contract="$repo_root/scripts/lib/algolia_import_public_job_contract.sh"
manifest="$repo_root/scripts/tests/fixtures/algolia_import_public_job_scenarios.json"

# shellcheck source=scripts/lib/algolia_import_public_job_contract.sh
source "$contract"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_invalid() {
    local fixture=$1
    local reason=$2
    if validate_algolia_import_public_job_manifest "$fixture" >/dev/null 2>&1; then
        fail "validator accepted mutation: $reason"
    fi
}

mutate_manifest() {
    local operation=$1
    local destination=$2
    python3 - "$manifest" "$destination" "$operation" <<'PY'
import copy
import json
import sys

source, destination, operation = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    document = json.load(handle)

scenarios = document["scenarios"]

def scenario(identifier):
    return next(row for row in scenarios if row["id"] == identifier)

if operation == "missing_id":
    scenarios.pop(0)
elif operation == "duplicate_id":
    scenarios.append(copy.deepcopy(scenarios[0]))
elif operation == "unknown_id":
    scenarios[0]["id"] = "not_a_required_public_scenario"
elif operation == "malformed_request":
    scenarios[0]["request"].pop("method")
elif operation == "malformed_oracle":
    scenarios[0]["oracle"]["status"] = 599
elif operation == "conditional_skip":
    scenarios[0]["skip_if"] = "backend unavailable"
elif operation == "missing_clock_action":
    scenario("retention_acknowledged_90_days")["actions"] = []
elif operation == "missing_cancel_row":
    scenarios.remove(scenario("cancel_queued"))
elif operation == "missing_resume_row":
    scenarios.remove(scenario("resume_fresh_credential_from_checkpoint"))
elif operation == "missing_asymmetry_row":
    scenarios.remove(scenario("pressure_cancel_environment_disabled"))
elif operation == "edited_expected_count":
    document["expected_count"] -= 1
elif operation == "wrong_body":
    scenario("replay_different_fingerprint_conflict")["oracle"]["body"]["code"] = "ok"
elif operation == "wrong_identity":
    scenario("replay_same_tenant_same_key_same_fingerprint")["oracle"]["job_identity"]["cloud_uuid"] = "new"
elif operation == "weakened_quota":
    scenario("quota_customer_count_boundary")["oracle"]["quota"]["accepted_at"] -= 1
elif operation == "early_gc":
    scenario("retention_acknowledged_90_days")["oracle"]["retention"]["gc_after_days"] = 89
elif operation == "reused_engine_uuid":
    scenario("retention_post_gc_key_reuse")["oracle"]["job_identity"]["engine_uuid"] = "same"
elif operation == "cross_tenant_visibility":
    scenario("ownership_cross_tenant_denied")["oracle"]["status"] = 200
elif operation == "pagination_loss":
    scenario("list_pagination")["oracle"]["pagination"]["all_job_ids_observed"] = False
elif operation == "cancelled_promoted":
    scenario("cancel_copying_documents")["oracle"]["publication_disposition"] = "promoted"
elif operation == "double_engine_cancel":
    scenario("cancel_repeated_cancelling")["oracle"]["engine_cancel_calls"] = 2
elif operation == "resume_duplication":
    scenario("resume_fresh_credential_from_checkpoint")["oracle"]["resume"]["duplicate_object_ids"] = 1
elif operation == "reversed_gating":
    scenario("pressure_cancel_environment_disabled")["oracle"]["status"] = 503
    scenario("pressure_resume_environment_disabled")["oracle"]["status"] = 202
else:
    raise SystemExit(f"unknown mutation: {operation}")

with open(destination, "w", encoding="utf-8") as handle:
    json.dump(document, handle)
PY
}

validate_algolia_import_public_job_manifest "$manifest"

required_count=$(algolia_import_public_job_required_ids | wc -l | tr -d ' ')
observed_count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["scenarios"]))' "$manifest")
[[ "$required_count" == "$observed_count" ]] || fail "required and observed scenario counts differ"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mutations=(
    missing_id duplicate_id unknown_id malformed_request malformed_oracle
    conditional_skip missing_clock_action missing_cancel_row missing_resume_row
    missing_asymmetry_row edited_expected_count wrong_body wrong_identity
    weakened_quota early_gc reused_engine_uuid cross_tenant_visibility
    pagination_loss cancelled_promoted double_engine_cancel resume_duplication
    reversed_gating
)

for mutation in "${mutations[@]}"; do
    mutated="$tmp_dir/$mutation.json"
    mutate_manifest "$mutation" "$mutated"
    expect_invalid "$mutated" "$mutation"
done

printf 'algolia public job scenario contract: ok (%s scenarios, %s mutations)\n' \
    "$observed_count" "${#mutations[@]}"
