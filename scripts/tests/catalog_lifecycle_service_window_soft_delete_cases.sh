#!/usr/bin/env bash

SOFT_DELETE_WRITER_REPO="catalog_writer__infra_api_src_repos_pg_customer_repo_lifecycle__soft_delete__pg_customer_repo_soft_delete"
SOFT_DELETE_WRITER_ACCOUNT="catalog_writer__infra_api_src_routes_account__delete_account__customer_repo_soft_delete"
SOFT_DELETE_WRITER_ADMIN="catalog_writer__infra_api_src_routes_admin_tenants__delete_tenant__customer_repo_soft_delete"
SOFT_DELETE_STALE_STATUS_KEYS=(
  stale_new_admission_status
  stale_replay_admission_status
  stale_cancel_status
  stale_resume_status
  stale_elapsed_resume_claim_status
  stale_state_update_status
  stale_terminal_ack_status
  stale_terminal_finalization_status
  stale_retention_gc_status
  stale_active_reservation_status
  stale_resume_intent_status
)
SOFT_DELETE_TRANSITION_EVIDENCE_KEYS=(
  soft_delete_account_transition
  soft_delete_admin_transition
)

assert_stdout_occurrences() {
  local needle="$1"
  local expected="$2"
  local msg="$3"
  local actual

  actual="$(RUN_STDOUT="$RUN_STDOUT" NEEDLE="$needle" python3 - <<'PY'
import os
print(os.environ["RUN_STDOUT"].count(os.environ["NEEDLE"]))
PY
  )"
  assert_eq "$actual" "$expected" "$msg"
}

assert_stdout_order() {
  local first_pattern="$1"
  local second_pattern="$2"
  local msg="$3"
  local first_line second_line

  first_line="$(printf '%s\n' "$RUN_STDOUT" | grep -n -m 1 -- "$first_pattern" | cut -d: -f1 || true)"
  second_line="$(printf '%s\n' "$RUN_STDOUT" | grep -n -m 1 -- "$second_pattern" | cut -d: -f1 || true)"
  if [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ]; then
    pass "$msg"
  else
    fail "$msg (first='$first_line' second='$second_line')"
  fi
}

