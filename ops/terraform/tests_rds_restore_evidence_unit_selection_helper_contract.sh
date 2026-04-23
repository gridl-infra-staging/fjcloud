#!/usr/bin/env bash
# Selection-helper fail-row regression coverage extracted from the main unit harness.

echo ""
echo "--- helper fail-row contract ---"
setup
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
