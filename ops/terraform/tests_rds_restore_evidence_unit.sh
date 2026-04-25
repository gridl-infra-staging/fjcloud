#!/usr/bin/env bash
# Red-phase contract tests for ops/scripts/rds_restore_evidence.sh.
# Stage 1 intentionally locks the behavior contract before wrapper implementation.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
EVIDENCE_SCRIPT_SOURCE="$ROOT_DIR/ops/scripts/rds_restore_evidence.sh"
SELECT_HELPER_SCRIPT_SOURCE="$ROOT_DIR/ops/scripts/lib/rds_restore_selection.py"
RUNBOOK_SOURCE="$ROOT_DIR/docs/runbooks/database-backup-recovery.md"

WORK_DIR=""
MOCK_BIN=""
MOCK_AWS_LOG=""
MOCK_DRILL_LOG=""
MOCK_DRILL_ENV_LOG=""
ARTIFACT_ROOT=""
UNSAFE_ENV_MARKER=""
LAST_OUTPUT=""
LAST_EXIT_CODE=0
DATE_COUNTER_FILE=""
RUNBOOK_PATH=""

setup() {
  WORK_DIR="$(mktemp -d)"
  MOCK_BIN="$WORK_DIR/bin"
  MOCK_AWS_LOG="$WORK_DIR/aws.log"
  MOCK_DRILL_LOG="$WORK_DIR/drill.log"
  MOCK_DRILL_ENV_LOG="$WORK_DIR/drill_env.log"
  ARTIFACT_ROOT="$WORK_DIR/artifacts"
  UNSAFE_ENV_MARKER="$WORK_DIR/unsafe_env_evaluated"
  DATE_COUNTER_FILE="$WORK_DIR/date_counter"

  mkdir -p "$WORK_DIR/ops/scripts/lib" "$MOCK_BIN" "$ARTIFACT_ROOT" "$WORK_DIR/inputs" "$WORK_DIR/tmp"
  mkdir -p "$WORK_DIR/docs/runbooks"
  : > "$MOCK_AWS_LOG"
  : > "$MOCK_DRILL_LOG"
  : > "$MOCK_DRILL_ENV_LOG"
  RUNBOOK_PATH="$WORK_DIR/docs/runbooks/database-backup-recovery.md"

  if [[ -f "$EVIDENCE_SCRIPT_SOURCE" ]]; then
    cp "$EVIDENCE_SCRIPT_SOURCE" "$WORK_DIR/ops/scripts/rds_restore_evidence.sh"
    chmod +x "$WORK_DIR/ops/scripts/rds_restore_evidence.sh"
  fi
  if [[ -f "$SELECT_HELPER_SCRIPT_SOURCE" ]]; then
    cp "$SELECT_HELPER_SCRIPT_SOURCE" "$WORK_DIR/ops/scripts/lib/rds_restore_selection.py"
    chmod +x "$WORK_DIR/ops/scripts/lib/rds_restore_selection.py"
  fi
  if [[ -f "$RUNBOOK_SOURCE" ]]; then
    cp "$RUNBOOK_SOURCE" "$RUNBOOK_PATH"
  fi

  cat > "$MOCK_BIN/aws" <<'AWSMOCK'
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${RDS_RESTORE_TEST_AWS_LOG:?}"
DISCOVERY_MODE="${RDS_RESTORE_TEST_DISCOVERY_MODE:-instance_ok}"
IS_TARGET_DESCRIBE=0

printf 'AWS_PAGER=%s | %s\n' "${AWS_PAGER-UNSET}" "$*" >> "$LOG_FILE"

if [[ "$1" == "rds" && "$2" == "describe-db-instances" ]]; then
  if [[ " $* " == *" --db-instance-identifier "* ]]; then
    IS_TARGET_DESCRIBE=1
  fi

  if [[ "$IS_TARGET_DESCRIBE" -eq 1 && "$DISCOVERY_MODE" == "poll_describe_error" ]]; then
    echo "mocked poll describe-db-instances failure" >&2
    exit 58
  fi

  if [[ "$IS_TARGET_DESCRIBE" -eq 1 && "$DISCOVERY_MODE" == "poll_invalid_json" ]]; then
    printf '%s\n' '{"DBInstances":['
    exit 0
  fi

  if [[ "$IS_TARGET_DESCRIBE" -eq 1 ]]; then
    target_id="$(printf '%s' "$*" | sed -n 's/.*--db-instance-identifier \([^ ]*\).*/\1/p')"
    cat <<JSON
{"DBInstances":[{"DBInstanceIdentifier":"$target_id","Engine":"postgres","DBInstanceStatus":"available","Endpoint":{"Address":"$target_id.cluster-contract.us-east-1.rds.amazonaws.com"}}]}
JSON
    exit 0
  fi

  if [[ "$DISCOVERY_MODE" == "instances_error" ]]; then
    echo "mocked describe-db-instances failure" >&2
    exit 42
  fi

  if [[ "$DISCOVERY_MODE" == "cluster_only" ]]; then
    cat <<'JSON'
{"DBInstances": []}
JSON
    exit 0
  fi

  if [[ "$DISCOVERY_MODE" == "missing_latest_restorable_time" || "$DISCOVERY_MODE" == "snapshot_fallback_mixed_sources" ]]; then
    cat <<'JSON'
{"DBInstances":[{"DBInstanceIdentifier":"fjcloud-staging","Engine":"postgres","DBInstanceStatus":"available","BackupRetentionPeriod":7,"Endpoint":{"Address":"fjcloud-staging.example.amazonaws.com"}}]}
JSON
    exit 0
  fi

  cat <<'JSON'
{"DBInstances":[{"DBInstanceIdentifier":"fjcloud-staging","Engine":"postgres","DBInstanceStatus":"available","BackupRetentionPeriod":7,"LatestRestorableTime":"2026-04-22T17:44:37Z","Endpoint":{"Address":"fjcloud-staging.example.amazonaws.com"}}]}
JSON
  exit 0
fi

if [[ "$1" == "rds" && "$2" == "describe-db-snapshots" ]]; then
  if [[ "$DISCOVERY_MODE" == "snapshots_invalid_json" ]]; then
    printf '%s\n' '{"DBSnapshots":['
    exit 0
  fi

  if [[ "$DISCOVERY_MODE" == "snapshot_fallback_mixed_sources" ]]; then
    cat <<'JSON'
{"DBSnapshots":[
  {"DBSnapshotIdentifier":"rds:fjcloud-staging-foreign-2026-04-22-06-00","DBInstanceIdentifier":"fjcloud-staging-foreign","SnapshotType":"automated","Status":"available","SnapshotCreateTime":"2026-04-22T06:00:00Z"},
  {"DBSnapshotIdentifier":"rds:fjcloud-staging-2026-04-22-02-00","DBInstanceIdentifier":"fjcloud-staging","SnapshotType":"automated","Status":"available","SnapshotCreateTime":"2026-04-22T02:00:00Z"},
  {"DBSnapshotIdentifier":"rds:fjcloud-staging-2026-04-22-05-00","DBInstanceIdentifier":"fjcloud-staging","SnapshotType":"automated","Status":"available","SnapshotCreateTime":"2026-04-22T05:00:00Z"}
]}
JSON
    exit 0
  fi

  if [[ "$DISCOVERY_MODE" == "no_snapshot" ]]; then
    cat <<'JSON'
{"DBSnapshots":[]}
JSON
    exit 0
  fi

  cat <<'JSON'
{"DBSnapshots":[{"DBSnapshotIdentifier":"rds:fjcloud-staging-2026-04-22-03-00","SnapshotType":"automated","Status":"available"}]}
JSON
  exit 0
fi

if [[ "$1" == "rds" && "$2" == "describe-db-clusters" ]]; then
  if [[ "$DISCOVERY_MODE" == "cluster_only" ]]; then
    cat <<'JSON'
{"DBClusters":[{"DBClusterIdentifier":"fjcloud-staging-cluster","Engine":"aurora-postgresql","Status":"available"}]}
JSON
    exit 0
  fi

  cat <<'JSON'
{"DBClusters":[]}
JSON
  exit 0
fi

if [[ "$1" == "rds" && ( "$2" == "restore-db-instance-from-db-snapshot" || "$2" == "restore-db-instance-to-point-in-time" ) ]]; then
  if [[ "${RDS_RESTORE_TEST_FORBID_RESTORE_API:-0}" == "1" ]]; then
    echo "restore API was forbidden in this test contract" >&2
    exit 99
  fi
  echo '{"DBInstance":{"DBInstanceStatus":"creating"}}'
  exit 0
fi

# default pass-through for non-contract calls
exit 0
AWSMOCK
  chmod +x "$MOCK_BIN/aws"

  cat > "$MOCK_BIN/date" <<'DATEMOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${RDS_RESTORE_TEST_FAKE_DATE_MODE:-}" == "fast_timeout" && "${1:-}" == "-u" && "${2:-}" == "+%s" ]]; then
  counter_file="${RDS_RESTORE_TEST_DATE_COUNTER_FILE:?}"
  if [[ ! -f "$counter_file" ]]; then
    printf '0\n' > "$counter_file"
  fi
  counter_value="$(cat "$counter_file")"
  if [[ "$counter_value" == "0" ]]; then
    printf '0\n'
    printf '1\n' > "$counter_file"
  else
    printf '1901\n'
  fi
  exit 0
fi

exec /bin/date "$@"
DATEMOCK
  chmod +x "$MOCK_BIN/date"

  cat > "$WORK_DIR/ops/scripts/rds_restore_drill.sh" <<'DRILLMOCK'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${RDS_RESTORE_TEST_DRILL_LOG:?}"
env | sort > "${RDS_RESTORE_TEST_DRILL_ENV_LOG:?}"

if [[ "${RDS_RESTORE_TEST_DRILL_EXIT_CODE:-0}" != "0" ]]; then
  echo "mocked rds_restore_drill failure" >&2
  exit "${RDS_RESTORE_TEST_DRILL_EXIT_CODE}"
fi

echo "Dry run: no restore API call dispatched."
echo "Command: aws rds restore-db-instance-to-point-in-time --region us-east-1 --source-db-instance-identifier fjcloud-staging --target-db-instance-identifier fjcloud-staging-restore --restore-time 2026-04-22T17:44:37Z"
DRILLMOCK
  chmod +x "$WORK_DIR/ops/scripts/rds_restore_drill.sh"

  cat > "$WORK_DIR/inputs/env.secret" <<'ENVFILE'
AWS_ACCESS_KEY_ID=AKIATESTCONTRACT
AWS_SECRET_ACCESS_KEY=test-contract-secret
AWS_SESSION_TOKEN=test-contract-session-token
AWS_DEFAULT_REGION=us-east-1
NOT_AWS_VAR=must_not_be_exported
ENVFILE

  cat > "$WORK_DIR/inputs/env_unsafe.secret" <<ENVUNSAFE
AWS_ACCESS_KEY_ID=AKIAUNSAFECONTRACT
AWS_SECRET_ACCESS_KEY=unsafe-contract-secret
AWS_SESSION_TOKEN=\$(echo shell_eval > "$UNSAFE_ENV_MARKER")
AWS_DEFAULT_REGION=us-east-1
ENVUNSAFE
}

