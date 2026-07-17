#!/usr/bin/env bash

# Print the canonical public-job scenario identifiers, one per line.
# Manifest validation consumes this list as the single owner of required scenarios.
# TODO: Document algolia_import_public_job_required_ids.
# TODO: Document algolia_import_public_job_required_ids.
algolia_import_public_job_required_ids() {
    printf '%s\n' \
        replay_same_tenant_same_key_same_fingerprint \
        replay_different_fingerprint_conflict \
        replay_cross_tenant_same_key_isolated \
        replay_credential_rotation_same_fingerprint \
        quota_customer_count_boundary \
        quota_customer_bytes_boundary \
        quota_node_count_boundary \
        quota_node_bytes_boundary \
        ownership_cross_tenant_denied \
        status_get \
        list_pagination \
        retention_acknowledged_90_days \
        retention_post_gc_key_reuse \
        pressure_high_water_refusal_recovery \
        cancel_queued \
        cancel_validating_source \
        cancel_copying_configuration \
        cancel_copying_documents \
        cancel_verifying \
        cancel_resuming \
        cancel_before_promotion_commit \
        cancel_after_promotion_commit \
        cancel_repeated_cancelling \
        cancel_repeated_cancelled \
        cancel_terminal_refusal \
        cancel_cross_tenant_denied \
        pressure_cancel_environment_disabled \
        pressure_cancel_node_backpressure \
        pressure_cancel_retained_watermark \
        resume_fresh_credential_from_checkpoint \
        resume_response_lost_idempotency \
        resume_engine_marked_interruption \
        resume_deadline_refusal \
        resume_exhaustion_refusal \
        resume_gone_refusal \
        resume_non_resumable_refusal \
        pressure_resume_environment_disabled \
        pressure_resume_node_backpressure \
        pressure_resume_retained_watermark
}