soft_delete_generation_fence_has_public_success_contract() {
  local payload="$1"
  local parse_rc

  PAYLOAD="$payload" \
  SOFT_DELETE_WRITER_REPO="$SOFT_DELETE_WRITER_REPO" \
  SOFT_DELETE_WRITER_ACCOUNT="$SOFT_DELETE_WRITER_ACCOUNT" \
  SOFT_DELETE_WRITER_ADMIN="$SOFT_DELETE_WRITER_ADMIN" \
    python3 - <<'PY'
import json
import os

payload = os.environ["PAYLOAD"]
lines = [line for line in payload.splitlines() if line.strip()]
marker = "soft_delete_generation_fence=passed"
if lines.count(marker) != 1 or lines[-1] != marker:
    raise SystemExit(1)
if "soft_delete_generation_fence=failed" in payload:
    raise SystemExit(1)
evidence_lines = [line for line in lines if line.startswith("{") and "selected_evidence" in line]
if len(evidence_lines) != 1:
    raise SystemExit(1)
evidence = json.loads(evidence_lines[0])
required = {
    "status": "pass",
    "inventory": "scripts/tests/fixtures/catalog_lifecycle_writers.json",
    "oracle": "scripts/tests/fixtures/catalog_lifecycle_acceptance_oracles.json",
    "prohibited_engine_observations": 0,
    "soft_delete_account_route_status": "deleted",
    "soft_delete_admin_route_status": "deleted",
    "soft_delete_account_hidden_target": "hidden",
    "soft_delete_admin_hidden_target": "hidden",
    "expired_worker_claim_route_status": "destination_conflict",
    "expired_worker_claim_service_status": "destination_conflict",
    "stale_new_admission_status": "destination_changed",
    "stale_replay_admission_status": "destination_changed",
    "stale_cancel_status": "cancel_not_permitted",
    "stale_resume_status": "not_resumable",
    "stale_elapsed_resume_claim_status": "excluded",
    "stale_state_update_status": "conflict",
    "stale_terminal_ack_status": "excluded",
    "stale_terminal_finalization_status": "conflict",
    "stale_retention_gc_status": "excluded",
    "stale_active_reservation_status": "excluded",
    "stale_resume_intent_status": "conflict",
}
for key, expected in required.items():
    if evidence.get(key) != expected:
        raise SystemExit(1)
expected_customer_states = {
    "before_customer": {"deleted_at": None, "lifecycle_generation": 5, "status": "active"},
    "first_delete_customer": {
        "deleted_at": "2026-01-01T00:00:00.000000Z",
        "lifecycle_generation": 6,
        "status": "deleted",
    },
    "repeat_delete_customer": {
        "deleted_at": "2026-01-01T00:00:00.000000Z",
        "lifecycle_generation": 6,
        "status": "deleted",
    },
}
expected_retained_evidence = {
    "catalog": {
        "customer_id": "sd-customer",
        "deployment_id": "sd-deployment",
        "service_type": "flapjack",
        "tenant_id": "sd-index",
        "tier": "active",
        "vm_id": "sd-vm",
    },
    "import_operation": {
        "dispatch_intent_state": "committed",
        "engine_ack_state": "acknowledged",
        "id": "sd-job",
        "lifecycle_generation": 5,
        "logical_target": "sd-index",
        "publication_disposition": "promoted",
        "reserved_index_count": 1,
        "status": "completed",
    },
    "routing": {
        "deployment_flapjack_url": "http://127.0.0.1:37801",
        "deployment_id": "sd-deployment",
        "deployment_status": "running",
        "vm_id": "sd-vm",
        "vm_status": "active",
    },
}
for key in ("soft_delete_account_transition", "soft_delete_admin_transition"):
    transition = evidence.get(key)
    if not isinstance(transition, dict):
        raise SystemExit(1)
    for state_key, expected_state in expected_customer_states.items():
        if transition.get(state_key) != expected_state:
            raise SystemExit(1)
    for retained_key in (
        "before_retained_evidence",
        "first_delete_retained_evidence",
        "repeat_delete_retained_evidence",
    ):
        if transition.get(retained_key) != expected_retained_evidence:
            raise SystemExit(1)
    if transition.get("first_delete_retained_evidence_unchanged") is not True:
        raise SystemExit(1)
    if transition.get("repeat_delete_retained_evidence_unchanged") is not True:
        raise SystemExit(1)
PY
  parse_rc=$?
  [ "$parse_rc" -eq 0 ] || return "$parse_rc"
  service_window_success_payload_has_public_contract "$payload"
}

assert_soft_delete_verdict_contract_rejects() {
  local payload="$1"
  local msg="$2"

  soft_delete_generation_fence_has_public_success_contract "$payload" \
    && fail "$msg" \
    || pass "$msg"
}

mutate_inventory() {
  local target="$1"
  local mutation="$2"

  python3 "$REPO_ROOT/scripts/tests/fixtures/catalog_lifecycle_inventory_mutator.py" \
    "$DEFAULT_INVENTORY" "$target" "$mutation"
}

assert_inventory_mutation_fails() {
  local mutation="$1"
  local expected="$2"
  local msg="$3"
  local bad_inventory

  setup_workspace
  bad_inventory="$WORK_DIR/fixtures/${mutation//:/_}.json"
  mutate_inventory "$bad_inventory" "$mutation"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" \
    --inventory "$bad_inventory"

  assert_eq "$RUN_EXIT_CODE" "1" "$msg"
  assert_contains "$RUN_STDOUT" "$expected" "$msg names the failed denominator invariant"
}

