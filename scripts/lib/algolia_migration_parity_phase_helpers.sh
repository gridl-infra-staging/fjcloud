#!/usr/bin/env bash

parity_observed_summary() {
    local report_file="$1" fixture_file="$2"
    python3 - "$report_file" "$fixture_file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    report = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    hits = json.load(handle)
object_ids = sorted(hit.get("objectID", "") for hit in hits if isinstance(hit, dict))
print(
    "count_source={count_source},count_migrated={count_migrated},"
    "only_in_source={only_in_source},only_in_migrated={only_in_migrated},"
    "field_mismatches={field_mismatches},object_ids={object_ids}".format(
        count_source=report["count_source"],
        count_migrated=report["count_migrated"],
        only_in_source=len(report["only_in_source"]),
        only_in_migrated=len(report["only_in_migrated"]),
        field_mismatches=len(report["field_mismatches"]),
        object_ids=",".join(object_ids),
    )
)
PY
}

fixture_count() {
    python3 - "$1" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(len(json.load(handle)))
PY
}

assert_fixture_ids() {
    local fixture_file="$1" expected_ids="$2"
    python3 - "$fixture_file" "$expected_ids" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    hits = json.load(handle)
actual = ",".join(sorted(hit.get("objectID", "") for hit in hits if isinstance(hit, dict)))
raise SystemExit(0 if actual == sys.argv[2] else 1)
PY
}

run_parity_oracle() {
    local source_fixture="${1:-$FIXTURE_FILE}" target_index="${2:-$TARGET_INDEX}" phase_label="${3:-parity_create_into_fresh}" expected_count="${4:-3}" expected_ids="${5:-doc-1,doc-2,doc-3}"
    CURRENT_STEP="parity"
    [ "$(fixture_count "$source_fixture")" = "$expected_count" ] || finish_action_required "inconclusive_evidence"
    assert_fixture_ids "$source_fixture" "$expected_ids" || finish_action_required "inconclusive_evidence"
    browse_collection_to_file flapjack "$target_index" "$MIGRATED_HITS_FILE"
    set +e
    python3 "$PARITY_ORACLE" --source "$source_fixture" --migrated "$MIGRATED_HITS_FILE" > "$PARITY_REPORT_FILE"
    local oracle_status=$?
    set -e
    [ "$oracle_status" -ne 2 ] || finish_action_required "inconclusive_evidence"
    local observed
    observed="$(parity_observed_summary "$PARITY_REPORT_FILE" "$source_fixture")"
    if [ "$oracle_status" -eq 0 ] && [ "$observed" = "count_source=${expected_count},count_migrated=${expected_count},only_in_source=0,only_in_migrated=0,field_mismatches=0,object_ids=${expected_ids}" ]; then
        if [ "$phase_label" = "parity_create_into_fresh" ]; then
            emit_phase "$phase_label" "count=${expected_count},diff=empty" "${observed%,object_ids=*}" "true"
        else
            emit_phase "$phase_label" "count=${expected_count},object_ids=${expected_ids},diff=empty" "$observed" "true"
        fi
        return 0
    fi
    emit_phase "$phase_label" "count=${expected_count},object_ids=${expected_ids},diff=empty" "$observed" "false"
    emit_parity_diff_summary
    finish_action_required "parity_mismatch"
}

assert_algolia_source_matches_fixture() {
    local source_index="$1" source_fixture="$2" expected_ids="$3"
    CURRENT_STEP="source_known_answer"
    browse_collection_to_file algolia "$source_index" "$SOURCE_HITS_FILE"
    set +e
    python3 "$PARITY_ORACLE" --source "$source_fixture" --migrated "$SOURCE_HITS_FILE" > "$PARITY_REPORT_FILE"
    local oracle_status=$?
    set -e
    [ "$oracle_status" -eq 0 ] || finish_action_required "parity_mismatch"
    assert_fixture_ids "$source_fixture" "$expected_ids" || finish_action_required "inconclusive_evidence"
}

emit_target_count_phase() {
    local target_index="$1" phase_label="$2" expected_count="$3" actual_count
    browse_collection_to_file flapjack "$target_index" "$MIGRATED_HITS_FILE"
    actual_count="$(fixture_count "$MIGRATED_HITS_FILE")"
    if [ "$actual_count" = "$expected_count" ]; then
        emit_phase "$phase_label" "count=$expected_count" "count=$actual_count" "true"
        return 0
    fi
    emit_phase "$phase_label" "count=$expected_count" "count=$actual_count" "false"
    finish_action_required "parity_mismatch"
}

