#!/usr/bin/env bash
# Build the single Stage 4 summary artifact that Stage 5 consumes.
# Derived only from the primary run disposition table — no parallel list.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMARY_DISP="$SCRIPT_DIR/runs/primary/30_termination_dispositions.json"
PRIMARY_SUMMARY="$SCRIPT_DIR/runs/primary/40_stage4_termination_summary.json"
RERUN_SUMMARY="$SCRIPT_DIR/runs/rerun/40_stage4_termination_summary.json"
OUT="$SCRIPT_DIR/40_stage4_summary.json"

python3 - "$PRIMARY_DISP" "$PRIMARY_SUMMARY" "$RERUN_SUMMARY" "$OUT" <<'PY'
import json
import pathlib
import sys

disp = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
primary = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
rerun = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
out_path = pathlib.Path(sys.argv[4])


def env_customer_groups(env_name):
    groups = {}
    for row in disp:
        if row["environment"] != env_name:
            continue
        groups.setdefault(row["customer_id"], []).append(row)
    return groups


def disposition_class(rows):
    # Roll up per-customer execution_disposition values into one customer-level
    # outcome that Stage 5 can switch on. If any deployment was terminated by
    # this stage, classify as "terminated_via_admin_route". Otherwise if any
    # deployment was already terminated, classify as "already_terminated_noop".
    # Otherwise if the listing failed entirely, classify as "list_failed".
    # Empty-list customers classify as "no_deployments".
    dispositions = [r["execution_disposition"] for r in rows]
    if any(d in {"terminated_via_admin_route", "terminated_other_2xx"} for d in dispositions):
        return "terminated_via_admin_route"
    if any(d == "already_terminated_concurrent" for d in dispositions):
        return "already_terminated_concurrent"
    if any(d == "already_terminated_noop" for d in dispositions):
        return "already_terminated_noop"
    if any(d == "list_failed" for d in dispositions):
        return "list_failed"
    if all(d == "no_deployments" for d in dispositions):
        return "no_deployments"
    if any(d == "delete_failed" for d in dispositions):
        return "delete_failed"
    return "unknown"


summary = {
    "stage": "stage4_deployment_termination",
    "stage_lineage": {
        "stage1_inventory_dir": "20260521T172106Z_stage1_inventory",
        "stage3_refund_execution_dir": "20260521T182407Z_stage3_refund_execution",
    },
    "primary_violations": primary.get("violations", []),
    "rerun_violations": rerun.get("violations", []),
    "totals": {
        "prod": primary["prod"],
        "staging": primary["staging"],
    },
    "rerun_mutation_proof": {
        "prod_deployments_terminated": rerun["prod"]["deployments_terminated"],
        "staging_deployments_terminated": rerun["staging"]["deployments_terminated"],
        "rerun_is_no_op_for_mutation": (
            rerun["prod"]["deployments_terminated"] == 0
            and rerun["staging"]["deployments_terminated"] == 0
        ),
    },
    "customer_dispositions": {
        env_name: {
            cid: {
                "customer_disposition": disposition_class(rows),
                "deployment_rows": rows,
            }
            for cid, rows in env_customer_groups(env_name).items()
        }
        for env_name in ("prod", "staging")
    },
}

out_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
PY

echo "Stage 4 summary written: $OUT"