validate_algolia_import_public_job_manifest() {
    local manifest=$1
    local required_ids
    required_ids=$(algolia_import_public_job_required_ids)
    ALGOLIA_IMPORT_REQUIRED_IDS="$required_ids" python3 - "$manifest" <<'PY'
import json
import os
import sys
from collections import Counter


def reject(message):
    print(f"invalid Algolia public job manifest: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition, message):
    if not condition:
        reject(message)


def nested(value, path):
    for key in path.split("."):
        require(isinstance(value, dict) and key in value, f"missing {path}")
        value = value[key]
    return value


def contains_forbidden_key(value):
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = key.lower().replace("-", "_")
            if normalized in {"skip", "skip_if", "skip_when", "condition", "conditional"}:
                return key
            found = contains_forbidden_key(child)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = contains_forbidden_key(child)
            if found:
                return found
    return None


try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        document = json.load(handle)
except (OSError, json.JSONDecodeError) as error:
    reject(str(error))

require(set(document) == {"schema_version", "expected_count", "scenarios"}, "root schema is not closed")
require(document["schema_version"] == 1, "schema_version must be 1")
require(isinstance(document["expected_count"], int), "expected_count must be an integer")
require(isinstance(document["scenarios"], list), "scenarios must be an array")

required = os.environ["ALGOLIA_IMPORT_REQUIRED_IDS"].splitlines()
required_set = set(required)
require(len(required) == len(required_set), "required ID oracle contains duplicates")
require(document["expected_count"] == len(required), "expected_count is not oracle-owned count")

rows = document["scenarios"]
ids = [row.get("id") for row in rows if isinstance(row, dict)]
duplicates = sorted(identifier for identifier, count in Counter(ids).items() if count > 1)
require(not duplicates, f"duplicate scenario IDs: {duplicates}")
observed_set = set(ids)
require(observed_set == required_set, f"required/observed ID mismatch missing={sorted(required_set - observed_set)} unknown={sorted(observed_set - required_set)}")
require(len(rows) == len(required), "scenario cardinality differs from required IDs")

by_id = {}
allowed_methods = {"GET", "POST"}
allowed_statuses = {200, 202, 400, 403, 404, 409, 410, 429, 503}
for row in rows:
    require(isinstance(row, dict), "scenario rows must be objects")
    require({"id", "category", "request", "oracle"} <= set(row), f"{row.get('id')} missing scenario fields")
    forbidden = contains_forbidden_key(row)
    require(forbidden is None, f"{row['id']} contains conditional skip field {forbidden}")
    request = row["request"]
    oracle = row["oracle"]
    require(isinstance(request, dict), f"{row['id']} request must be an object")
    require(set(request) == {"method", "path", "headers", "body"}, f"{row['id']} request schema is not closed")
    require(request["method"] in allowed_methods, f"{row['id']} request method is invalid")
    require(isinstance(request["path"], str) and request["path"].startswith("/v1/algolia/import-jobs"), f"{row['id']} request path is not public job HTTP")
    require(isinstance(request["headers"], dict), f"{row['id']} headers must be an object")
    require(request["body"] is None or isinstance(request["body"], dict), f"{row['id']} body must be object or null")
    require(isinstance(oracle, dict), f"{row['id']} oracle must be an object")
    require({"status", "body", "job_identity", "history", "quota", "clock", "content"} <= set(oracle), f"{row['id']} missing closed oracle fields")
    require(oracle["status"] in allowed_statuses, f"{row['id']} status is invalid")
    require(isinstance(oracle["body"], dict), f"{row['id']} body oracle must be an object")
    require(isinstance(oracle["job_identity"], dict), f"{row['id']} job identity oracle must be an object")
    require(isinstance(oracle["history"], list), f"{row['id']} history oracle must be an array")
    require(isinstance(oracle["quota"], dict), f"{row['id']} quota oracle must be an object")
    require(isinstance(oracle["clock"], dict), f"{row['id']} clock oracle must be an object")
    require(isinstance(oracle["content"], dict), f"{row['id']} content oracle must be an object")
    serialized = json.dumps(row, sort_keys=True).lower()
    require("direct_sql" not in serialized and "select * from" not in serialized, f"{row['id']} uses SQL as an acceptance oracle")
    by_id[row["id"]] = row


def value(identifier, path):
    return nested(by_id[identifier], path)


require(value("replay_same_tenant_same_key_same_fingerprint", "oracle.status") == 200, "same replay must return 200")
require(value("replay_same_tenant_same_key_same_fingerprint", "oracle.job_identity.cloud_uuid") == "same", "same replay must preserve cloud UUID")
require(value("replay_same_tenant_same_key_same_fingerprint", "oracle.job_identity.engine_uuid") == "same", "same replay must preserve engine UUID")
require(value("replay_different_fingerprint_conflict", "oracle.status") == 409, "different fingerprint must conflict")
require(value("replay_different_fingerprint_conflict", "oracle.body.code") == "idempotency_conflict", "different fingerprint body code drifted")
require(value("replay_cross_tenant_same_key_isolated", "oracle.status") == 202, "cross-tenant key must be isolated")
require(value("replay_cross_tenant_same_key_isolated", "oracle.job_identity.cloud_uuid") == "different", "cross-tenant cloud UUID must differ")
require(value("replay_credential_rotation_same_fingerprint", "oracle.job_identity.cloud_uuid") == "same", "credential rotation changed semantic identity")

quota_rules = {
    "quota_customer_count_boundary": (8, 9),
    "quota_customer_bytes_boundary": (10_737_418_240, 10_737_418_241),
    "quota_node_count_boundary": (4, 5),
    "quota_node_bytes_boundary": (10_737_418_240, 10_737_418_241),
}
for identifier, (accepted_at, refused_at) in quota_rules.items():
    oracle = by_id[identifier]["oracle"]
    require(oracle["status"] == 503, f"{identifier} must fail closed with 503")
    require(oracle["body"].get("code") == "backend_unavailable", f"{identifier} code drifted")
    require(oracle["quota"].get("accepted_at") == accepted_at, f"{identifier} accepted boundary drifted")
    require(oracle["quota"].get("refused_at") == refused_at, f"{identifier} refused boundary drifted")
    retry_after = oracle["quota"].get("retry_after_seconds")
    require(isinstance(retry_after, int) and 1 <= retry_after <= 60, f"{identifier} Retry-After is unbounded")

require(value("ownership_cross_tenant_denied", "oracle.status") == 403, "cross-tenant ownership must be denied")
require(value("ownership_cross_tenant_denied", "oracle.content.visible") is False, "cross-tenant job became visible")
require(value("status_get", "oracle.status") == 200, "job GET must remain available")
require(value("list_pagination", "oracle.pagination.all_job_ids_observed") is True, "pagination loses job IDs")
require(value("list_pagination", "oracle.pagination.cursor_progression") == "strict", "pagination cursor must progress")

retention = by_id["retention_acknowledged_90_days"]
actions = retention.get("actions")
require(isinstance(actions, list) and any(action == {"type": "advance_clock", "days": 90} for action in actions), "retention requires deterministic 90-day clock action")
require(retention["oracle"]["clock"] == {"source": "public_test_control", "advanced_days": 90}, "retention clock oracle drifted")
require(retention["oracle"]["retention"].get("gc_after_days") == 90, "retention permits early GC")
require(retention["oracle"]["retention"].get("terminal_ack_required") is True, "retention GC must require terminal ACK")
require(value("retention_post_gc_key_reuse", "oracle.job_identity.cloud_uuid") == "new", "post-GC cloud UUID must be new")
require(value("retention_post_gc_key_reuse", "oracle.job_identity.engine_uuid") == "new", "post-GC engine UUID must be new")

legal_cancel_ids = [
    "cancel_queued", "cancel_validating_source", "cancel_copying_configuration",
    "cancel_copying_documents", "cancel_verifying", "cancel_resuming",
    "cancel_before_promotion_commit",
]
for identifier in legal_cancel_ids:
    oracle = by_id[identifier]["oracle"]
    require(oracle["status"] == 202, f"{identifier} must return ordinary 202")
    require(oracle.get("publication_disposition") == "unchanged", f"{identifier} must remain cancelled+unchanged")
    require(oracle.get("destination_content") == "unchanged", f"{identifier} changed destination content")
    require(oracle.get("engine_cancel_calls") == 1, f"{identifier} must issue exactly one engine cancel")
require(value("cancel_after_promotion_commit", "oracle.status") == 409, "post-promotion cancel must refuse")
require(value("cancel_repeated_cancelling", "oracle.status") == 200, "repeated cancelling must be idempotent")
require(value("cancel_repeated_cancelled", "oracle.status") == 200, "repeated cancelled must be idempotent")
require(value("cancel_repeated_cancelling", "oracle.engine_cancel_calls") == 1, "repeated cancel doubled engine call")
require(value("cancel_repeated_cancelled", "oracle.engine_cancel_calls") == 1, "cancelled replay doubled engine call")
require(value("cancel_terminal_refusal", "oracle.status") == 409, "terminal cancel must refuse")
require(value("cancel_cross_tenant_denied", "oracle.status") == 403, "cross-tenant cancel must deny")

resume = by_id["resume_fresh_credential_from_checkpoint"]["oracle"]["resume"]
require(resume == {"checkpoint_k": 40, "final_n": 100, "new_writes": 60, "duplicate_object_ids": 0, "credential": "fresh", "checkpoint_in_request": False, "cloud_uuid": "same", "engine_uuid": "same", "progress": "monotonic"}, "fresh-credential resume arithmetic or identity drifted")
lost = by_id["resume_response_lost_idempotency"]["oracle"]["resume"]
require(lost.get("engine_resume_calls") == 1 and lost.get("new_writes") == 60 and lost.get("duplicate_object_ids") == 0, "response-lost resume is not generation-idempotent")
require(value("resume_engine_marked_interruption", "oracle.resumable") is True, "engine interruption must remain resumable")
for identifier, status in {
    "resume_deadline_refusal": 409,
    "resume_exhaustion_refusal": 409,
    "resume_gone_refusal": 410,
    "resume_non_resumable_refusal": 409,
}.items():
    require(value(identifier, "oracle.status") == status, f"{identifier} refusal status drifted")

for suffix in ["environment_disabled", "node_backpressure", "retained_watermark"]:
    cancel = by_id[f"pressure_cancel_{suffix}"]["oracle"]
    resume_pressure = by_id[f"pressure_resume_{suffix}"]["oracle"]
    require(cancel["status"] in {200, 202}, f"cancel pressure {suffix} returned availability error")
    require("retry_after_seconds" not in cancel, f"cancel pressure {suffix} exposed Retry-After")
    require(resume_pressure["status"] == 503, f"resume pressure {suffix} must return 503")
    require(resume_pressure["body"].get("code") == "backend_unavailable", f"resume pressure {suffix} code drifted")
    retry_after = resume_pressure.get("retry_after_seconds")
    require(isinstance(retry_after, int) and 1 <= retry_after <= 60, f"resume pressure {suffix} Retry-After is unbounded")
    require(resume_pressure.get("job_unchanged") is True and resume_pressure.get("resumable") is True, f"resume pressure {suffix} mutated job")
    for oracle in [cancel, resume_pressure]:
        require(oracle["content"] == {"job_get": "available", "job_list": "available", "status": "available", "search": "unchanged"}, f"pressure {suffix} hid retained work")

high_water = by_id["pressure_high_water_refusal_recovery"]["oracle"]
require(high_water["status"] == 503 and high_water["body"].get("code") == "backend_unavailable", "high-water admission must fail closed")
require(high_water["quota"].get("recovers_after_release") is True, "high-water scenario lacks recovery")
PY
}