teardown() {
  rm -rf "$WORK_DIR"
}

run_wrapper() {
  local cli=()
  local env_overrides=()
  local env_cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        env_overrides+=("$2")
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done
  cli=("$@")

  local exit_code=0
  local output=""
  env_cmd=(
    env -i
    "PATH=$MOCK_BIN:/usr/bin:/bin:/usr/local/bin"
    "HOME=$WORK_DIR"
    "TMPDIR=$WORK_DIR/tmp"
    "RDS_RESTORE_TEST_AWS_LOG=$MOCK_AWS_LOG"
    "RDS_RESTORE_TEST_DRILL_LOG=$MOCK_DRILL_LOG"
    "RDS_RESTORE_TEST_DRILL_ENV_LOG=$MOCK_DRILL_ENV_LOG"
    "RDS_RESTORE_TEST_DATE_COUNTER_FILE=$DATE_COUNTER_FILE"
  )
  if [[ "${#env_overrides[@]}" -gt 0 ]]; then
    env_cmd+=("${env_overrides[@]}")
  fi
  output=$(cd "$WORK_DIR" && "${env_cmd[@]}" bash "$WORK_DIR/ops/scripts/rds_restore_evidence.sh" "${cli[@]}" 2>&1) || exit_code=$?

  LAST_OUTPUT="$output"
  LAST_EXIT_CODE=$exit_code
}

