#!/usr/bin/env bash
# Execute-path and polling failure contracts extracted from the main unit harness.

# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
# TODO: Document assert_json_top_level_field_equals.
assert_json_top_level_field_equals() {
  local json_path="$1"
  local field_name="$2"
  local expected_json="$3"
  local label="$4"
  local output=""
  local status=0
  local actual_json=""
  local normalized_expected_json=""

  output="$(
    python3 - "$json_path" "$field_name" "$expected_json" <<'PY'
import json
import sys

path = sys.argv[1]
field_name = sys.argv[2]
expected = json.loads(sys.argv[3])
with open(path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

if field_name not in payload:
    print("__MISSING_KEY__")
    print(json.dumps(expected))
    sys.exit(2)

actual = payload[field_name]
print(json.dumps(actual))
print(json.dumps(expected))
sys.exit(0 if actual == expected else 1)
PY
  )" || status=$?

  if [[ "$status" -eq 0 ]]; then
    pass "$label"
    return
  fi

  actual_json="$(printf '%s\n' "$output" | sed -n '1p')"
  normalized_expected_json="$(printf '%s\n' "$output" | sed -n '2p')"
  if [[ "$actual_json" == "__MISSING_KEY__" ]]; then
    fail "$label (missing required top-level key '$field_name')"
    return
  fi
  fail "$label (expected $normalized_expected_json, got $actual_json)"
}

echo ""
echo "--- successful live execute artifact truthfulness contract ---"
setup
run_wrapper --env RDS_RESTORE_DRILL_EXECUTE=1 -- staging --artifact-dir "$ARTIFACT_ROOT" --env-file "$WORK_DIR/inputs/env.secret" --execute --target-db-instance-id fjcloud-staging-restore-live
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "successful mocked live execute wrapper run exits 0"
else
  fail "successful mocked live execute wrapper run exits 0"
fi

run_dir="$(single_run_dir "$ARTIFACT_ROOT")"
if [[ -n "$run_dir" ]]; then
  pass "successful mocked live execute wrapper run writes one run directory"
else
  fail "successful mocked live execute wrapper run writes one run directory"
fi

if [[ -n "$run_dir" && -f "$run_dir/summary.json" ]]; then
  assert_json_top_level_field_equals "$run_dir/summary.json" "result" '"pass"' "successful mocked live execute summary result is pass"
  assert_json_top_level_field_equals "$run_dir/summary.json" "status" '"success"' "successful mocked live execute summary status is success"
  assert_json_top_level_field_equals "$run_dir/summary.json" "target_status" '"available"' "successful mocked live execute summary target_status is available"
  assert_json_top_level_field_equals "$run_dir/summary.json" "reason" 'null' "successful mocked live execute summary reason is null"
  assert_file_contains "$run_dir/summary.json" 'fjcloud-staging-restore-live\.\*\.us-east-1\.rds\.amazonaws\.com' "successful mocked live execute summary redacts RDS endpoint"
  assert_file_not_contains "$run_dir/summary.json" 'fjcloud-staging-restore-live\.cluster-contract\.us-east-1\.rds\.amazonaws\.com' "successful mocked live execute summary omits raw RDS endpoint"
else
  fail "successful mocked live execute writes summary artifact"
fi

if [[ -n "$run_dir" && -f "$run_dir/restore_request.json" ]]; then
  assert_json_top_level_field_equals "$run_dir/restore_request.json" "wrapper_execute" 'true' "successful mocked live execute restore_request records wrapper_execute=true"
  assert_json_top_level_field_equals "$run_dir/restore_request.json" "drill_execute_gate" '"1"' "successful mocked live execute restore_request records drill execute gate"
else
  fail "successful mocked live execute writes restore_request artifact"
fi

if [[ -n "$run_dir" && -f "$run_dir/verification.sql" ]]; then
  assert_verification_sql_matches_runbook "$run_dir/verification.sql" "$RUNBOOK_PATH" "successful mocked live execute verification.sql exactly matches canonical runbook SQL block"
else
  fail "successful mocked live execute writes verification.sql artifact"
fi

if [[ -n "$run_dir" && -f "$run_dir/verification.txt" ]]; then
  assert_file_contains "$run_dir/verification.txt" '^status=success$' "successful mocked live execute verification notes status success"
  assert_file_contains "$run_dir/verification.txt" '^result=pass$' "successful mocked live execute verification notes result pass"
  assert_file_contains "$run_dir/verification.txt" '^target_status=available$' "successful mocked live execute verification notes target status available"
  assert_file_contains "$run_dir/verification.txt" '^target_endpoint=fjcloud-staging-restore-live\.\*\.us-east-1\.rds\.amazonaws\.com$' "successful mocked live execute verification notes redact endpoint"
  assert_file_not_contains "$run_dir/verification.txt" 'fjcloud-staging-restore-live\.cluster-contract\.us-east-1\.rds\.amazonaws\.com' "successful mocked live execute verification notes omit raw endpoint"