test_soft_delete_inventory_denominator_success_contract() {
  setup_workspace

  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "0" "soft-delete denominator baseline should pass"
  assert_contains "$RUN_STDOUT" "\"inventory\":\"scripts/tests/fixtures/catalog_lifecycle_writers.json\"" \
    "soft-delete evidence reports the canonical inventory display path"
  assert_stdout_occurrences "$SOFT_DELETE_WRITER_REPO" "1" \
    "repository soft-delete writer ID appears exactly once"
  assert_stdout_occurrences "$SOFT_DELETE_WRITER_ACCOUNT" "1" \
    "account route soft-delete writer ID appears exactly once"
  assert_stdout_occurrences "$SOFT_DELETE_WRITER_ADMIN" "1" \
    "admin tenant route soft-delete writer ID appears exactly once"
  assert_stdout_occurrences "soft_delete_generation_fence=passed" "1" \
    "soft-delete final verdict marker appears exactly once"
  assert_contains "$RUN_STDOUT" "\"prohibited_engine_observations\":0" \
    "soft-delete evidence includes the explicit zero engine-observer count"
  soft_delete_generation_fence_has_public_success_contract "$RUN_STDOUT" \
    && pass "soft-delete success output satisfies the public verdict contract" \
    || fail "soft-delete success output satisfies the public verdict contract"
  assert_stdout_order "\"expired_worker_claim_service_status\":\"destination_conflict\"" \
    "soft_delete_generation_fence=passed" \
    "soft-delete verdict is emitted after structured evidence"
}

test_soft_delete_inventory_denominator_mutations_fail_closed() {
  for label in repo account admin; do
    assert_inventory_mutation_fails "remove:$label" "missing F5P1 soft-delete writers" \
      "missing $label soft-delete writer should fail"
    assert_inventory_mutation_fails "duplicate:$label" "expected exactly one F5P1 soft-delete writer" \
      "duplicate $label soft-delete writer should fail"
    assert_inventory_mutation_fails "wrong_disposition:$label" "missing F5P1 soft-delete writers" \
      "wrong $label soft-delete disposition should fail"
    assert_inventory_mutation_fails "wrong_owner:$label" "missing F5P1 soft-delete writers" \
      "wrong $label soft-delete owner should fail"
    assert_inventory_mutation_fails "wrong_anchor:$label" "missing F5P1 soft-delete writers" \
      "wrong $label soft-delete anchor should fail"
  done
  assert_inventory_mutation_fails "extra_matching_soft_delete" \
    "expected exactly one F5P1 soft-delete writer" \
    "extra matching soft-delete writer should fail"

  setup_workspace
  local copied_inventory="$WORK_DIR/fixtures/copied_inventory.json"
  cp "$DEFAULT_INVENTORY" "$copied_inventory"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack" \
    --inventory "$copied_inventory"
  assert_eq "$RUN_EXIT_CODE" "1" "non-canonical inventory path should fail"
  assert_contains "$RUN_STDOUT" "canonical inventory path" \
    "non-canonical inventory path failure is explicit"
}