require_engine_acknowledged() {
    local on_failure="${1:-finish_action_required}"
    CURRENT_STEP="engine_ack"
    local elapsed=0 acknowledged debug
    while :; do
        acknowledged="$(job_engine_acknowledged_count || true)"
        [ "$acknowledged" = "1" ] && return 0
        [ "$elapsed" -lt "$POLL_SECONDS" ] || {
            debug="$(job_reconciliation_debug || printf 'unavailable')"
            emit "EVIDENCE|engine_ack=missing|job_state=${debug:-empty}"
            "$on_failure" "inconclusive_evidence"
        }
        sleep "$POLL_INTERVAL_SECONDS"
        elapsed=$((elapsed + POLL_INTERVAL_SECONDS))
    done
}

http_body_summary() {
    [ -n "${HTTP_BODY:-}" ] || { printf 'none\n'; return 0; }
    python3 - "$HTTP_BODY" <<'PY'
import json
import sys
try:
    payload = json.loads(sys.argv[1])
except json.JSONDecodeError:
    print("non_json")
    raise SystemExit(0)
if not isinstance(payload, dict):
    print(type(payload).__name__)
    raise SystemExit(0)
parts = []
for key in ("error", "message", "code", "status", "id"):
    value = payload.get(key)
    if isinstance(value, str) and value:
        parts.append(f"{key}:{value}")
print(",".join(parts) if parts else "object")
PY
}

SESSION_READY=0

ensure_probe_session() {
    [ "$SESSION_READY" -eq 1 ] && return 0
    start_stack
    require_health
    register_and_login
    require_migration_availability
    SESSION_READY=1
}

select_phase_indexes() {
    local phase="$1"
    case "$phase" in
        create_into_fresh)
            SOURCE_INDEX="$BASE_SOURCE_INDEX"
            TARGET_INDEX="$BASE_TARGET_INDEX"
            IDEMPOTENCY_KEY="${PROBE_PREFIX}_${RUN_ID}_create"
            ;;
        overwrite_rerun)
            SOURCE_INDEX="${PROBE_PREFIX}_${RUN_ID}_ow_source"
            TARGET_INDEX="${PROBE_PREFIX}_${RUN_ID}_ow_target"
            IDEMPOTENCY_KEY="${PROBE_PREFIX}_${RUN_ID}_overwrite_create"
            ;;
        idempotency)
            SOURCE_INDEX="${PROBE_PREFIX}_${RUN_ID}_id_source"
            SECOND_SOURCE_INDEX="${PROBE_PREFIX}_${RUN_ID}_id_source_alt"
            TARGET_INDEX="${PROBE_PREFIX}_${RUN_ID}_id_target"
            IDEMPOTENCY_KEY="${PROBE_PREFIX}_${RUN_ID}_idempotency_create"
            ;;
        cancel_partial)
            SOURCE_INDEX="${PROBE_PREFIX}_${RUN_ID}_cp_source"
            TARGET_INDEX="${PROBE_PREFIX}_${RUN_ID}_cp_target"
            IDEMPOTENCY_KEY="${PROBE_PREFIX}_${RUN_ID}_cancel_partial_create"
            ;;
        resume_refused)
            SOURCE_INDEX="${PROBE_PREFIX}_${RUN_ID}_rr_source"
            TARGET_INDEX="${PROBE_PREFIX}_${RUN_ID}_rr_target"
            IDEMPOTENCY_KEY="${PROBE_PREFIX}_${RUN_ID}_resume_refused_create"
            ;;
    esac
}

run_create_into_fresh() {
    ensure_probe_session
    select_phase_indexes create_into_fresh
    seed_source_index
    create_restricted_key
    prime_local_node_key
    obtain_target_envelope
    track_flapjack_target "$TARGET_INDEX"
    dispatch_job
    poll_job_to_terminal
    require_engine_acknowledged
    run_parity_oracle "$FIXTURE_FILE" "$TARGET_INDEX" "parity_create_into_fresh" "3" "doc-1,doc-2,doc-3"
}

