#!/usr/bin/env bash
# Selection-helper fail-row regression coverage extracted from the main unit harness.

echo ""
echo "--- helper fail-row contract ---"
setup
LAST_OUTPUT="$(
  cd "$WORK_DIR" && env -i \
    "PATH=$MOCK_BIN:/usr/bin:/bin:/usr/local/bin" \
    "HOME=$WORK_DIR" \
    "TMPDIR=$WORK_DIR/tmp" \
    python3 "$WORK_DIR/ops/scripts/lib/rds_restore_selection.py" 2>&1
)"
LAST_EXIT_CODE=$?
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "selection helper missing-argv contract run exits 0"
else
  fail "selection helper missing-argv contract run exits 0"
fi
assert_selection_field_equals "status" "fail" "selection helper missing-argv marks fail"
assert_selection_field_equals "reason" "expected 8 positional args: <instances_json> <snapshots_json> <clusters_json> <source_db_instance_id> <target_db_instance_id> <snapshot_id> <restore_time> <timestamp>" "selection helper missing-argv reports required positional contract"
assert_output_not_contains 'Traceback' "selection helper missing-argv does not leak a Python traceback"

cat > "$WORK_DIR/inputs/helper_instances.json" <<'JSON'
{"DBInstances":[{"DBInstanceIdentifier":"fjcloud-staging","BackupRetentionPeriod":7,"LatestRestorableTime":"2026-04-22T17:44:37Z"}]}
JSON
cat > "$WORK_DIR/inputs/helper_snapshots.json" <<'JSON'
{"DBSnapshots":[]}
JSON
cat > "$WORK_DIR/inputs/helper_clusters.json" <<'JSON'
{"DBClusters":[]}
JSON

run_selection_helper \
  "$WORK_DIR/inputs/helper_instances.json" \
  "$WORK_DIR/inputs/helper_snapshots.json" \
  "$WORK_DIR/inputs/helper_clusters.json" \
  "fjcloud-staging" \
  "fjcloud-staging" \
  "" \
  ""
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "selection helper identical source/target contract run exits 0"
else
  fail "selection helper identical source/target contract run exits 0"
fi
assert_selection_field_equals "status" "fail" "selection helper identical source/target marks fail"
assert_selection_field_equals "source" "" "selection helper identical source/target keeps source field blank"
assert_selection_field_equals "target" "" "selection helper identical source/target keeps target field blank"
assert_selection_field_equals "snapshot_id" "" "selection helper identical source/target keeps snapshot_id blank"
assert_selection_field_equals "restore_time" "" "selection helper identical source/target keeps restore_time blank"

run_selection_helper \
  "$WORK_DIR/inputs/helper_instances.json" \
  "$WORK_DIR/inputs/helper_snapshots.json" \
  "$WORK_DIR/inputs/helper_clusters.json" \
  "fjcloud-staging" \
  "fjcloud-staging-restore" \
  "rds:fjcloud-staging-2026-04-22-03-00" \
  "2026-04-22T17:44:37Z"
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "selection helper mutually-exclusive selector contract run exits 0"
else
  fail "selection helper mutually-exclusive selector contract run exits 0"
fi
assert_selection_field_equals "status" "fail" "selection helper mutually-exclusive selectors mark fail"
assert_selection_field_equals "source" "" "selection helper mutually-exclusive selectors keep source field blank"
assert_selection_field_equals "target" "" "selection helper mutually-exclusive selectors keep target field blank"
assert_selection_field_equals "snapshot_id" "" "selection helper mutually-exclusive selectors keep snapshot_id blank"
assert_selection_field_equals "restore_time" "" "selection helper mutually-exclusive selectors keep restore_time blank"
teardown

setup
cat > "$WORK_DIR/inputs/helper_instances.json" <<'JSON'
{"DBInstances":[
  {"DBInstanceIdentifier":"fjcloud-staging","BackupRetentionPeriod":7,"LatestRestorableTime":"2026-04-22T17:44:37Z"},
  {"DBInstanceIdentifier":"fjcloud-staging-restore-20260422174437","BackupRetentionPeriod":7},
  {"DBInstanceIdentifier":"fjcloud-staging-restore-20260422174437-2","BackupRetentionPeriod":7}
]}
JSON
cat > "$WORK_DIR/inputs/helper_snapshots.json" <<'JSON'
{"DBSnapshots":[]}
JSON
cat > "$WORK_DIR/inputs/helper_clusters.json" <<'JSON'
{"DBClusters":[]}
JSON