test_soft_delete_observer_and_verdict_mutations_fail_closed() {
  setup_workspace
  rm -f "$WORK_DIR/observed-callers.json"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "missing observed-callers artifact should fail"
  assert_contains "$RUN_STDOUT" "observed callers artifact missing" \
    "missing observer artifact failure is explicit"

  setup_workspace
  printf '{not-json\n' > "$WORK_DIR/observed-callers.json"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "malformed observed-callers artifact should fail"
  assert_contains "$RUN_STDOUT" "observed callers artifact is not structured JSON" \
    "malformed observer artifact failure is explicit"

  setup_workspace
  printf '{"status":"observed","callers":[]}\n' > "$WORK_DIR/observed-callers.json"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "absent observer checks window should fail"
  assert_contains "$RUN_STDOUT" "observed callers artifact reports skipped or unchecked state" \
    "absent observer checks window failure is explicit"

  setup_workspace
  printf '{"status":"observed","callers":[],"checks":{}}\n' > "$WORK_DIR/observed-callers.json"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "empty observer checks window should fail"
  assert_contains "$RUN_STDOUT" "observed callers artifact reports skipped or unchecked state" \
    "empty observer checks window failure is explicit"

  setup_workspace
  printf '{"status":"observed","callers":[],"checks":{"extra":"checked"}}\n' > "$WORK_DIR/observed-callers.json"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "unknown-only observer checks window should fail"
  assert_contains "$RUN_STDOUT" "observed callers artifact reports skipped or unchecked state" \
    "unknown-only observer checks window failure is explicit"

  setup_workspace
  printf '{"status":"observed","callers":[],"checks":{"identity":"checked","auth":"skipped","status":"checked"}}\n' > "$WORK_DIR/observed-callers.json"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "unchecked observer window should fail"
  assert_contains "$RUN_STDOUT" "observed callers artifact reports skipped or unchecked state" \
    "unchecked observer window failure is explicit"

  setup_workspace
  printf '{"status":"observed","checks":{"identity":"checked","auth":"checked","status":"checked"}}\n' > "$WORK_DIR/observed-callers.json"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "missing callers array should fail"
  assert_contains "$RUN_STDOUT" "observed callers artifact missing callers array" \
    "missing callers array failure is explicit"

  setup_workspace
  printf '{"status":"observed","callers":[null],"checks":{"identity":"checked","auth":"checked","status":"checked"}}\n' > "$WORK_DIR/observed-callers.json"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "malformed caller row should fail"
  assert_contains "$RUN_STDOUT" "observed callers artifact has malformed caller rows" \
    "malformed caller row failure is explicit"

  setup_workspace
  printf '{"status":"observed","callers":[{"observed_upstream_kind":"physical_uid"}],"checks":{"identity":"checked","auth":"checked","status":"checked"}}\n' > "$WORK_DIR/observed-callers.json"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "1" "caller row missing caller_id should fail"
  assert_contains "$RUN_STDOUT" "observed callers artifact has malformed caller rows" \
    "caller row missing caller_id failure is explicit"

  setup_workspace
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "0" "soft-delete verdict mutation baseline should pass"

  local duplicate_marker early_marker false_marker false_status missing_engine_count
  local omitted_engine_count missing_preceding_evidence
  duplicate_marker="$(printf '%s\n%s\n' "$RUN_STDOUT" "soft_delete_generation_fence=passed")"
  early_marker="$(RUN_STDOUT="$RUN_STDOUT" python3 - <<'PY'
import os
lines = [line for line in os.environ["RUN_STDOUT"].splitlines() if line.strip()]
lines.remove("soft_delete_generation_fence=passed")
print("\n".join(["soft_delete_generation_fence=passed", *lines]))
PY
  )"
  false_marker="$(printf '%s\n' "$RUN_STDOUT" | sed 's/soft_delete_generation_fence=passed/soft_delete_generation_fence=failed/')"
  false_status="$(printf '%s\n' "$RUN_STDOUT" | sed 's/"status":"pass"/"status":"fail"/')"
  missing_engine_count="$(printf '%s\n' "$RUN_STDOUT" | sed 's/"prohibited_engine_observations":0/"prohibited_engine_observations":1/')"
  omitted_engine_count="$(printf '%s\n' "$RUN_STDOUT" | sed 's/"prohibited_engine_observations":0,//')"
  missing_preceding_evidence="$(printf '%s\n' "$RUN_STDOUT" | grep -v '"selected_evidence"' || true)"

  assert_soft_delete_verdict_contract_rejects "$duplicate_marker" \
    "duplicated soft-delete success marker should fail"
  assert_soft_delete_verdict_contract_rejects "$early_marker" \
    "early soft-delete success marker should fail"
  assert_soft_delete_verdict_contract_rejects "$false_marker" \
    "false soft-delete verdict marker should fail"
  assert_soft_delete_verdict_contract_rejects "$false_status" \
    "false structured soft-delete status should fail"
  assert_soft_delete_verdict_contract_rejects "$missing_engine_count" \
    "nonzero prohibited engine observation count should fail"
  assert_soft_delete_verdict_contract_rejects "$omitted_engine_count" \
    "omitted prohibited engine observation count should fail"
  assert_soft_delete_verdict_contract_rejects "$missing_preceding_evidence" \
    "missing structured soft-delete evidence should fail"

  local key missing_transition
  for key in "${SOFT_DELETE_TRANSITION_EVIDENCE_KEYS[@]}"; do
    missing_transition="$(RUN_STDOUT="$RUN_STDOUT" TRANSITION_KEY="$key" python3 - <<'PY'
