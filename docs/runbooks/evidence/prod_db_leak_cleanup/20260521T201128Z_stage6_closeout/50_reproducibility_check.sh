#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMARY="$SCRIPT_DIR/runs/primary/40_run_summary.json"
RERUN="$SCRIPT_DIR/runs/rerun/40_run_summary.json"
STAGE4_REPRO="$SCRIPT_DIR/../20260521T191408Z_stage4_deployment_termination/50_reproducibility_check.txt"
STAGE5_REPRO="$SCRIPT_DIR/../20260521T193529Z_stage5_tenant_soft_delete/50_reproducibility_check.txt"

[ -f "$PRIMARY" ] || { echo "missing primary summary" >&2; exit 1; }
[ -f "$RERUN" ] || { echo "missing rerun summary" >&2; exit 1; }
[ -f "$STAGE4_REPRO" ] || { echo "missing stage4 reproducibility proof" >&2; exit 1; }
[ -f "$STAGE5_REPRO" ] || { echo "missing stage5 reproducibility proof" >&2; exit 1; }
grep -Fq "reproducibility_check=PASS" "$STAGE4_REPRO" || { echo "stage4 reproducibility not PASS" >&2; exit 1; }
grep -Fq "reproducibility_check=PASS" "$STAGE5_REPRO" || { echo "stage5 reproducibility not PASS" >&2; exit 1; }

python3 - "$PRIMARY" "$RERUN" <<"PY"
import json, sys
primary=json.load(open(sys.argv[1],encoding="utf-8"))
rerun=json.load(open(sys.argv[2],encoding="utf-8"))
for env in ("prod","staging"):
    p=primary["counts"][env]["active_exact_cleanup_customers"]
    r=rerun["counts"][env]["active_exact_cleanup_customers"]
    if p != 0 or r != 0:
        raise SystemExit(f"active_exact_cleanup_customers must remain 0 for {env} (primary={p}, rerun={r})")
    ps=sorted(primary["customer_ids"][env]["suspicious"])
    rs=sorted(rerun["customer_ids"][env]["suspicious"])
    if ps != rs:
        raise SystemExit(f"suspicious customer id set drift in {env}")
print("reproducibility_check=PASS")
PY
