#!/usr/bin/env bash
# Stage 5 reproducibility/idempotency check.
#
# Asserts:
#   - primary and rerun summary violations are empty
#   - rerun makes zero new soft-deletes via admin route
#   - per-customer terminal disposition remains stable across runs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMARY_SUMMARY="$SCRIPT_DIR/runs/primary/40_stage5_soft_delete_summary.json"
RERUN_SUMMARY="$SCRIPT_DIR/runs/rerun/40_stage5_soft_delete_summary.json"
PRIMARY_DISP="$SCRIPT_DIR/runs/primary/30_stage5_soft_delete_dispositions.json"
RERUN_DISP="$SCRIPT_DIR/runs/rerun/30_stage5_soft_delete_dispositions.json"
OUT="$SCRIPT_DIR/50_reproducibility_check.txt"

python3 - "$PRIMARY_SUMMARY" "$RERUN_SUMMARY" "$PRIMARY_DISP" "$RERUN_DISP" "$OUT" <<'PY'
import json
import pathlib
import sys

primary_summary = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
rerun_summary = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
primary_disp = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
rerun_disp = json.loads(pathlib.Path(sys.argv[4]).read_text(encoding="utf-8"))
out_path = pathlib.Path(sys.argv[5])

failures = []

if primary_summary.get("violations"):
    failures.append(f"primary_violations={primary_summary['violations']}")
if rerun_summary.get("violations"):
    failures.append(f"rerun_violations={rerun_summary['violations']}")

rerun_new_soft_deletes = rerun_summary.get("bucket_counts", {}).get("soft_deleted_via_admin_route", -1)
if rerun_new_soft_deletes != 0:
    failures.append(
        f"rerun_soft_deleted_via_admin_route={rerun_new_soft_deletes} (expected 0)"
    )


def terminal_class(bucket):
    if bucket in {"soft_deleted_via_admin_route", "already_deleted_confirmed"}:
        return "deleted_terminal"
    return "delete_failed"

primary_map = {
    (row["environment"], row["customer_id"]): terminal_class(row.get("bucket"))
    for row in primary_disp
}
rerun_map = {
    (row["environment"], row["customer_id"]): terminal_class(row.get("bucket"))
    for row in rerun_disp
}

if set(primary_map) != set(rerun_map):
    failures.append("primary_vs_rerun_customer_key_mismatch")
else:
    for key in sorted(primary_map):
        if primary_map[key] != rerun_map[key]:
            failures.append(
                f"terminal_disposition_changed:{key[0]}:{key[1]}:{primary_map[key]}->{rerun_map[key]}"
            )

if failures:
    out_path.write_text(
        "reproducibility_check=FAIL\n" + "\n".join(failures) + "\n",
        encoding="utf-8",
    )
    raise SystemExit(1)

out_path.write_text(
    "\n".join(
        [
            "reproducibility_check=PASS",
            f"primary_soft_deleted_via_admin_route={primary_summary['bucket_counts']['soft_deleted_via_admin_route']}",
            f"primary_already_deleted_confirmed={primary_summary['bucket_counts']['already_deleted_confirmed']}",
            f"rerun_soft_deleted_via_admin_route={rerun_summary['bucket_counts']['soft_deleted_via_admin_route']}",
            f"rerun_already_deleted_confirmed={rerun_summary['bucket_counts']['already_deleted_confirmed']}",
            f"active_exact_cleanup_customers_total={primary_summary['active_exact_cleanup_customers']['total']}",
        ]
    )
    + "\n",
    encoding="utf-8",
)
PY

cat "$OUT"