import json
import os

lines = os.environ["RUN_STDOUT"].splitlines()
for idx, line in enumerate(lines):
    if line.startswith("{") and "selected_evidence" in line:
        evidence = json.loads(line)
        evidence.pop(os.environ["TRANSITION_KEY"], None)
        lines[idx] = json.dumps(evidence, separators=(",", ":"), sort_keys=True)
        break
print("\n".join(lines))
PY
    )"
    assert_soft_delete_verdict_contract_rejects "$missing_transition" \
      "public verdict without ${key} should fail"
  done
}

assert_soft_delete_fence_mutation_fails() {
  local mutation_env="$1"
  local expected="$2"
  local msg="$3"

  setup_workspace
  export "${mutation_env}=1"
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  unset "$mutation_env"

  assert_eq "$RUN_EXIT_CODE" "1" "$msg"
  assert_contains "$RUN_STDOUT" "$expected" "$msg names the failed invariant"
}

test_soft_delete_generation_fence_transition_contract() {
  setup_workspace

  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "0" "soft-delete generation-fence transition baseline should pass"
  local curl_log
  curl_log="$(cat "$WORK_DIR/curl.log")"
  assert_contains "$curl_log" "http://localhost:38101/account" \
    "probe drives deletion through the real account route"
  assert_contains "$curl_log" "/admin/tenants/dddddddd-dddd-dddd-dddd-dddddddddda2" \
    "probe drives deletion through the real admin tenant route"
  assert_contains "$(cat "$WORK_DIR/psql.log")" "catalog_service_window_soft_delete_seed" \
    "probe seeds a dedicated generation-G customer with retained evidence"
  local soft_delete_seed_sql
  soft_delete_seed_sql="$(
    python3 - "$WORK_DIR/psql.log" <<'PY'
import sys

payload = open(sys.argv[1], encoding="utf-8").read()
blocks = payload.split("\nPSQL ")
for block in blocks:
    if "catalog_service_window_soft_delete_seed" in block:
        print(block)
        break
PY
  )"
  assert_contains "$soft_delete_seed_sql" "destination_deployment_id" \
    "soft-delete retained import job seed includes replace destination deployment identity"
  assert_contains "$soft_delete_seed_sql" "catalog-service-window-sd-node-" \
    "soft-delete deployment node_id derives from customer_id to avoid UNIQUE collision across arms"
  assert_contains "$soft_delete_seed_sql" "engine_job_id" \
    "soft-delete retained import job seed includes acknowledged engine job identity"
  assert_contains "$RUN_STDOUT" "\"soft_delete_account_route_status\":\"deleted\"" \
    "account route soft-delete drives the generation fence to deleted"
  assert_contains "$RUN_STDOUT" "\"soft_delete_admin_route_status\":\"deleted\"" \
    "admin route soft-delete drives the generation fence to deleted"
  assert_contains "$RUN_STDOUT" "\"soft_delete_account_hidden_target\":\"hidden\"" \
    "account arm proves the retained target stays hidden after deletion"
  assert_contains "$RUN_STDOUT" "\"soft_delete_admin_hidden_target\":\"hidden\"" \
    "admin arm proves the retained target stays hidden after deletion"
  local event_log
  event_log="$(cat "$WORK_DIR/events.log")"
  assert_not_contains "$event_log" "http://127.0.0.1:37801/1/indexes/catalog_service_window_source_soft_delete" \
    "refused hidden-target mutations produce no physical engine dispatch"
  assert_stdout_order "\"soft_delete_admin_hidden_target\":\"hidden\"" \
    "soft_delete_generation_fence=passed" \
    "generation-fence transition evidence is emitted before the verdict"
}

