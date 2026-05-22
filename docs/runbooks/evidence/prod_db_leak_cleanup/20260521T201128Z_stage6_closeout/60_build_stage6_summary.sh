#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMARY_SUMMARY="$SCRIPT_DIR/runs/primary/40_run_summary.json"
RERUN_SUMMARY="$SCRIPT_DIR/runs/rerun/40_run_summary.json"
STAGE1_DIR="$SCRIPT_DIR/../20260521T172106Z_stage1_inventory"
STAGE2_DIR="$SCRIPT_DIR/../20260521T180304Z_stage2_refund_proposal"
STAGE3_DIR="$SCRIPT_DIR/../20260521T182407Z_stage3_refund_execution"
STAGE4_DIR="$SCRIPT_DIR/../20260521T191408Z_stage4_deployment_termination"
STAGE5_DIR="$SCRIPT_DIR/../20260521T193529Z_stage5_tenant_soft_delete"
OUT="$SCRIPT_DIR/40_stage6_summary.json"
DISP_OUT="$SCRIPT_DIR/30_suspicious_inventory_dispositions.json"

python3 - "$PRIMARY_SUMMARY" "$RERUN_SUMMARY" "$STAGE1_DIR" "$STAGE2_DIR" "$STAGE3_DIR" "$STAGE4_DIR" "$STAGE5_DIR" "$DISP_OUT" "$OUT" <<"PY"
import csv
import json
import pathlib
import sys

primary_path = pathlib.Path(sys.argv[1])
rerun_path = pathlib.Path(sys.argv[2])
stage1_dir = pathlib.Path(sys.argv[3])
stage2_dir = pathlib.Path(sys.argv[4])
stage3_dir = pathlib.Path(sys.argv[5])
stage4_dir = pathlib.Path(sys.argv[6])
stage5_dir = pathlib.Path(sys.argv[7])
disp_out = pathlib.Path(sys.argv[8])
out = pathlib.Path(sys.argv[9])

primary = json.loads(primary_path.read_text(encoding="utf-8"))
rerun = json.loads(rerun_path.read_text(encoding="utf-8"))
stage1 = json.loads((stage1_dir / "40_stage1_summary.json").read_text(encoding="utf-8"))
stage2 = json.loads((stage2_dir / "40_refund_proposal_summary.json").read_text(encoding="utf-8"))
stage2_approval = json.loads((stage2_dir / "41_operator_approval_input.json").read_text(encoding="utf-8"))
stage3 = json.loads((stage3_dir / "40_refund_execution_summary.json").read_text(encoding="utf-8"))
stage4 = json.loads((stage4_dir / "40_stage4_summary.json").read_text(encoding="utf-8"))
stage5 = json.loads((stage5_dir / "40_stage5_summary.json").read_text(encoding="utf-8"))

def read_csv(path):
    with path.open("r", encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))

# Row identity is (customer_id, tenant_id, deployment_id): one customer may
# own several customer_tenants/customer_deployments rows (e.g. prod customer
# 60dc2284 owns 14 distinct tenants), so deduping by customer_id alone drops
# real suspicious rows from the closeout disposition table.
def row_key(row):
    return (
        (row.get("customer_id") or "").strip(),
        (row.get("tenant_id") or "").strip(),
        (row.get("deployment_id") or "").strip(),
    )

def keyed(rows):
    out = {}
    for row in rows:
        key = row_key(row)
        if not key[0]:
            continue
        out[key] = row
    return out

s1_prod_rows = read_csv(stage1_dir / "20_prod_suspicious_inventory.csv")
s1_stg_rows = read_csv(stage1_dir / "21_staging_suspicious_inventory.csv")
r_prod_rows = read_csv(pathlib.Path(primary_path.parent) / "20_prod_suspicious_inventory_rerun.csv")
r_stg_rows = read_csv(pathlib.Path(primary_path.parent) / "21_staging_suspicious_inventory_rerun.csv")

s1_prod = keyed(s1_prod_rows)
s1_stg = keyed(s1_stg_rows)
r_prod = keyed(r_prod_rows)
r_stg = keyed(r_stg_rows)

