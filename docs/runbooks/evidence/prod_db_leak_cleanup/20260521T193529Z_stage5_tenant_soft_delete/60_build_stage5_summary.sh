#!/usr/bin/env bash
# Build the single Stage 5 cross-run summary artifact consumed by Stage 6.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMARY_SUMMARY="$SCRIPT_DIR/runs/primary/40_stage5_soft_delete_summary.json"
RERUN_SUMMARY="$SCRIPT_DIR/runs/rerun/40_stage5_soft_delete_summary.json"
PRIMARY_DISP="$SCRIPT_DIR/runs/primary/30_stage5_soft_delete_dispositions.json"
OUT="$SCRIPT_DIR/40_stage5_summary.json"

python3 - "$PRIMARY_SUMMARY" "$RERUN_SUMMARY" "$PRIMARY_DISP" "$OUT" <<'PY'
import json
import pathlib
import sys

primary_summary = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
rerun_summary = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
primary_disp = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
out = pathlib.Path(sys.argv[4])

summary = {
    "stage": "stage5_tenant_soft_delete",
    "active_exact_cleanup_customers": primary_summary["active_exact_cleanup_customers"],
    "primary_bucket_counts": primary_summary["bucket_counts"],
    "rerun_bucket_counts": rerun_summary["bucket_counts"],
    "primary_violations": primary_summary.get("violations", []),
    "rerun_violations": rerun_summary.get("violations", []),
    "rerun_is_no_op_for_mutation": rerun_summary.get("bucket_counts", {}).get("soft_deleted_via_admin_route", -1) == 0,
    "customer_terminal_dispositions": {
        f"{row['environment']}:{row['customer_id']}": {
            "bucket": row.get("bucket"),
            "bucket_reason": row.get("bucket_reason"),
        }
        for row in primary_disp
    },
    "post_delete_status_evidence_pointers": primary_summary.get("post_delete_status_evidence_pointers", {}),
}

out.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
PY

echo "Stage 5 summary written: $OUT"