run_selection_helper() {
  local instances_json="$1"
  local snapshots_json="$2"
  local clusters_json="$3"
  local source_id="$4"
  local target_id="$5"
  local snapshot_override="$6"
  local restore_time_override="$7"
  local output=""
  local exit_code=0
  output="$(
    cd "$WORK_DIR" && env -i \
      "PATH=$MOCK_BIN:/usr/bin:/bin:/usr/local/bin" \
      "HOME=$WORK_DIR" \
      "TMPDIR=$WORK_DIR/tmp" \
      python3 "$WORK_DIR/ops/scripts/lib/rds_restore_selection.py" \
      "$instances_json" \
      "$snapshots_json" \
      "$clusters_json" \
      "$source_id" \
      "$target_id" \
      "$snapshot_override" \
      "$restore_time_override" \
      "20260422174437" \
      2>&1
  )" || exit_code=$?

  LAST_OUTPUT="$output"
  LAST_EXIT_CODE=$exit_code
}

selection_output_field() {
  local row="$1"
  local field_name="$2"
  SELECTION_OUTPUT="$row" python3 - "$field_name" <<'PY'
import os
import sys

field_name = sys.argv[1]
fields = {
    "status": 0,
    "reason": 1,
    "source": 2,
    "target": 3,
    "restore_mode": 4,
    "snapshot_id": 5,
    "restore_time": 6,
}
parts = os.environ["SELECTION_OUTPUT"].split("\x1f")
print(parts[fields[field_name]] if len(parts) > fields[field_name] else "")
PY
}