write_mutated_fixture() {
    local output="$1"
    python3 - "$FIXTURE_FILE" "$output" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    docs = json.load(handle)
mutated = []
for doc in docs:
    if doc.get("objectID") == "doc-3":
        continue
    item = dict(doc)
    if item.get("objectID") == "doc-2":
        item["price"] = 251
    mutated.append(item)
mutated.append({"objectID": "doc-4", "title": "Delta", "price": 400, "tags": ["z"]})
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(mutated, handle, separators=(",", ":"))
PY
}

mutate_source_index() {
    local source_index="$1" fixture_file="$2" payload task_id
    CURRENT_STEP="mutate_source"
    payload="$(secure_temp_file)"
    python3 - "$fixture_file" "$payload" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    docs = json.load(handle)
requests = [{"action": "deleteObject", "body": {"objectID": "doc-3"}}]
requests.extend({"action": "addObject", "body": doc} for doc in docs)
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump({"requests": requests}, handle, separators=(",", ":"))
PY
    algolia_request "200 201" POST "/1/indexes/$source_index/batch" "$payload" || finish_action_required "endpoint_unavailable"
    task_id="$(json_field "$HTTP_BODY" taskID 2>/dev/null || true)"
    if [ -n "$task_id" ]; then
        safe_response_identifier "$task_id" || finish_action_required "invalid_response_identifier"
        algolia_import_probe_wait_for_algolia_task "$source_index" "$task_id" || finish_action_required "inconclusive_evidence"
    fi
}

run_overwrite_rerun() {
    local mutated_fixture
    ensure_probe_session
    require_replace_capability
    select_phase_indexes overwrite_rerun
    seed_source_index "$SOURCE_INDEX" "$FIXTURE_FILE"
    create_restricted_key "$SOURCE_INDEX"
    prime_local_node_key
    obtain_target_envelope
    track_flapjack_target "$TARGET_INDEX"
    dispatch_job create "$SOURCE_INDEX" "$IDEMPOTENCY_KEY"
    poll_job_to_terminal
    require_engine_acknowledged
    emit_target_count_phase "$TARGET_INDEX" "overwrite_initial" "3"

    IDEMPOTENCY_KEY="${PROBE_PREFIX}_${RUN_ID}_overwrite_replace_same"
    obtain_replace_target_envelope
    dispatch_job replace "$SOURCE_INDEX" "$IDEMPOTENCY_KEY"
    poll_job_to_terminal
    require_engine_acknowledged
    run_parity_oracle "$FIXTURE_FILE" "$TARGET_INDEX" "overwrite_rerun" "3" "doc-1,doc-2,doc-3"

    mutated_fixture="$(secure_temp_file)"
    write_mutated_fixture "$mutated_fixture"
    mutate_source_index "$SOURCE_INDEX" "$mutated_fixture"
    assert_algolia_source_matches_fixture "$SOURCE_INDEX" "$mutated_fixture" "doc-1,doc-2,doc-4"
    IDEMPOTENCY_KEY="${PROBE_PREFIX}_${RUN_ID}_overwrite_replace_mutated"
    obtain_replace_target_envelope
    dispatch_job replace "$SOURCE_INDEX" "$IDEMPOTENCY_KEY"
    poll_job_to_terminal
    require_engine_acknowledged
    run_parity_oracle "$mutated_fixture" "$TARGET_INDEX" "overwrite_rerun_mutated" "3" "doc-1,doc-2,doc-4"
}

write_job_payload() {
    local output="$1" mode="$2" source_index="$3"
    write_json_file "$output" "{\"mode\":\"$mode\",\"appId\":\"$ALGOLIA_APP_ID\",\"apiKey\":\"$DISPOSABLE_KEY\",\"sourceName\":\"$source_index\",\"target\":{\"eligibilityToken\":\"$TARGET_TOKEN\"}}"
}

submit_job_payload() {
    local payload="$1" idempotency="$2" expected="$3"
    api_request "$expected" POST "/migration/algolia/jobs" "$payload" "$idempotency"
}

# Every job the engine accepted (HTTP 202) that must reach terminal promoted
# success plus durable ACK before we tear down its shared source, key, or target.
# Owned generically so both idempotency replays and overwrite dispatches drain
# their accepted jobs through one lifecycle path.
ACCEPTED_JOB_IDS=()
# Terminal kind a job is expected to reach unless a phase overrides it.
DEFAULT_JOB_TERMINAL_KIND="promoted_success"
# Expected terminal kind per accepted job, as job_id/kind rows joined by
# ACCEPTED_JOB_ROW_SEPARATOR and terminated by newlines. Kept as a plain string
# rather than an associative array so repo-supported Bash 3.2 can run the same
# canonical drain without a shell-version fork.
ACCEPTED_JOB_ROW_SEPARATOR=$'\t'
ACCEPTED_JOB_TERMINAL_KIND_ROWS=""
DRAINING_ACCEPTED_JOBS=0

