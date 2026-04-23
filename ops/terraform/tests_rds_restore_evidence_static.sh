#!/usr/bin/env bash
# Static ownership assertions for ops/scripts/rds_restore_evidence.sh.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

script_file="ops/scripts/rds_restore_evidence.sh"
selection_helper_file="ops/scripts/lib/rds_restore_selection.py"
unit_harness_file="ops/terraform/tests_rds_restore_evidence_unit.sh"
unit_harness_selection_contract_file="ops/terraform/tests_rds_restore_evidence_unit_selection_helper_contract.sh"

echo ""
echo "=== RDS Restore Evidence Static Contract Tests ==="
echo ""

assert_file_exists "$script_file" "rds_restore_evidence.sh exists"
assert_file_exists "$selection_helper_file" "rds_restore_selection.py exists"
assert_file_exists "$unit_harness_selection_contract_file" "selection-helper contract coverage split file exists"
assert_file_contains "$script_file" 'rds_restore_drill\.sh' "wrapper delegates restore command construction to rds_restore_drill.sh"
assert_file_contains "$unit_harness_file" 'tests_rds_restore_evidence_unit_selection_helper_contract\.sh' "unit harness sources split selection-helper contract coverage"
assert_file_contains "$script_file" '/Users/stuart/repos/gridl/fjcloud/\.secret/\.env\.secret' "wrapper defaults to canonical staging secret env path"
assert_file_not_contains "$script_file" 'restore-db-instance-from-db-snapshot' "wrapper does not duplicate snapshot restore API assembly"
assert_file_not_contains "$script_file" 'restore-db-instance-to-point-in-time' "wrapper does not duplicate PITR restore API assembly"
assert_file_not_contains "$script_file" 'python3 - "\$DISCOVERY_DB_INSTANCES_JSON"' "discovery helper does not pass large describe payloads through python argv"
assert_file_not_contains "$script_file" 'python3 - "\$describe_payload"' "poll helper does not pass large describe payloads through python argv"

discover_restore_inputs_lines="$(
  awk '
    /^discover_restore_inputs\(\) \{/ {start=NR}
    start && /^}$/ {print NR - start + 1; exit}
  ' "$script_file"
)"

if [[ -n "$discover_restore_inputs_lines" && "$discover_restore_inputs_lines" -le 100 ]]; then
  pass "discover_restore_inputs stays within 100-line hard limit"
else
  fail "discover_restore_inputs stays within 100-line hard limit (actual=${discover_restore_inputs_lines:-unknown})"
fi

select_restore_inputs_lines="$(
  awk '
    /^select_restore_inputs_from_discovery\(\) \{/ {start=NR}
    start && /^}$/ {print NR - start + 1; exit}
  ' "$script_file"
)"

if [[ -n "$select_restore_inputs_lines" && "$select_restore_inputs_lines" -le 100 ]]; then
  pass "select_restore_inputs_from_discovery stays within 100-line hard limit"
else
  fail "select_restore_inputs_from_discovery stays within 100-line hard limit (actual=${select_restore_inputs_lines:-unknown})"
fi

script_line_count="$(wc -l < "$script_file" | tr -d '[:space:]')"
if [[ -n "$script_line_count" && "$script_line_count" -le 800 ]]; then
  pass "rds_restore_evidence.sh stays within 800-line hard limit"
else
  fail "rds_restore_evidence.sh stays within 800-line hard limit (actual=${script_line_count:-unknown})"
fi

unit_harness_line_count="$(wc -l < "$unit_harness_file" | tr -d '[:space:]')"
if [[ -n "$unit_harness_line_count" && "$unit_harness_line_count" -le 800 ]]; then
  pass "tests_rds_restore_evidence_unit.sh stays within 800-line hard limit"
else
  fail "tests_rds_restore_evidence_unit.sh stays within 800-line hard limit (actual=${unit_harness_line_count:-unknown})"
fi

selection_main_lines="$(
  python3 - "$selection_helper_file" <<'PY'
import ast
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
module = ast.parse(source, filename=str(path))
for node in module.body:
    if isinstance(node, ast.FunctionDef) and node.name == "main":
        print(node.end_lineno - node.lineno + 1)
        raise SystemExit(0)
print("")
PY
)"

if [[ -n "$selection_main_lines" && "$selection_main_lines" -le 100 ]]; then
  pass "rds_restore_selection.py main stays within 100-line hard limit"
else
  fail "rds_restore_selection.py main stays within 100-line hard limit (actual=${selection_main_lines:-unknown})"
fi

test_summary "RDS restore evidence static checks"