assert_selection_field_equals() {
  local field_name="$1"
  local expected="$2"
  local label="$3"
  local actual=""
  actual="$(selection_output_field "$LAST_OUTPUT" "$field_name")"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '$actual')"
  fi
}

assert_output_contains() {
  local pattern="$1"
  local label="$2"
  if echo "$LAST_OUTPUT" | rg -q -- "$pattern"; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_output_not_contains() {
  local pattern="$1"
  local label="$2"
  if echo "$LAST_OUTPUT" | rg -q -- "$pattern"; then
    fail "$label"
  else
    pass "$label"
  fi
}

assert_log_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -q -- "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_log_not_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if rg -q -- "$pattern" "$file"; then
    fail "$label"
  else
    pass "$label"
  fi
}

assert_every_log_line_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  local nonmatching=""

  if [[ ! -s "$file" ]]; then
    fail "$label (log empty: $file)"
    return
  fi

  nonmatching="$(rg -n -v -- "$pattern" "$file" || true)"
  if [[ -n "$nonmatching" ]]; then
    fail "$label"
  else
    pass "$label"
  fi
}

single_run_dir() {
  local root="$1"
  local dirs=()
  local d
  for d in "$root"/*; do
    [[ -d "$d" ]] || continue
    dirs+=("$d")
  done
  if [[ "${#dirs[@]}" -eq 1 ]]; then
    printf '%s\n' "${dirs[0]}"
    return 0
  fi
  printf '\n'
  return 0
}

file_mode_octal() {
  local path="$1"
  python3 - "$path" <<'PY'
import os
import stat
import sys
mode = stat.S_IMODE(os.stat(sys.argv[1]).st_mode)
print(format(mode, "03o"))
PY
}

assert_summary_has_required_fields() {
  local summary_path="$1"
  local label="$2"
  local missing

  missing=$(python3 - "$summary_path" <<'PY'
import json
import sys
path = sys.argv[1]
required = [
    "result",
    "status",
    "env",
    "source_db_instance_id",
    "target_db_instance_id",
    "restore_mode",
    "restore_command",
    "cleanup_lifecycle",
]
with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)
missing = [k for k in required if k not in payload]
print(",".join(missing))
PY
)

  if [[ -z "$missing" ]]; then
    pass "$label"
  else
    fail "$label (missing keys: $missing)"
  fi
}

extract_runbook_sql_like_wrapper() {
  local runbook_path="$1"
  awk '
    /<<'\''SQL'\''/ {in_sql=1; next}
    in_sql && /^SQL$/ {exit}
    in_sql {print}
  ' "$runbook_path"
}

assert_verification_sql_matches_runbook() {
  local verification_sql_path="$1"
  local runbook_path="$2"
  local label="$3"
  local expected_sql=""
  local expected_file=""
  local actual_file=""

  if [[ ! -f "$verification_sql_path" || ! -f "$runbook_path" ]]; then
    fail "$label"
    return
  fi

  expected_sql="$(extract_runbook_sql_like_wrapper "$runbook_path")"
  if [[ -z "$expected_sql" ]]; then
    fail "$label (runbook SQL block missing)"
    return
  fi

  expected_file="$(mktemp "$WORK_DIR/tmp/expected_sql.XXXXXX")"
  actual_file="$(mktemp "$WORK_DIR/tmp/actual_sql.XXXXXX")"

  printf '%s\n' "$expected_sql" > "$expected_file"
  cat "$verification_sql_path" > "$actual_file"

  if cmp -s "$expected_file" "$actual_file"; then
    pass "$label"
  else
    fail "$label"
  fi

  rm -f "$expected_file" "$actual_file"
}

echo ""
echo "=== RDS Restore Evidence Wrapper Contract Tests (Red) ==="

echo ""
echo "--- wrapper script existence ---"
if [[ -x "$EVIDENCE_SCRIPT_SOURCE" ]]; then
  pass "rds_restore_evidence.sh exists and is executable"
else
  fail "rds_restore_evidence.sh exists and is executable"
fi

echo ""
echo "--- env-loading + aws cli guardrails ---"
setup
mkdir -p "$WORK_DIR/.secret"
cat > "$WORK_DIR/.secret/.env.secret" <<'ENVDEFAULT'
AWS_ACCESS_KEY_ID=AKIADEFAULTREPO
AWS_SECRET_ACCESS_KEY=default-repo-secret
AWS_SESSION_TOKEN=default-repo-session
AWS_DEFAULT_REGION=us-east-1
ENVDEFAULT
run_wrapper --env RDS_RESTORE_DRILL_EXECUTE=1 -- staging --artifact-dir "$ARTIFACT_ROOT" --execute
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "live execution without --env-file uses readable default repo-root env secret file"
else
  fail "live execution without --env-file uses readable default repo-root env secret file"
fi
assert_log_contains "$MOCK_DRILL_ENV_LOG" '^AWS_ACCESS_KEY_ID=AKIADEFAULTREPO$' "default repo-root env file values are loaded for live execution"

run_wrapper -- staging --artifact-dir "$ARTIFACT_ROOT" --execute --env-file "$WORK_DIR/inputs/missing.secret"
if [[ "$LAST_EXIT_CODE" -ne 0 ]]; then
  pass "live execution requires readable secret env file"
else
  fail "live execution requires readable secret env file"
fi
assert_output_contains 'env|secret|readable|file' "missing secret env file error references env-file contract"

run_wrapper -- staging --artifact-dir "$ARTIFACT_ROOT" --execute --env-file "$WORK_DIR/inputs/env_unsafe.secret"
if [[ "$LAST_EXIT_CODE" -ne 0 ]]; then
  pass "wrapper rejects env files with shell-unsafe AWS assignments"
else
  fail "wrapper rejects env files with shell-unsafe AWS assignments"
fi
assert_output_contains 'unsafe|shell|env' "unsafe env parsing rejection is explicit"
if [[ -f "$UNSAFE_ENV_MARKER" ]]; then
  fail "wrapper never evaluates shell expressions while loading AWS vars"
else
  pass "wrapper never evaluates shell expressions while loading AWS vars"
fi

run_wrapper -- staging --artifact-dir "$ARTIFACT_ROOT" --env-file "$WORK_DIR/inputs/env.secret"
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "wrapper accepts readable secret env file for dry-run flow"
else
  fail "wrapper accepts readable secret env file for dry-run flow"
fi
assert_every_log_line_contains "$MOCK_AWS_LOG" 'AWS_PAGER= |' "all aws calls run with empty AWS_PAGER"
assert_log_not_contains "$MOCK_AWS_LOG" 'AWS_PAGER=UNSET' "aws calls do not leave AWS_PAGER unset"
assert_every_log_line_contains "$MOCK_AWS_LOG" '--no-cli-pager' "all aws calls include --no-cli-pager"
assert_log_not_contains "$MOCK_DRILL_ENV_LOG" '^NOT_AWS_VAR=' "wrapper does not export non-AWS vars from env file"
teardown

echo ""
echo "--- dry-run artifact + summary contract ---"
setup
run_wrapper -- staging --artifact-dir "$ARTIFACT_ROOT" --env-file "$WORK_DIR/inputs/env.secret"
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "dry-run wrapper execution exits 0"
else
  fail "dry-run wrapper execution exits 0"
fi
assert_log_contains "$MOCK_DRILL_LOG" '--source-db-instance-id' "wrapper delegates to rds_restore_drill.sh with source id"
assert_log_not_contains "$MOCK_AWS_LOG" 'restore-db-instance-from-db-snapshot|restore-db-instance-to-point-in-time' "dry-run wrapper does not dispatch restore APIs"

run_dir="$(single_run_dir "$ARTIFACT_ROOT")"
if [[ -n "$run_dir" ]]; then
  pass "wrapper creates one run-scoped artifact directory"
else
  fail "wrapper creates one run-scoped artifact directory"
fi

if [[ -n "$run_dir" ]]; then
  mode="$(file_mode_octal "$run_dir")"
  if [[ "$mode" == "700" ]]; then
    pass "run-scoped artifact directory is owner-only"
  else
    fail "run-scoped artifact directory is owner-only (mode=$mode)"
  fi

  assert_file_exists "$run_dir/summary.json" "summary.json is written"
  assert_file_exists "$run_dir/discovery.json" "discovery.json is written"
  assert_file_exists "$run_dir/restore_request.json" "restore_request.json is written"
  assert_file_exists "$run_dir/verification.sql" "verification.sql is written"
  assert_file_exists "$run_dir/verification.txt" "verification.txt is written"
  assert_verification_sql_matches_runbook "$run_dir/verification.sql" "$RUNBOOK_PATH" "verification.sql exactly matches canonical runbook SQL block"

  if [[ -f "$run_dir/summary.json" ]]; then
    assert_summary_has_required_fields "$run_dir/summary.json" "summary.json includes machine-readable required fields"
    assert_file_contains "$run_dir/summary.json" '"status"' "summary.json includes status"
    assert_file_contains "$run_dir/summary.json" '"result"' "summary.json includes result"
    assert_file_contains "$run_dir/summary.json" '"restore_command"' "summary.json includes redacted restore_command"
    assert_file_contains "$run_dir/summary.json" '"cleanup_lifecycle"' "summary.json includes cleanup_lifecycle contract"
  fi
fi
teardown

echo ""
echo "--- gating regression contract ---"
setup
run_wrapper -- staging --artifact-dir "$ARTIFACT_ROOT" --source-db-instance-id fjcloud-staging --target-db-instance-id fjcloud-staging
if [[ "$LAST_EXIT_CODE" -ne 0 ]]; then
  pass "wrapper rejects identical source/target db identifiers"
else
  fail "wrapper rejects identical source/target db identifiers"
fi
assert_output_contains 'different|source|target' "identical source/target rejection is explicit"

run_wrapper -- staging --artifact-dir "$ARTIFACT_ROOT" --source-db-instance-id fjcloud-staging --target-db-instance-id fjcloud-staging-restore --master-user-password supersecret
if [[ "$LAST_EXIT_CODE" -ne 0 ]]; then
  pass "wrapper rejects password CLI arguments"
else
  fail "wrapper rejects password CLI arguments"
fi
assert_output_not_contains 'supersecret' "password rejection never echoes secret value"

run_wrapper -- staging --artifact-dir "$ARTIFACT_ROOT" --source-db-instance-id fjcloud-staging --target-db-instance-id fjcloud-staging-restore --master-user-password=supersecret
if [[ "$LAST_EXIT_CODE" -ne 0 ]]; then
  pass "wrapper rejects password CLI arguments passed with equals syntax"
else
  fail "wrapper rejects password CLI arguments passed with equals syntax"
fi
assert_output_not_contains 'supersecret' "password equals-arg rejection never echoes secret value"

run_wrapper -- staging --artifact-dir "$ARTIFACT_ROOT" --source-db-instance-id fjcloud-staging --target-db-instance-id fjcloud-staging-restore --execute
if [[ "$LAST_EXIT_CODE" -ne 0 ]]; then
  pass "live dispatch requires both --execute and RDS_RESTORE_DRILL_EXECUTE=1"
else
  fail "live dispatch requires both --execute and RDS_RESTORE_DRILL_EXECUTE=1"
fi
assert_output_contains 'RDS_RESTORE_DRILL_EXECUTE=1' "live dispatch gate error names env gate"

: > "$MOCK_AWS_LOG"
run_wrapper --env RDS_RESTORE_DRILL_EXECUTE=1 -- staging --artifact-dir "$ARTIFACT_ROOT" --source-db-instance-id fjcloud-staging --target-db-instance-id fjcloud-staging-restore --env-file "$WORK_DIR/inputs/env.secret"
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "env gate alone does not force live restore dispatch"
else
  fail "env gate alone does not force live restore dispatch"
fi
assert_log_not_contains "$MOCK_AWS_LOG" 'restore-db-instance-from-db-snapshot|restore-db-instance-to-point-in-time' "RDS_RESTORE_DRILL_EXECUTE=1 without --execute never dispatches restore APIs"

run_wrapper -- staging --artifact-dir "$ARTIFACT_ROOT" --source-db-instance-id fjcloud-staging --target-db-instance-id fjcloud-staging-restore
assert_log_not_contains "$MOCK_AWS_LOG" 'restore-db-instance-from-db-snapshot|restore-db-instance-to-point-in-time' "default/dry-run wrapper execution never dispatches restore APIs"
teardown

source "$SCRIPT_DIR/tests_rds_restore_evidence_unit_selection_helper_contract.sh"
source "$SCRIPT_DIR/tests_rds_restore_evidence_unit_execute_and_poll_contract.sh"

echo ""
echo "--- delegated gate artifact contract ---"
setup
run_wrapper --env RDS_RESTORE_DRILL_EXECUTE=1 -- staging --artifact-dir "$ARTIFACT_ROOT" --env-file "$WORK_DIR/inputs/env.secret"
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "dry-run wrapper run with parent execute gate exits 0"
else
  fail "dry-run wrapper run with parent execute gate exits 0"
fi

run_dir="$(single_run_dir "$ARTIFACT_ROOT")"
if [[ -n "$run_dir" && -f "$run_dir/restore_request.json" ]]; then
  assert_file_contains "$run_dir/restore_request.json" '"wrapper_execute"[[:space:]]*:[[:space:]]*false' "restore_request records wrapper_execute=false for dry-run delegation"
  assert_file_contains "$run_dir/restore_request.json" '"drill_execute_gate"[[:space:]]*:[[:space:]]*""' "restore_request records effective delegated drill gate for dry-run delegation"
else
  fail "dry-run delegated gate run writes restore_request artifact"
fi
teardown

echo ""
echo "--- blocked precondition contract ---"
setup
run_wrapper --env RDS_RESTORE_TEST_DISCOVERY_MODE=cluster_only -- staging --artifact-dir "$ARTIFACT_ROOT" --env-file "$WORK_DIR/inputs/env.secret"
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "cluster-shaped blocker records blocked result without hard failure"
else
  fail "cluster-shaped blocker records blocked result without hard failure"
fi
assert_log_not_contains "$MOCK_AWS_LOG" 'restore-db-instance-from-db-snapshot|restore-db-instance-to-point-in-time' "blocked preconditions never dispatch restore APIs"

run_dir="$(single_run_dir "$ARTIFACT_ROOT")"
if [[ -n "$run_dir" && -f "$run_dir/summary.json" ]]; then
  assert_file_contains "$run_dir/summary.json" '"status"[[:space:]]*:[[:space:]]*"blocked"' "blocked precondition summary status is blocked"
  assert_file_contains "$run_dir/summary.json" '"reason"' "blocked precondition summary includes blocker reason"
else
  fail "blocked precondition writes summary.json with blocked status"
fi

assert_output_not_contains 'cluster restore workflow|restore-db-cluster' "blocked path does not invent alternate cluster restore workflow"
teardown

echo ""
echo "--- discovery failure artifact contract ---"
setup
run_wrapper --env RDS_RESTORE_TEST_DISCOVERY_MODE=instances_error -- staging --artifact-dir "$ARTIFACT_ROOT" --env-file "$WORK_DIR/inputs/env.secret"
if [[ "$LAST_EXIT_CODE" -ne 0 ]]; then
  pass "aws discovery command failures return non-zero"
else
  fail "aws discovery command failures return non-zero"
fi

run_dir="$(single_run_dir "$ARTIFACT_ROOT")"
if [[ -n "$run_dir" ]]; then
  pass "aws discovery command failure still creates run-scoped directory"
else
  fail "aws discovery command failure still creates run-scoped directory"
fi

if [[ -n "$run_dir" ]]; then
  assert_file_exists "$run_dir/discovery.json" "aws discovery command failure still writes discovery artifact"
  assert_file_exists "$run_dir/summary.json" "aws discovery command failure still writes summary artifact"
  assert_file_exists "$run_dir/restore_request.json" "aws discovery command failure still writes restore_request artifact"
  assert_file_exists "$run_dir/verification.sql" "aws discovery command failure still writes verification.sql"
  assert_file_exists "$run_dir/verification.txt" "aws discovery command failure still writes verification.txt"
  if [[ -f "$run_dir/summary.json" ]]; then
    assert_file_contains "$run_dir/summary.json" '"status"[[:space:]]*:[[:space:]]*"fail"' "aws discovery command failure summary status is fail"
    assert_file_contains "$run_dir/summary.json" '"reason"' "aws discovery command failure summary includes reason"
  fi
fi
teardown

setup
run_wrapper --env RDS_RESTORE_TEST_DISCOVERY_MODE=snapshots_invalid_json -- staging --artifact-dir "$ARTIFACT_ROOT" --env-file "$WORK_DIR/inputs/env.secret"
if [[ "$LAST_EXIT_CODE" -ne 0 ]]; then
  pass "discovery json parsing failures return non-zero"
else
  fail "discovery json parsing failures return non-zero"
fi

run_dir="$(single_run_dir "$ARTIFACT_ROOT")"
if [[ -n "$run_dir" ]]; then
  pass "discovery json parsing failure still creates run-scoped directory"
else
  fail "discovery json parsing failure still creates run-scoped directory"
fi

if [[ -n "$run_dir" ]]; then
  assert_file_exists "$run_dir/discovery.json" "discovery json parsing failure still writes discovery artifact"
  assert_file_exists "$run_dir/summary.json" "discovery json parsing failure still writes summary artifact"
  assert_file_exists "$run_dir/restore_request.json" "discovery json parsing failure still writes restore_request artifact"
  assert_file_exists "$run_dir/verification.sql" "discovery json parsing failure still writes verification.sql"
  assert_file_exists "$run_dir/verification.txt" "discovery json parsing failure still writes verification.txt"
  if [[ -f "$run_dir/summary.json" ]]; then
    assert_file_contains "$run_dir/summary.json" '"status"[[:space:]]*:[[:space:]]*"fail"' "discovery json parsing failure summary status is fail"
    assert_file_contains "$run_dir/summary.json" '"reason"' "discovery json parsing failure summary includes reason"
  fi
fi
teardown

echo ""
echo "--- discovery artifact redaction contract ---"
setup
run_wrapper -- staging --artifact-dir "$ARTIFACT_ROOT" --env-file "$WORK_DIR/inputs/env.secret"
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "dry-run for discovery redaction contract exits 0"
else
  fail "dry-run for discovery redaction contract exits 0"
fi

run_dir="$(single_run_dir "$ARTIFACT_ROOT")"
if [[ -n "$run_dir" && -f "$run_dir/discovery.json" ]]; then
  assert_file_not_contains "$run_dir/discovery.json" '"DBInstances"' "discovery.json omits raw DBInstances payload"
  assert_file_not_contains "$run_dir/discovery.json" '"DBSnapshots"' "discovery.json omits raw DBSnapshots payload"
  assert_file_not_contains "$run_dir/discovery.json" '"DBClusters"' "discovery.json omits raw DBClusters payload"
else
  fail "dry-run writes discovery artifact for redaction checks"
fi
teardown

echo ""
echo "--- snapshot fallback selection contract ---"
setup
run_wrapper --env RDS_RESTORE_TEST_DISCOVERY_MODE=snapshot_fallback_mixed_sources -- staging --artifact-dir "$ARTIFACT_ROOT" --env-file "$WORK_DIR/inputs/env.secret"
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "snapshot fallback run exits 0 when source snapshots are available"
else
  fail "snapshot fallback run exits 0 when source snapshots are available"
fi
assert_log_contains "$MOCK_DRILL_LOG" '--snapshot-id rds:fjcloud-staging-2026-04-22-05-00' "snapshot fallback selects newest exact-source snapshot"
assert_log_not_contains "$MOCK_DRILL_LOG" '--snapshot-id rds:fjcloud-staging-foreign-2026-04-22-06-00' "snapshot fallback rejects substring-matching foreign source snapshots"
teardown

test_summary "RDS restore evidence wrapper red contract checks"
