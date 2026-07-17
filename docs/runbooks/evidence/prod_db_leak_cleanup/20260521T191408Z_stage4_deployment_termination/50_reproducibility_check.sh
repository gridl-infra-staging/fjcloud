#!/usr/bin/env bash
# Stage 4 reproducibility check.
#
# Compares primary and rerun disposition summaries and asserts:
#   - All terminating customers in primary are NOT also terminating in rerun
#     (the rerun must not produce new mutations — every running deployment
#     should have been terminated in primary).
#   - Both runs end with zero contract violations.
#   - Pre-delete capture is complete for every Stage 1 exact-cohort customer
#     in BOTH runs (so Stage 5 has a frozen pre-delete deployment record).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

STAGE1_DIR="$REPO_ROOT/docs/runbooks/evidence/prod_db_leak_cleanup/20260521T172106Z_stage1_inventory"
PRIMARY_SUMMARY="$SCRIPT_DIR/runs/primary/40_stage4_termination_summary.json"
RERUN_SUMMARY="$SCRIPT_DIR/runs/rerun/40_stage4_termination_summary.json"
PRIMARY_PRE_DELETE="$SCRIPT_DIR/runs/primary/20_pre_delete_deployments"
RERUN_PRE_DELETE="$SCRIPT_DIR/runs/rerun/20_pre_delete_deployments"
OUT="$SCRIPT_DIR/50_reproducibility_check.txt"

python3 - "$PRIMARY_SUMMARY" "$RERUN_SUMMARY" \
        "$STAGE1_DIR/10_prod_exact_cleanup.csv" \
        "$STAGE1_DIR/11_staging_exact_cleanup.csv" \
        "$PRIMARY_PRE_DELETE" "$RERUN_PRE_DELETE" "$OUT" <<'PY'
import csv
import json
import pathlib
import sys

primary = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
rerun = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
prod_csv = pathlib.Path(sys.argv[3])
staging_csv = pathlib.Path(sys.argv[4])
primary_pre_delete = pathlib.Path(sys.argv[5])
rerun_pre_delete = pathlib.Path(sys.argv[6])
out_path = pathlib.Path(sys.argv[7])


def read_ids(csv_path):
    ids = []
    with csv_path.open("r", encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            cid = (row.get("customer_id") or "").strip()
            if cid:
                ids.append(cid)
    return ids


prod_ids = read_ids(prod_csv)
staging_ids = read_ids(staging_csv)

failures = []

# 1. Violations must be empty in both runs.
if primary.get("violations"):
    failures.append(f"primary_violations={primary['violations']}")
if rerun.get("violations"):
    failures.append(f"rerun_violations={rerun['violations']}")

# 2. Rerun must not generate new terminations.
for env_name in ("prod", "staging"):
    if rerun[env_name]["deployments_terminated"] > 0:
        failures.append(
            f"rerun_{env_name}_deployments_terminated={rerun[env_name]['deployments_terminated']} "
            "(rerun must be a no-op for mutation)"
        )
    if rerun[env_name]["delete_failed_rows"] > 0:
        failures.append(
            f"rerun_{env_name}_delete_failed_rows={rerun[env_name]['delete_failed_rows']}"
        )

# 3. Pre-delete capture must be complete for every CSV customer in both runs.
def assert_pre_delete_complete(label, base_dir, env_name, ids):
    for cid in ids:
        safe = "".join(ch if ch.isalnum() or ch in "_-" else "_" for ch in cid)
        path = base_dir / f"{env_name}_{safe}_list.meta.json"
        if not path.exists():
            failures.append(f"{label}_pre_delete_missing:{env_name}:{cid}")


assert_pre_delete_complete("primary", primary_pre_delete, "prod", prod_ids)
assert_pre_delete_complete("primary", primary_pre_delete, "staging", staging_ids)
assert_pre_delete_complete("rerun", rerun_pre_delete, "prod", prod_ids)
assert_pre_delete_complete("rerun", rerun_pre_delete, "staging", staging_ids)

# 4. Customer counts must match Stage 1.
if primary["prod"]["csv_customer_count"] != len(prod_ids):
    failures.append(
        f"prod_csv_count_mismatch:primary={primary['prod']['csv_customer_count']}:csv={len(prod_ids)}"
    )
if primary["staging"]["csv_customer_count"] != len(staging_ids):
    failures.append(
        f"staging_csv_count_mismatch:primary={primary['staging']['csv_customer_count']}:csv={len(staging_ids)}"
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
            f"prod_csv_customer_count={len(prod_ids)}",
            f"staging_csv_customer_count={len(staging_ids)}",
            f"primary_prod_no_deployments={primary['prod']['customers_no_deployments']}",
            f"primary_staging_no_deployments={primary['staging']['customers_no_deployments']}",
            f"primary_staging_list_failed_rows={primary['staging']['list_failed_rows']}",
            f"primary_prod_deployments_terminated={primary['prod']['deployments_terminated']}",
            f"primary_staging_deployments_terminated={primary['staging']['deployments_terminated']}",
            f"rerun_prod_deployments_terminated={rerun['prod']['deployments_terminated']}",
            f"rerun_staging_deployments_terminated={rerun['staging']['deployments_terminated']}",
        ]
    )
    + "\n",
    encoding="utf-8",
)
PY

cat "$OUT"