parse_response_job_fields() {
    PARSED_JOB_ID="$(json_field "$HTTP_BODY" id 2>/dev/null || true)"
    PARSED_JOB_LOCATION="$(sed -n 's/^[Ll]ocation:[[:space:]]*//p' "$HTTP_HEADERS_FILE" | tr -d '\r' | tail -1)"
    [ -n "$PARSED_JOB_ID" ] || return 1
    safe_response_identifier "$PARSED_JOB_ID" || return 1
    [ "$PARSED_JOB_LOCATION" = "/migration/algolia/jobs/$PARSED_JOB_ID" ] || return 1
}

# Conservatively identify an accepted job from the Location header alone, used
# when the response body is missing or disagrees with the header. The Location
# header is the canonical resource pointer for the newly created job, so a valid
# one lets us track and drain that job before cleanup even under a malformed body.
parse_job_id_from_location() {
    local location job_id
    location="$(sed -n 's/^[Ll]ocation:[[:space:]]*//p' "$HTTP_HEADERS_FILE" | tr -d '\r' | tail -1)"
    case "$location" in
        /migration/algolia/jobs/*) ;;
        *) return 1 ;;
    esac
    job_id="${location##*/}"
    [ -n "$job_id" ] || return 1
    safe_response_identifier "$job_id" || return 1
    PARSED_JOB_ID="$job_id"
    PARSED_JOB_LOCATION="$location"
}

track_accepted_job() {
    local job_id="$1" kind="${2:-$DEFAULT_JOB_TERMINAL_KIND}"
    set_job_terminal_kind "$job_id" "$kind"
    if accepted_job_is_tracked "$job_id"; then
        return 0
    fi
    ACCEPTED_JOB_IDS+=("$job_id")
}

accepted_job_is_tracked() {
    local job_id="$1" existing
    for existing in "${ACCEPTED_JOB_IDS[@]+"${ACCEPTED_JOB_IDS[@]}"}"; do
        [ "$existing" = "$job_id" ] && return 0
    done
    return 1
}

# Update the expected terminal kind for an already-tracked job. A cancellation
# turns a job accepted as a promotion into one whose canonical terminal is
# cancelled_unchanged, so the shared drain waits for the right terminal tuple.
set_job_terminal_kind() {
    local job_id="$1" kind="$2" current_id current_kind other_rows=""
    while IFS="$ACCEPTED_JOB_ROW_SEPARATOR" read -r current_id current_kind; do
        [ -n "$current_id" ] || continue
        [ "$current_id" = "$job_id" ] && continue
        other_rows="${other_rows}${current_id}${ACCEPTED_JOB_ROW_SEPARATOR}${current_kind}"$'\n'
    done <<<"$ACCEPTED_JOB_TERMINAL_KIND_ROWS"
    ACCEPTED_JOB_TERMINAL_KIND_ROWS="${other_rows}${job_id}${ACCEPTED_JOB_ROW_SEPARATOR}${kind}"$'\n'
}

accepted_job_terminal_kind() {
    local job_id="$1" current_id current_kind
    while IFS="$ACCEPTED_JOB_ROW_SEPARATOR" read -r current_id current_kind; do
        [ -n "$current_id" ] || continue
        if [ "$current_id" = "$job_id" ]; then
            printf '%s\n' "$current_kind"
            return 0
        fi
    done <<<"$ACCEPTED_JOB_TERMINAL_KIND_ROWS"
    printf '%s\n' "$DEFAULT_JOB_TERMINAL_KIND"
}

track_current_job_response() {
    parse_response_job_fields || finish_accepted_job_action_required "inconclusive_evidence"
    track_accepted_job "$PARSED_JOB_ID"
}

parse_current_job_response() {
    track_current_job_response
    JOB_ID="$PARSED_JOB_ID"
    JOB_LOCATION="$PARSED_JOB_LOCATION"
}