run_selection_helper \
  "$WORK_DIR/inputs/helper_instances.json" \
  "$WORK_DIR/inputs/helper_snapshots.json" \
  "$WORK_DIR/inputs/helper_clusters.json" \
  "fjcloud-staging" \
  "" \
  "" \
  ""
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "selection helper target-collision contract run exits 0"
else
  fail "selection helper target-collision contract run exits 0"
fi
assert_selection_field_equals "status" "ok" "selection helper target-collision run stays selectable"
assert_selection_field_equals "target" "fjcloud-staging-restore-20260422174437-3" "selection helper chooses next deterministic non-colliding default target"
teardown

echo ""
echo "--- selection helper explicit stale target contract ---"
setup
cat > "$WORK_DIR/inputs/helper_instances.json" <<'JSON'
{"DBInstances":[
  {"DBInstanceIdentifier":"fjcloud-staging","BackupRetentionPeriod":7,"LatestRestorableTime":"2026-04-22T17:44:37Z"},
  {"DBInstanceIdentifier":"fjcloud-staging-restore-existing","BackupRetentionPeriod":7}
]}
JSON
cat > "$WORK_DIR/inputs/helper_snapshots.json" <<'JSON'
{"DBSnapshots":[{"DBSnapshotIdentifier":"rds:fjcloud-staging-2026-04-22-03-00","DBInstanceIdentifier":"fjcloud-staging","SnapshotType":"automated","Status":"available","SnapshotCreateTime":"2026-04-22T03:00:00Z"}]}
JSON
cat > "$WORK_DIR/inputs/helper_clusters.json" <<'JSON'
{"DBClusters":[]}
JSON

run_selection_helper \
  "$WORK_DIR/inputs/helper_instances.json" \
  "$WORK_DIR/inputs/helper_snapshots.json" \
  "$WORK_DIR/inputs/helper_clusters.json" \
  "fjcloud-staging" \
  "fjcloud-staging-restore-existing" \
  "" \
  ""
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "selection helper explicit stale target run exits 0"
else
  fail "selection helper explicit stale target run exits 0"
fi
assert_selection_field_equals "status" "blocked" "selection helper explicit stale target marks blocked"
assert_selection_field_equals "reason" "target DB instance id 'fjcloud-staging-restore-existing' already exists; choose a new target identifier" "selection helper explicit stale target records deterministic reason"
assert_selection_field_equals "source" "fjcloud-staging" "selection helper explicit stale target keeps source in diagnostics"
assert_selection_field_equals "target" "fjcloud-staging-restore-existing" "selection helper explicit stale target keeps target in diagnostics"
assert_selection_field_equals "source_instance_present" "false" "selection helper explicit stale target exits before source discovery bookkeeping"
assert_selection_field_equals "available_snapshot_count" "0" "selection helper explicit stale target leaves snapshot fallback counters at defaults"
assert_selection_field_equals "restore_mode" "" "selection helper explicit stale target leaves restore_mode blank"
assert_selection_field_equals "snapshot_id" "" "selection helper explicit stale target leaves snapshot_id blank"
assert_selection_field_equals "restore_time" "" "selection helper explicit stale target leaves restore_time blank"
teardown

echo ""
echo "--- selection helper no-PITR-no-snapshot fallback contract ---"
setup
cat > "$WORK_DIR/inputs/helper_instances.json" <<'JSON'
{"DBInstances":[{"DBInstanceIdentifier":"fjcloud-staging","BackupRetentionPeriod":0,"DBInstanceStatus":"available"}]}
JSON
cat > "$WORK_DIR/inputs/helper_snapshots.json" <<'JSON'
{"DBSnapshots":[]}
JSON
cat > "$WORK_DIR/inputs/helper_clusters.json" <<'JSON'
{"DBClusters":[]}
JSON

run_selection_helper \
  "$WORK_DIR/inputs/helper_instances.json" \
  "$WORK_DIR/inputs/helper_snapshots.json" \
  "$WORK_DIR/inputs/helper_clusters.json" \
  "fjcloud-staging" \
  "fjcloud-staging-restore" \
  "" \
  ""
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "selection helper no-PITR-no-snapshot exits 0"
else
  fail "selection helper no-PITR-no-snapshot exits 0"
