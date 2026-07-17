#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/00_commands.sh"
FILTER_CONTRACT="$SCRIPT_DIR/../20260521T172106Z_stage1_inventory/06_filter_contract.txt"

fail() { echo "[FAIL] $1" >&2; exit 1; }

[ -f "$RUNNER" ] || fail "missing runner: $RUNNER"
[ -f "$FILTER_CONTRACT" ] || fail "missing stage1 filter contract"

runner_text="$(cat "$RUNNER")"
contract_text="$(cat "$FILTER_CONTRACT")"

exact_filter="$(printf "%s\n" "$contract_text" | awk -F= "/^exact_filter=/{print \$2}")"
created_floor="$(printf "%s\n" "$contract_text" | awk -F= "/^created_at_floor=/{print \$2}")"

printf "%s" "$runner_text" | grep -Fq "$exact_filter" || fail "runner missing stage1 exact filter"
printf "%s" "$runner_text" | grep -Fq "$created_floor" || fail "runner missing stage1 created_at_floor"
printf "%s" "$runner_text" | grep -Fq "active_exact_cleanup_customers" || fail "runner missing active count alias"
printf "%s" "$runner_text" | grep -Fq "signup-paid-%@e2e.griddle.test" || fail "runner missing exact leak pattern"
printf "%s" "$runner_text" | grep -Fq "runs/\$label" || fail "runner missing runs/<label> path"
printf "%s" "$runner_text" | grep -Fq "case \"\$label\" in" || fail "runner must gate label values"
printf "%s" "$runner_text" | grep -Fq "primary)" || fail "runner must support primary label"
printf "%s" "$runner_text" | grep -Fq "rerun)" || fail "runner must support rerun label"
printf "%s" "$runner_text" | grep -Fq "10_prod_exact_cleanup_rerun.csv" || fail "runner missing prod exact rerun csv"
printf "%s" "$runner_text" | grep -Fq "11_staging_exact_cleanup_rerun.csv" || fail "runner missing staging exact rerun csv"
printf "%s" "$runner_text" | grep -Fq "20_prod_suspicious_inventory_rerun.csv" || fail "runner missing prod suspicious rerun csv"
printf "%s" "$runner_text" | grep -Fq "21_staging_suspicious_inventory_rerun.csv" || fail "runner missing staging suspicious rerun csv"
printf "%s" "$runner_text" | grep -Fq "22_prod_active_exact_cleanup_count.txt" || fail "runner missing prod active count file"
printf "%s" "$runner_text" | grep -Fq "23_staging_active_exact_cleanup_count.txt" || fail "runner missing staging active count file"
printf "%s" "$runner_text" | grep -Fq "40_run_summary.json" || fail "runner missing run summary"
printf "%s" "$runner_text" | grep -Fq "if [ \"\$prod_active_count\" -ne 0 ] || [ \"\$staging_active_count\" -ne 0 ]" || fail "runner must fail closed on non-zero active exact customers"

echo "stage6_closeout_contract=PASS"