test_soft_delete_stale_operation_matrix_contract() {
  setup_workspace

  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"

  assert_eq "$RUN_EXIT_CODE" "0" "soft-delete stale-operation matrix baseline should pass"
  local curl_log psql_log event_log
  curl_log="$(cat "$WORK_DIR/curl.log")"
  psql_log="$(cat "$WORK_DIR/psql.log")"
  event_log="$(cat "$WORK_DIR/events.log")"
  assert_contains "$curl_log" "/migration/algolia/destination-eligibility" \
    "stale matrix drives the route-backed destination eligibility seam"
  assert_contains "$curl_log" "/migration/algolia/jobs" \
    "stale matrix drives the route-backed import admission seam"
  assert_contains "$curl_log" "/migration/algolia/jobs/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa02/cancel" \
    "stale matrix drives the route-backed cancel seam"
  assert_contains "$curl_log" "/migration/algolia/jobs/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaa03/resume" \
    "stale matrix drives the route-backed resume seam"
  assert_contains "$psql_log" "catalog_service_window_soft_delete_stale_matrix_seed" \
    "stale matrix seeds a deleted generation-mismatched operation fixture"
  local stale_seed_sql
  stale_seed_sql="$(
    python3 - "$WORK_DIR/psql.log" <<'PY'
import sys
payload = open(sys.argv[1], encoding="utf-8").read()
blocks = payload.split("\nPSQL ")
for block in blocks:
    if "catalog_service_window_soft_delete_stale_matrix_seed" in block:
        print(block)
        break
PY
  )"
  assert_contains "$stale_seed_sql" "'replace', :'sd_index' || '-' || suffix" \
    "stale matrix logical_target derives from suffix to avoid partial unique index collision"
  assert_contains "$psql_log" "logical_target LIKE" \
    "stale matrix snapshot query matches per-suffix logical_targets via LIKE prefix"
  assert_contains "$psql_log" "catalog_service_window_soft_delete_stale_matrix_repo_probe" \
    "stale matrix exercises repository-selector refusal probes"
  assert_contains "$psql_log" "catalog_service_window_soft_delete_stale_matrix_snapshot" \
    "stale matrix compares retained database evidence after every attempt"
  for key in "${SOFT_DELETE_STALE_STATUS_KEYS[@]}"; do
    assert_contains "$RUN_STDOUT" "\"${key}\":" \
      "soft-delete public evidence includes ${key}"
  done
  assert_not_contains "$event_log" "soft_delete_stale_physical_dispatch" \
    "stale-operation refusals produce no physical engine dispatch"
  assert_stdout_order "\"stale_resume_intent_status\":\"conflict\"" \
    "soft_delete_generation_fence=passed" \
    "stale-operation evidence is emitted before the verdict"
}

test_soft_delete_hidden_target_mutations_fail_closed() {
  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_TARGET_VISIBLE" \
    "expected deleted-customer refusal" \
    "a visible retained target after deletion should fail"

  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_LEASE_MUTATION_ALLOWED" \
    "expected deleted-customer refusal" \
    "an accepted lease-guarded mutation on a deleted target should fail"
}