# When a failing step still returned HTTP 202, the engine accepted a job we must
# not orphan. Track it by body id or, failing that, the canonical Location header.
track_unexpected_acceptance() {
    [ "${HTTP_STATUS:-}" = "202" ] || return 0
    if parse_response_job_fields || parse_job_id_from_location; then
        track_accepted_job "$PARSED_JOB_ID"
        return 0
    fi
    return 1
}

# Fail closed while preserving every tracked remote resource. Used when an
# accepted job did not reach terminal promoted success plus durable ACK within
# the drain budget: cleanup must not delete a source index, restricted key, or
# target that a still-running worker depends on.
finish_live_job_action_required() {
    PRESERVE_LIVE_JOB_RESOURCES=1
    finish_action_required "$1"
}

# Poll every accepted job to terminal promoted success plus durable ACK before
# cleanup. Runs with DRAINING_ACCEPTED_JOBS set so any per-job timeout preserves
# the live worker's remote resources instead of recursing into another drain or
# racing destructive cleanup.
drain_accepted_jobs() {
    local original_job_id="${JOB_ID:-}" original_job_location="${JOB_LOCATION:-}" job_id
    DRAINING_ACCEPTED_JOBS=1
    for job_id in "${ACCEPTED_JOB_IDS[@]+"${ACCEPTED_JOB_IDS[@]}"}"; do
        JOB_ID="$job_id"
        JOB_LOCATION="/migration/algolia/jobs/$job_id"
        poll_job_to_terminal finish_live_job_action_required
        require_engine_acknowledged finish_live_job_action_required
    done
    DRAINING_ACCEPTED_JOBS=0
    JOB_ID="$original_job_id"
    JOB_LOCATION="$original_job_location"
}

finish_accepted_job_action_required() {
    local reason="$1"
    if [ "$DRAINING_ACCEPTED_JOBS" -eq 1 ]; then
        finish_live_job_action_required "$reason"
    fi
    local failure_body="${HTTP_BODY:-}" failure_status="${HTTP_STATUS:-none}" failure_target="${HTTP_REQUEST_TARGET:-none}" failure_step="$CURRENT_STEP"
    track_unexpected_acceptance || {
        [ "$failure_target" = "POST /migration/algolia/jobs/${JOB_ID:-}/cancel" ] \
            && accepted_job_is_tracked "${JOB_ID:-}"
    } || finish_live_job_action_required "invalid_response_identifier"
    drain_accepted_jobs
    HTTP_BODY="$failure_body"
    HTTP_STATUS="$failure_status"
    HTTP_REQUEST_TARGET="$failure_target"
    CURRENT_STEP="$failure_step"
    finish_action_required "$reason"
}

run_idempotency() {
    local payload changed_payload replay_id replay_location conflict_code source_count key_count terminal_count
    ensure_probe_session
    select_phase_indexes idempotency
    seed_source_index "$SOURCE_INDEX" "$FIXTURE_FILE"
    seed_source_index "$SECOND_SOURCE_INDEX" "$FIXTURE_FILE"
    create_restricted_key "$SOURCE_INDEX" "$SECOND_SOURCE_INDEX"
    prime_local_node_key
    obtain_target_envelope
    track_flapjack_target "$TARGET_INDEX"

    payload="$(secure_temp_file)"
    write_job_payload "$payload" create "$SOURCE_INDEX"
    submit_job_payload "$payload" "$IDEMPOTENCY_KEY" "202" || finish_action_required "inconclusive_evidence"
    parse_current_job_response

    submit_job_payload "$payload" "$IDEMPOTENCY_KEY" "202" || finish_accepted_job_action_required "inconclusive_evidence"
    track_current_job_response
    replay_id="$PARSED_JOB_ID"
    replay_location="$PARSED_JOB_LOCATION"
    [ "$replay_id" = "$JOB_ID" ] || finish_accepted_job_action_required "inconclusive_evidence"
    [ "$replay_location" = "$JOB_LOCATION" ] || finish_accepted_job_action_required "inconclusive_evidence"
    emit_phase "idempotency_replay" "same_job_and_location" "same_job_and_location" "true"

    changed_payload="$(secure_temp_file)"
    write_job_payload "$changed_payload" create "$SECOND_SOURCE_INDEX"
    submit_job_payload "$changed_payload" "$IDEMPOTENCY_KEY" "409" || finish_accepted_job_action_required "inconclusive_evidence"
    conflict_code="$(json_field "$HTTP_BODY" code 2>/dev/null || true)"
    [ "$conflict_code" = "destination_conflict" ] || finish_accepted_job_action_required "inconclusive_evidence"
    emit_phase "idempotency_conflict" "changed_body_409_destination_conflict" "changed_body_409_destination_conflict" "true"

    source_count="$(idempotency_source_unchanged_count || true)"
    key_count="$(idempotency_key_row_count || true)"
    [ "$source_count" = "1" ] || finish_accepted_job_action_required "inconclusive_evidence"
    [ "$key_count" = "1" ] || finish_accepted_job_action_required "inconclusive_evidence"
    poll_job_to_terminal finish_accepted_job_action_required
    require_engine_acknowledged finish_accepted_job_action_required
    terminal_count="$(idempotency_terminal_job_count || true)"
    [ "$terminal_count" = "1" ] || finish_action_required "inconclusive_evidence"
    emit_phase "idempotency_db" "source_unchanged,row_count=1,terminal_jobs=1" "source_unchanged,row_count=1,terminal_jobs=1" "true"
    run_parity_oracle "$FIXTURE_FILE" "$TARGET_INDEX" "idempotency_parity" "3" "doc-1,doc-2,doc-3"
}