else
  fail "successful mocked live execute writes verification notes artifact"
fi
teardown

echo ""
echo "--- non-executable delegate contract ---"
setup
chmod 0644 "$WORK_DIR/ops/scripts/rds_restore_drill.sh"
run_wrapper -- staging --artifact-dir "$ARTIFACT_ROOT" --env-file "$WORK_DIR/inputs/env.secret"
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "wrapper dry-run accepts a readable non-executable delegate script"
else
  fail "wrapper dry-run accepts a readable non-executable delegate script"
fi

run_dir="$(single_run_dir "$ARTIFACT_ROOT")"
if [[ -n "$run_dir" ]]; then
  pass "non-executable delegate dry-run still creates run-scoped artifact directory"
else
  fail "non-executable delegate dry-run still creates run-scoped artifact directory"
fi

if [[ -n "$run_dir" ]]; then
  assert_file_exists "$run_dir/summary.json" "non-executable delegate dry-run writes summary artifact"
  assert_file_exists "$run_dir/restore_request.json" "non-executable delegate dry-run writes restore_request artifact"
fi
teardown

echo ""
echo "--- live poll failure artifact contract ---"
setup
run_wrapper --env RDS_RESTORE_DRILL_EXECUTE=1 --env RDS_RESTORE_TEST_DISCOVERY_MODE=poll_describe_error -- staging --artifact-dir "$ARTIFACT_ROOT" --env-file "$WORK_DIR/inputs/env.secret" --execute --target-db-instance-id fjcloud-staging-restore-live
if [[ "$LAST_EXIT_CODE" -ne 0 ]]; then
  pass "live poll describe failures return non-zero"
else
  fail "live poll describe failures return non-zero"
fi

run_dir="$(single_run_dir "$ARTIFACT_ROOT")"
if [[ -n "$run_dir" ]]; then
  pass "live poll describe failures still create run-scoped directory"
else
  fail "live poll describe failures still create run-scoped directory"
fi

if [[ -n "$run_dir" ]]; then
  assert_file_exists "$run_dir/summary.json" "live poll describe failure still writes summary artifact"
  assert_file_exists "$run_dir/verification.sql" "live poll describe failure still writes verification.sql"
  assert_file_exists "$run_dir/verification.txt" "live poll describe failure still writes verification.txt"
  if [[ -f "$run_dir/summary.json" ]]; then
    assert_file_contains "$run_dir/summary.json" '"status"[[:space:]]*:[[:space:]]*"fail"' "live poll describe failure summary status is fail"
    assert_file_contains "$run_dir/summary.json" 'aws poll describe-db-instances failed' "live poll describe failure summary records AWS polling failure reason"
  fi
fi
teardown

setup
run_wrapper --env RDS_RESTORE_DRILL_EXECUTE=1 --env RDS_RESTORE_TEST_DISCOVERY_MODE=poll_invalid_json -- staging --artifact-dir "$ARTIFACT_ROOT" --env-file "$WORK_DIR/inputs/env.secret" --execute
if [[ "$LAST_EXIT_CODE" -ne 0 ]]; then
  pass "live poll invalid json failures return non-zero"
else
  fail "live poll invalid json failures return non-zero"
fi

run_dir="$(single_run_dir "$ARTIFACT_ROOT")"
if [[ -n "$run_dir" ]]; then
  pass "live poll invalid json failures still create run-scoped directory"
else
  fail "live poll invalid json failures still create run-scoped directory"
fi

if [[ -n "$run_dir" ]]; then
  assert_file_exists "$run_dir/summary.json" "live poll invalid json failure still writes summary artifact"
  assert_file_exists "$run_dir/verification.sql" "live poll invalid json failure still writes verification.sql"
  assert_file_exists "$run_dir/verification.txt" "live poll invalid json failure still writes verification.txt"
  if [[ -f "$run_dir/summary.json" ]]; then
    assert_file_contains "$run_dir/summary.json" '"status"[[:space:]]*:[[:space:]]*"fail"' "live poll invalid json failure summary status is fail"
    assert_file_contains "$run_dir/summary.json" 'failed to parse poll describe-db-instances payload for target' "live poll invalid json summary records parse failure reason"
  fi
  if [[ -f "$run_dir/verification.txt" ]]; then
    assert_file_contains "$run_dir/verification.txt" '^reason=failed to parse poll describe-db-instances payload for target' "live poll invalid json verification notes parse failure reason"
  fi
fi
teardown