fi
assert_selection_field_equals "status" "blocked" "selection helper no-PITR-no-snapshot marks blocked"
assert_selection_field_equals "reason" "missing required restore selectors (no PITR timestamp and no available snapshot bound to source 'fjcloud-staging')" "selection helper no-PITR-no-snapshot records full reason"
assert_selection_field_equals "restore_mode" "" "selection helper no-PITR-no-snapshot leaves restore_mode blank"
assert_selection_field_equals "snapshot_id" "" "selection helper no-PITR-no-snapshot leaves snapshot_id blank"
assert_selection_field_equals "restore_time" "" "selection helper no-PITR-no-snapshot leaves restore_time blank"
teardown

echo ""
echo "--- selection helper all-snapshots-unavailable contract ---"
setup
cat > "$WORK_DIR/inputs/helper_instances.json" <<'JSON'
{"DBInstances":[{"DBInstanceIdentifier":"fjcloud-staging","BackupRetentionPeriod":0,"DBInstanceStatus":"available"}]}
JSON
cat > "$WORK_DIR/inputs/helper_snapshots.json" <<'JSON'
{"DBSnapshots":[
  {"DBSnapshotIdentifier":"rds:fjcloud-staging-creating","DBInstanceIdentifier":"fjcloud-staging","SnapshotType":"automated","Status":"creating","SnapshotCreateTime":"2026-04-22T06:00:00Z"},
  {"DBSnapshotIdentifier":"rds:fjcloud-staging-deleting","DBInstanceIdentifier":"fjcloud-staging","SnapshotType":"automated","Status":"deleting","SnapshotCreateTime":"2026-04-22T05:00:00Z"}
]}
JSON
cat > "$WORK_DIR/inputs/helper_clusters.json" <<'JSON'
{"DBClusters":[]}
JSON

run_selection_helper \
  "$WORK_DIR/inputs/helper_instances.json" \
  "$WORK_DIR/inputs/helper_snapshots.json" \
  "$WORK_DIR/inputs/helper_clusters.json" \
  "fjcloud-staging" \
  "fjcloud-staging-restore" \
  "" \
  ""
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "selection helper all-snapshots-unavailable exits 0"
else
  fail "selection helper all-snapshots-unavailable exits 0"
fi
assert_selection_field_equals "status" "blocked" "selection helper all-snapshots-unavailable marks blocked"
assert_selection_field_equals "reason" "missing required restore selectors (no PITR timestamp and no available snapshot bound to source 'fjcloud-staging')" "selection helper all-snapshots-unavailable records full reason"
assert_selection_field_equals "available_snapshot_count" "0" "selection helper all-snapshots-unavailable counts zero available snapshots"
assert_selection_field_equals "source_scoped_snapshot_count" "0" "selection helper all-snapshots-unavailable counts zero source-scoped snapshots"
teardown

echo ""
echo "--- selection helper retention-but-no-LRT fallback contract ---"
setup
cat > "$WORK_DIR/inputs/helper_instances.json" <<'JSON'
{"DBInstances":[{"DBInstanceIdentifier":"fjcloud-staging","BackupRetentionPeriod":7,"DBInstanceStatus":"available"}]}
JSON
cat > "$WORK_DIR/inputs/helper_snapshots.json" <<'JSON'
{"DBSnapshots":[{"DBSnapshotIdentifier":"rds:fjcloud-staging-2026-04-22-03-00","DBInstanceIdentifier":"fjcloud-staging","SnapshotType":"automated","Status":"available","SnapshotCreateTime":"2026-04-22T03:00:00Z"}]}
JSON
cat > "$WORK_DIR/inputs/helper_clusters.json" <<'JSON'
{"DBClusters":[]}
JSON

run_selection_helper \
  "$WORK_DIR/inputs/helper_instances.json" \
  "$WORK_DIR/inputs/helper_snapshots.json" \
  "$WORK_DIR/inputs/helper_clusters.json" \
  "fjcloud-staging" \
  "fjcloud-staging-restore" \
  "" \
  ""
if [[ "$LAST_EXIT_CODE" -eq 0 ]]; then
  pass "selection helper retention-but-no-LRT exits 0"
else
  fail "selection helper retention-but-no-LRT exits 0"
fi
assert_selection_field_equals "status" "ok" "selection helper retention-but-no-LRT stays ok"
assert_selection_field_equals "restore_mode" "snapshot" "selection helper retention-but-no-LRT falls to snapshot mode"
assert_selection_field_equals "snapshot_id" "rds:fjcloud-staging-2026-04-22-03-00" "selection helper retention-but-no-LRT selects the available snapshot"
assert_selection_field_equals "restore_time" "" "selection helper retention-but-no-LRT leaves restore_time blank"
teardown