# Observe a non-terminal public status for the current job, proving cancellation
# is requested while the retained job is still live. Any accepted job that failed
# to reach this state is drained before cleanup rather than orphaned.
observe_nonterminal_status() {
    CURRENT_STEP="observe_nonterminal"
    local status
    api_request "200" GET "/migration/algolia/jobs/$JOB_ID" "" "" || finish_accepted_job_action_required "inconclusive_evidence"
    status="$(json_field "$HTTP_BODY" status 2>/dev/null || true)"
    is_nonterminal_status "$status" || finish_accepted_job_action_required "inconclusive_evidence"
}

# POST {} to the cancel route twice through the shared api_request helper: the
# first must be 202 and the replay 200, both for the same public job id with an
# unchanged, non-null cancelRequestedAt.
request_cancel_twice() {
    CURRENT_STEP="cancel"
    local payload first_id first_at replay_id replay_at
    payload="$(secure_temp_file)"
    write_json_file "$payload" '{}'
    api_request "202" POST "/migration/algolia/jobs/$JOB_ID/cancel" "$payload" "" \
        || finish_accepted_job_action_required "inconclusive_evidence"
    set_job_terminal_kind "$JOB_ID" cancelled_unchanged
    first_id="$(json_field "$HTTP_BODY" id 2>/dev/null || true)"
    first_at="$(json_field "$HTTP_BODY" cancelRequestedAt 2>/dev/null || true)"
    [ "$first_id" = "$JOB_ID" ] || finish_accepted_job_action_required "inconclusive_evidence"
    [ -n "$first_at" ] || finish_accepted_job_action_required "inconclusive_evidence"
    api_request "200" POST "/migration/algolia/jobs/$JOB_ID/cancel" "$payload" "" \
        || finish_accepted_job_action_required "inconclusive_evidence"
    replay_id="$(json_field "$HTTP_BODY" id 2>/dev/null || true)"
    replay_at="$(json_field "$HTTP_BODY" cancelRequestedAt 2>/dev/null || true)"
    [ "$replay_id" = "$JOB_ID" ] || finish_accepted_job_action_required "inconclusive_evidence"
    [ "$replay_at" = "$first_at" ] || finish_accepted_job_action_required "inconclusive_evidence"
    emit_phase "cancel_partial_replay" "first_202_replay_200_same_job_stable_intent" "first_202_replay_200_same_job_stable_intent" "true"
}

# A cancelled create-into-fresh must publish zero customer-visible documents and
# reach the canonical cancelled+unchanged/ACK terminal, with exactly one durable
# cancel intent and one engine-linked job for the phase.
run_cancel_partial() {
    local cancel_intent engine_linked customer_count
    ensure_probe_session
    select_phase_indexes cancel_partial
    seed_source_index "$SOURCE_INDEX" "$FIXTURE_FILE"
    create_restricted_key "$SOURCE_INDEX"
    prime_local_node_key
    obtain_target_envelope
    track_flapjack_target "$TARGET_INDEX"
    dispatch_job create "$SOURCE_INDEX" "$IDEMPOTENCY_KEY"

    observe_nonterminal_status
    request_cancel_twice
    poll_job_to_terminal
    require_engine_acknowledged

    cancel_intent="$(cancel_intent_count || true)"
    engine_linked="$(cancel_phase_engine_linked_count || true)"
    [ "$cancel_intent" = "1" ] || finish_action_required "inconclusive_evidence"
    [ "$engine_linked" = "1" ] || finish_action_required "inconclusive_evidence"
    emit_phase "cancel_partial_intent" "linked_job=1,cancel_intent=1" "linked_job=${engine_linked},cancel_intent=${cancel_intent}" "true"

    customer_visible_target_count "$TARGET_INDEX" || finish_action_required "inconclusive_evidence"
    customer_count="$CUSTOMER_VISIBLE_TARGET_COUNT"
    [ "$customer_count" = "0" ] || finish_action_required "parity_mismatch"
    emit_phase "cancel_partial" "cancelled_unchanged,resumable=false,customer_visible=0" "cancelled_unchanged,resumable=false,customer_visible=${customer_count}" "true"
}