test_soft_delete_generation_fence_mutations_fail_closed() {
  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_BAD_FIRST_STATUS" \
    "soft delete fence first delete must set status=deleted" \
    "first delete that does not set status=deleted should fail"

  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_BAD_FIRST_GENERATION" \
    "soft delete fence first delete must advance generation to G + 1" \
    "first delete that does not advance generation to G + 1 should fail"

  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_MISSING_DELETED_AT" \
    "soft delete fence first delete must populate deleted_at" \
    "first delete without a populated deleted_at should fail"

  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_REPEAT_BUMP_GENERATION" \
    "soft delete fence repeat delete must not change generation" \
    "repeat delete that changes generation should fail"

  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_REPEAT_CHANGE_TIMESTAMP" \
    "soft delete fence repeat delete must not change deleted_at" \
    "repeat delete that changes deleted_at should fail"

  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_MISSING_EVIDENCE_ROW" \
    "soft delete fence snapshot missing import_operation row" \
    "missing retained import/reservation/dispatch-intent/ACK row should fail"

  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_MISSING_CATALOG_ROW" \
    "soft delete fence snapshot missing catalog row" \
    "missing retained catalog row should fail"

  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_MISSING_ROUTING_ROW" \
    "soft delete fence snapshot missing routing row" \
    "missing retained routing row should fail"

  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_MISSING_CUSTOMER_ROW" \
    "soft delete fence snapshot missing customer row" \
    "missing customer row should fail"

  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_MUTATE_RETAINED_EVIDENCE" \
    "soft delete fence first delete mutated retained evidence" \
    "any change to retained evidence across the delete should fail"
}

test_soft_delete_stale_operation_mutations_fail_closed() {
  local key upper expected

  for key in "${SOFT_DELETE_STALE_STATUS_KEYS[@]}"; do
    upper="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
    assert_soft_delete_fence_mutation_fails \
      "CATALOG_SERVICE_WINDOW_SOFT_DELETE_${upper}_ACCEPTED" \
      "soft delete stale operation ${key} expected" \
      "accepted ${key} should fail"
    assert_soft_delete_fence_mutation_fails \
      "CATALOG_SERVICE_WINDOW_SOFT_DELETE_${upper}_OMITTED" \
      "soft delete stale operation ${key} missing" \
      "omitted ${key} should fail"
  done

  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_STALE_MUTATE_RETAINED_EVIDENCE" \
    "soft delete stale operation retained evidence changed" \
    "stale-operation retained evidence drift should fail"

  assert_soft_delete_fence_mutation_fails \
    "CATALOG_SERVICE_WINDOW_SOFT_DELETE_STALE_ENGINE_CALL" \
    "soft delete stale operations produced engine observations" \
    "stale-operation physical engine dispatch should fail"

  setup_workspace
  run_probe --api-binary "$WORK_DIR/bin/api" --engine-binary "$WORK_DIR/bin/flapjack"
  assert_eq "$RUN_EXIT_CODE" "0" "soft-delete stale verdict mutation baseline should pass"
  for key in "${SOFT_DELETE_STALE_STATUS_KEYS[@]}"; do
    expected="$(RUN_STDOUT="$RUN_STDOUT" STALE_KEY="$key" python3 - <<'PY'
import json
import os

lines = os.environ["RUN_STDOUT"].splitlines()
for idx, line in enumerate(lines):
    if line.startswith("{") and "selected_evidence" in line:
        evidence = json.loads(line)
        evidence.pop(os.environ["STALE_KEY"], None)
        lines[idx] = json.dumps(evidence, separators=(",", ":"), sort_keys=True)
        break
print("\n".join(lines))
PY
    )"
    assert_soft_delete_verdict_contract_rejects "$expected" \
      "public verdict without ${key} should fail"
  done
}

test_soft_delete_integration_up_enables_algolia_migration() {
  local integration_block
  integration_block="$(sed -n '/START_STACK.*1/,/integration-up/p' "$TARGET_SCRIPT")"
  assert_contains "$integration_block" "FJCLOUD_ALGOLIA_MIGRATION_ENABLED=true" \
    "integration-up must enable algolia migration so destination-eligibility route accepts requests"
}