rows = []
for env, stage1_rows, rerun_rows in (("prod", s1_prod, r_prod), ("staging", s1_stg, r_stg)):
    all_keys = sorted(set(stage1_rows) | set(rerun_rows))
    for key in all_keys:
        row = rerun_rows.get(key, stage1_rows.get(key, {}))
        cid, tenant_id, deployment_id = key
        rows.append({
            "environment": env,
            "customer_id": cid,
            "tenant_id": tenant_id or None,
            "deployment_id": deployment_id or None,
            "email": row.get("email"),
            "stage1_present": key in stage1_rows,
            "stage6_rerun_present": key in rerun_rows,
            "disposition": "inventory_only_not_mutated_in_cleanup_lane",
        })

# Row-completeness gate: every Stage 1 suspicious row (each unique
# customer/tenant/deployment triple) must show up in the disposition table.
# This is the regression guard for the customer_id-dedup bug.
expected_counts = {"prod": len(s1_prod), "staging": len(s1_stg)}
actual_counts = {
    "prod": sum(1 for r in rows if r["environment"] == "prod"),
    "staging": sum(1 for r in rows if r["environment"] == "staging"),
}
for env in ("prod", "staging"):
    if actual_counts[env] < expected_counts[env]:
        raise SystemExit(
            f"disposition row-completeness failure for {env}: "
            f"actual={actual_counts[env]} stage1_expected={expected_counts[env]}"
        )

disp_out.write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")

for env in ("prod", "staging"):
    if primary["counts"][env]["active_exact_cleanup_customers"] != 0:
        raise SystemExit(f"primary active_exact_cleanup_customers not zero for {env}")
    if rerun["counts"][env]["active_exact_cleanup_customers"] != 0:
        raise SystemExit(f"rerun active_exact_cleanup_customers not zero for {env}")

summary = {
    "stage": "stage6_closeout",
    "active_exact_cleanup_customers": {
        "prod": primary["counts"]["prod"]["active_exact_cleanup_customers"],
        "staging": primary["counts"]["staging"]["active_exact_cleanup_customers"],
    },
    "suspicious_inventory": {
        "prod_count": sum(1 for r in rows if r["environment"] == "prod"),
        "staging_count": sum(1 for r in rows if r["environment"] == "staging"),
        "dispositions_json": str(disp_out),
    },
    "refund_lineage": {
        "stage2_approved_refund_eligible_charge_count": stage2_approval["refund_eligible_charge_count"],
        "stage2_approved_refund_total_cents": stage2_approval["refund_total_cents"],
        "stage3_executed_refund_count": stage3["created_refund_count"],
        "stage3_refund_post_count": stage3["refund_post_count"],
        "stage3_executed_refunded_total_cents": stage3["post_refetch_refunded_total_cents"],
    },
    "lineage_pointers": {
        "stage1_summary": str(stage1_dir / "40_stage1_summary.json"),
        "stage2_summary": str(stage2_dir / "40_refund_proposal_summary.json"),
        "stage2_operator_approval": str(stage2_dir / "41_operator_approval_input.json"),
        "stage3_summary": str(stage3_dir / "40_refund_execution_summary.json"),
        "stage4_summary": str(stage4_dir / "40_stage4_summary.json"),
        "stage5_summary": str(stage5_dir / "40_stage5_summary.json"),
    },
    "stage4_evidence": {
        "primary_pre_delete_deployments_dir": str(stage4_dir / "runs/primary/20_pre_delete_deployments"),
        "primary_termination_dispositions_json": str(stage4_dir / "runs/primary/30_termination_dispositions.json"),
        "stage4_rerun_no_mutation": stage4.get("rerun_mutation_proof", {}).get("rerun_is_no_op_for_mutation"),
    },
    "stage5_evidence": stage5.get("post_delete_status_evidence_pointers", {}),
    "stage6_rerun_reproducibility": {
        "primary_summary": str(primary_path),
        "rerun_summary": str(rerun_path),
    },
}

out.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
PY

echo "Stage 6 summary written: $OUT"