# resume stays advertised false: a completed, acknowledged, non-resumable job
# must refuse resume with 409/not_resumable and mutate no lifecycle generation,
# checkpoint, or job count.
run_resume_refused() {
    local resumable pre_generation post_generation pre_job_count post_job_count resume_status resume_code payload
    ensure_probe_session
    select_phase_indexes resume_refused
    seed_source_index "$SOURCE_INDEX" "$FIXTURE_FILE"
    create_restricted_key "$SOURCE_INDEX"
    prime_local_node_key
    obtain_target_envelope
    track_flapjack_target "$TARGET_INDEX"
    dispatch_job create "$SOURCE_INDEX" "$IDEMPOTENCY_KEY"
    poll_job_to_terminal
    require_engine_acknowledged

    require_enabled_availability_exact

    api_request "200" GET "/migration/algolia/jobs/$JOB_ID" "" "" || finish_action_required "inconclusive_evidence"
    resumable="$(json_field "$HTTP_BODY" resumable 2>/dev/null || true)"
    [ "$resumable" = "false" ] || finish_action_required "inconclusive_evidence"

    pre_generation="$(resume_lifecycle_generation || true)"
    pre_job_count="$(resume_phase_job_count || true)"

    CURRENT_STEP="resume"
    payload="$(secure_temp_file)"
    write_json_file "$payload" "{\"apiKey\":\"$DISPOSABLE_KEY\"}"
    api_request "409" POST "/migration/algolia/jobs/$JOB_ID/resume" "$payload" "" \
        || finish_action_required "inconclusive_evidence"
    resume_status="$HTTP_STATUS"
    resume_code="$(json_field "$HTTP_BODY" code 2>/dev/null || true)"
    [ "$resume_status" = "409" ] || finish_action_required "inconclusive_evidence"
    [ "$resume_code" = "not_resumable" ] || finish_action_required "inconclusive_evidence"

    post_generation="$(resume_lifecycle_generation || true)"
    post_job_count="$(resume_phase_job_count || true)"
    [ -n "$pre_generation" ] || finish_action_required "inconclusive_evidence"
    [ "$post_generation" = "$pre_generation" ] || finish_action_required "inconclusive_evidence"
    [ "$pre_job_count" = "1" ] || finish_action_required "inconclusive_evidence"
    [ "$post_job_count" = "1" ] || finish_action_required "inconclusive_evidence"
    emit_phase "resume_refused" "409_not_resumable,resumable=false,generation_unchanged,job_count=1" "409_not_resumable,resumable=false,generation_unchanged,job_count=1" "true"
}

# Any phase set that includes overwrite_rerun must establish the replace surface
# is live before running ANY phase, so an earlier phase (e.g. idempotency) cannot
# seed Algolia or accept a job only to discover replace is unavailable afterward.
preflight_requested_phases() {
    local IFS=',' phase
    for phase in $REQUESTED_PHASES; do
        if [ "$phase" = "overwrite_rerun" ]; then
            ensure_probe_session
            require_replace_capability
            return 0
        fi
    done
}

run_requested_phases() {
    local IFS=',' phase
    preflight_requested_phases
    for phase in $REQUESTED_PHASES; do
        case "$phase" in
            create_into_fresh) run_create_into_fresh ;;
            overwrite_rerun) run_overwrite_rerun ;;
            idempotency) run_idempotency ;;
            cancel_partial) run_cancel_partial ;;
            resume_refused) run_resume_refused ;;
            *) finish_action_required "invalid_phases" ;;
        esac
    done
}
