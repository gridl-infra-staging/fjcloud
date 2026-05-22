#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="/Users/stuart/parallel_development/fjcloud_dev/may21_12pm_2_prod_db_leak_cleanup/fjcloud_dev"
cd "$REPO_ROOT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_FILE="${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
RUN_LABEL="${1:-primary}"

case "$RUN_LABEL" in
    primary|rerun)
        ;;
    *)
        echo "Usage: $0 [primary|rerun]" >&2
        exit 2
        ;;
esac

STAGE2_DIR="$REPO_ROOT/docs/runbooks/evidence/prod_db_leak_cleanup/20260521T180304Z_stage2_refund_proposal"
STAGE2_DISPOSITIONS_JSON="$STAGE2_DIR/runs/primary/31_refund_dispositions.json"
STAGE2_SUMMARY_JSON="$STAGE2_DIR/40_refund_proposal_summary.json"
STAGE2_APPROVAL_JSON="$STAGE2_DIR/41_operator_approval_input.json"
STAGE3_APPROVAL_JSON="$SCRIPT_DIR/05_operator_approval.json"

RUN_DIR="$SCRIPT_DIR/runs/$RUN_LABEL"
mkdir -p "$RUN_DIR/24_refund_attempts" "$RUN_DIR/25_charge_refetches"

source "$REPO_ROOT/scripts/lib/env.sh"
source "$REPO_ROOT/scripts/lib/stripe_account.sh"
source "$REPO_ROOT/scripts/lib/stripe_request.sh"

load_layered_env_files "$SECRET_FILE"
stripe_account_resolve_secret_key "flapjack_cloud"

STRIPE_SECRET_KEY_EFFECTIVE="${STRIPE_SECRET_KEY}"
export STRIPE_SECRET_KEY_EFFECTIVE
STRIPE_API_BASE="https://api.stripe.com"
export STRIPE_API_BASE

if [ ! -f "$STAGE3_APPROVAL_JSON" ]; then
    echo "Missing required stage-local operator approval artifact: $STAGE3_APPROVAL_JSON" >&2
    exit 1
fi

cp "$STAGE3_APPROVAL_JSON" "$RUN_DIR/05_operator_approval.json"

python3 - "$STAGE2_APPROVAL_JSON" "$STAGE3_APPROVAL_JSON" "$RUN_DIR/06_approval_validation.txt" <<'PY'
import json
import pathlib
import sys

stage2_approval = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
stage3_approval = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
out_path = pathlib.Path(sys.argv[3])

failures = []
for field in ("refund_eligible_charge_count", "refund_total_cents"):
    left = int(stage2_approval.get(field, 0) or 0)
    right = int(stage3_approval.get(field, 0) or 0)
    if left != right:
        failures.append(f"approval_mismatch:{field}:stage2={left}:stage3={right}")

if failures:
    out_path.write_text("approval_validation=FAIL\n" + "\n".join(failures) + "\n", encoding="utf-8")
    raise SystemExit(1)

out_path.write_text("approval_validation=PASS\n", encoding="utf-8")
PY

STRIPE_LIVE_CUTOVER=1 bash "$REPO_ROOT/scripts/validate-stripe.sh" --live-cutover > "$RUN_DIR/10_validate_stripe_live_cutover.json"

python3 - "$STAGE2_DISPOSITIONS_JSON" "$STAGE2_SUMMARY_JSON" "$STAGE2_APPROVAL_JSON" "$RUN_DIR/20_refund_execution_plan.json" "$RUN_DIR/21_plan_lineage_validation.txt" "$RUN_DIR/22_plan_totals_validation.txt" <<'PY'
import json
import pathlib
import sys

stage2_dispositions = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
stage2_summary = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
stage2_approval = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
plan_path = pathlib.Path(sys.argv[4])
lineage_path = pathlib.Path(sys.argv[5])
totals_path = pathlib.Path(sys.argv[6])

plan_rows = []
for row in stage2_dispositions:
    stage2_disposition = (row.get("disposition") or "").strip()
    charge_id = row.get("charge_id")
    idempotency_key = None
    if stage2_disposition == "refund_eligible":
        if not charge_id:
            raise SystemExit("Stage 2 row has refund_eligible disposition but missing charge_id")
        idempotency_key = f"refund_{charge_id}_prod_db_leak_cleanup_20260521"

    plan_rows.append(
        {
            "customer_id": row.get("customer_id"),
            "email": row.get("email"),
            "stripe_customer_id": row.get("stripe_customer_id"),
            "charge_id": charge_id,
            "amount": row.get("amount"),
            "currency": row.get("currency"),
            "stage2_disposition": stage2_disposition,
            "stage2_reason": row.get("reason"),
            "idempotency_key": idempotency_key,
        }
    )

plan_path.write_text(json.dumps(plan_rows, indent=2) + "\n", encoding="utf-8")

approved_ids_by_customer = stage2_approval.get("refund_eligible_charge_ids_by_customer", {})
approved_ids = sorted(
    charge_id
    for charge_ids in approved_ids_by_customer.values()
    for charge_id in charge_ids
)
planned_eligible = [row for row in plan_rows if row.get("stage2_disposition") == "refund_eligible"]
planned_ids = sorted(row.get("charge_id") for row in planned_eligible if row.get("charge_id"))

lineage_failures = []

stage2_customer_ids = sorted(
    {
        str(row.get("customer_id")).strip()
        for row in stage2_dispositions
        if str(row.get("customer_id") or "").strip()
    }
)
plan_customer_ids = sorted(
    {
        str(row.get("customer_id")).strip()
        for row in plan_rows
        if str(row.get("customer_id") or "").strip()
    }
)
if stage2_customer_ids != plan_customer_ids:
    lineage_failures.append(
        "customer_coverage_mismatch:"
        f"missing_from_plan={sorted(set(stage2_customer_ids) - set(plan_customer_ids))}:"
        f"extra_in_plan={sorted(set(plan_customer_ids) - set(stage2_customer_ids))}"
    )

approved_id_set = set(approved_ids)
planned_id_set = set(planned_ids)
if not planned_id_set.issubset(approved_id_set):
    lineage_failures.append(f"planned_ids_not_in_stage2_approved={sorted(planned_id_set - approved_id_set)}")
if not approved_id_set.issubset(planned_id_set):
    lineage_failures.append(f"stage2_approved_ids_missing_from_plan={sorted(approved_id_set - planned_id_set)}")

if lineage_failures:
    lineage_path.write_text("plan_lineage_validation=FAIL\n" + "\n".join(lineage_failures) + "\n", encoding="utf-8")
    raise SystemExit(1)

lineage_path.write_text(
    "\n".join(
        [
            "plan_lineage_validation=PASS",
            f"stage2_customer_count={len(stage2_customer_ids)}",
            f"planned_customer_count={len(plan_customer_ids)}",
            f"approved_refund_charge_count={len(approved_ids)}",
            f"planned_refund_charge_count={len(planned_ids)}",
        ]
    )
    + "\n",
    encoding="utf-8",
)

totals_failures = []
recomputed_count = len(planned_eligible)
recomputed_total = sum(int(row.get("amount") or 0) for row in planned_eligible)
expected_count = int(stage2_summary.get("refund_eligible_charge_count", 0) or 0)
expected_total = int(stage2_summary.get("refund_total_cents", 0) or 0)

if recomputed_count != expected_count:
    totals_failures.append(f"refund_eligible_charge_count_mismatch:expected={expected_count}:recomputed={recomputed_count}")
if recomputed_total != expected_total:
    totals_failures.append(f"refund_total_cents_mismatch:expected={expected_total}:recomputed={recomputed_total}")

if totals_failures:
    totals_path.write_text("plan_totals_validation=FAIL\n" + "\n".join(totals_failures) + "\n", encoding="utf-8")
    raise SystemExit(1)

totals_path.write_text(
    "\n".join(
        [
            "plan_totals_validation=PASS",
            f"expected_refund_eligible_charge_count={expected_count}",
            f"recomputed_refund_eligible_charge_count={recomputed_count}",
            f"expected_refund_total_cents={expected_total}",
            f"recomputed_refund_total_cents={recomputed_total}",
        ]
    )
    + "\n",
    encoding="utf-8",
)
PY

APPROVED_ELIGIBLE_COUNT="$(python3 - "$STAGE3_APPROVAL_JSON" <<'PY'
import json
import pathlib
import sys

approval = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(int(approval.get("refund_eligible_charge_count", 0) or 0))
PY
)"

if [ "$APPROVED_ELIGIBLE_COUNT" -eq 0 ]; then
    python3 - "$STAGE2_APPROVAL_JSON" "$RUN_DIR/23_no_mutation_execution.json" <<'PY'
import json
import pathlib
import sys

stage2_approval = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
out_path = pathlib.Path(sys.argv[2])
out_path.write_text(
    json.dumps(
        {
            "execution_disposition": "no_mutation",
            "refund_post_count": 0,
            "reason": stage2_approval.get("zero_refund_explanation") or "approved_refund_eligible_charge_count_is_zero",
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY
else
    : > "$RUN_DIR/24_refund_attempts.tsv"
    while IFS=$'\t' read -r charge_id idempotency_key; do
        [ -n "${charge_id:-}" ] || continue
        [ -n "${idempotency_key:-}" ] || continue

        safe_charge_id="${charge_id//[^a-zA-Z0-9_]/_}"
        refund_body_path="$RUN_DIR/24_refund_attempts/${safe_charge_id}_refund.json"
        refund_meta_path="$RUN_DIR/24_refund_attempts/${safe_charge_id}_refund.meta.json"
        charge_body_path="$RUN_DIR/25_charge_refetches/${safe_charge_id}_charge.json"
        charge_meta_path="$RUN_DIR/25_charge_refetches/${safe_charge_id}_charge.meta.json"

        stripe_request POST "/v1/refunds" -H "Idempotency-Key: ${idempotency_key}" -d "charge=${charge_id}" || true
        printf '%s\n' "$STRIPE_BODY" > "$refund_body_path"
        python3 - "$refund_meta_path" "$charge_id" "$idempotency_key" "$STRIPE_HTTP_CODE" "$STRIPE_REQUEST_ID" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = {
    "charge_id": sys.argv[2],
    "idempotency_key": sys.argv[3],
    "refund_http_code": sys.argv[4],
    "refund_request_id": sys.argv[5],
}
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

        stripe_request GET "/v1/charges/${charge_id}" || true
        printf '%s\n' "$STRIPE_BODY" > "$charge_body_path"
        python3 - "$charge_meta_path" "$charge_id" "$STRIPE_HTTP_CODE" "$STRIPE_REQUEST_ID" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = {
    "charge_id": sys.argv[2],
    "charge_refetch_http_code": sys.argv[3],
    "charge_refetch_request_id": sys.argv[4],
}
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$charge_id" \
            "$idempotency_key" \
            "$refund_body_path" \
            "$refund_meta_path" \
            "$charge_body_path" \
            "$charge_meta_path" >> "$RUN_DIR/24_refund_attempts.tsv"
    done < <(python3 - "$RUN_DIR/20_refund_execution_plan.json" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for row in plan:
    if row.get("stage2_disposition") != "refund_eligible":
        continue
    print(f"{row.get('charge_id') or ''}\t{row.get('idempotency_key') or ''}")
PY
)
fi

python3 - "$RUN_DIR/20_refund_execution_plan.json" "$RUN_DIR/24_refund_attempts.tsv" "$RUN_DIR/30_refund_execution_dispositions.json" "$RUN_DIR/31_refund_execution_dispositions.csv" "$RUN_DIR/40_refund_execution_summary.json" "$STAGE2_APPROVAL_JSON" "$STAGE3_APPROVAL_JSON" "$RUN_DIR" <<'PY'
import csv
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
attempts_tsv = pathlib.Path(sys.argv[2])
dispositions_path = pathlib.Path(sys.argv[3])
csv_path = pathlib.Path(sys.argv[4])
summary_path = pathlib.Path(sys.argv[5])
stage2_approval = json.loads(pathlib.Path(sys.argv[6]).read_text(encoding="utf-8"))
stage3_approval = json.loads(pathlib.Path(sys.argv[7]).read_text(encoding="utf-8"))
run_dir = pathlib.Path(sys.argv[8])

attempts_by_charge = {}
if attempts_tsv.exists():
    with attempts_tsv.open("r", encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.strip()
            if not line:
                continue
            fields = line.split("\t")
            if len(fields) == 6:
                charge_id, idempotency_key, refund_body_path, refund_meta_path, charge_body_path, charge_meta_path = fields
            elif len(fields) == 4:
                charge_id, idempotency_key, refund_body_path, charge_body_path = fields
                refund_meta_path = str(pathlib.Path(refund_body_path).with_suffix(".meta.json"))
                charge_meta_path = str(pathlib.Path(charge_body_path).with_suffix(".meta.json"))
            else:
                continue
            attempts_by_charge[charge_id] = {
                "idempotency_key": idempotency_key,
                "refund_body_path": pathlib.Path(refund_body_path),
                "refund_meta_path": pathlib.Path(refund_meta_path),
                "charge_body_path": pathlib.Path(charge_body_path),
                "charge_meta_path": pathlib.Path(charge_meta_path),
            }


def parse_json_file(path: pathlib.Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


rows = []
for row in plan:
    stage2_disposition = row.get("stage2_disposition")
    charge_id = row.get("charge_id")
    idempotency_key = row.get("idempotency_key")

    execution_disposition = "no_mutation"
    execution_reason = f"stage2_disposition_{stage2_disposition}:{row.get('stage2_reason')}"
    refund_id = None
    refund_http_code = None
    post_charge_refunded = None
    post_charge_amount_refunded = None

    if stage2_disposition == "refund_eligible":
        attempt = attempts_by_charge.get(charge_id)
        if not attempt:
            execution_disposition = "execution_missing_attempt"
            execution_reason = "eligible_charge_missing_refund_attempt"
        else:
            refund_payload = parse_json_file(attempt["refund_body_path"])
            refund_meta = parse_json_file(attempt["refund_meta_path"])
            charge_payload = parse_json_file(attempt["charge_body_path"])

            refund_http_code = str(refund_meta.get("refund_http_code") or "") or None
            if refund_payload.get("object") == "refund":
                refund_id = refund_payload.get("id")
            post_charge_refunded = charge_payload.get("refunded")
            amount_refunded_raw = charge_payload.get("amount_refunded")
            post_charge_amount_refunded = int(amount_refunded_raw or 0) if amount_refunded_raw is not None else None

            if refund_http_code in {"200", "201"} and refund_id:
                execution_disposition = "refund_created"
                execution_reason = "stripe_refund_created"
            elif refund_http_code and refund_http_code.startswith("2"):
                execution_disposition = "refund_response_without_id"
                execution_reason = "stripe_refund_http_2xx_missing_refund_id"
            else:
                error_obj = refund_payload.get("error") if isinstance(refund_payload, dict) else None
                error_code = (error_obj or {}).get("code") if isinstance(error_obj, dict) else None
                if error_code in {"charge_already_refunded", "charge_already_disputed"}:
                    execution_disposition = "already_refunded_noop"
                    execution_reason = f"stripe_error_code_{error_code}"
                else:
                    execution_disposition = "refund_request_failed"
                    execution_reason = f"stripe_refund_http_{refund_http_code or 'unknown'}"

    rows.append(
        {
            "customer_id": row.get("customer_id"),
            "email": row.get("email"),
            "stripe_customer_id": row.get("stripe_customer_id"),
            "charge_id": charge_id,
            "idempotency_key": idempotency_key,
            "stage2_disposition": stage2_disposition,
            "execution_disposition": execution_disposition,
            "execution_reason": execution_reason,
            "refund_id": refund_id,
            "refund_http_code": refund_http_code,
            "post_charge_refunded": post_charge_refunded,
            "post_charge_amount_refunded": post_charge_amount_refunded,
        }
    )

dispositions_path.write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")

csv_fields = [
    "customer_id",
    "email",
    "stripe_customer_id",
    "charge_id",
    "idempotency_key",
    "stage2_disposition",
    "execution_disposition",
    "execution_reason",
    "refund_id",
    "refund_http_code",
    "post_charge_refunded",
    "post_charge_amount_refunded",
]
with csv_path.open("w", encoding="utf-8", newline="") as fh:
    writer = csv.DictWriter(fh, fieldnames=csv_fields)
    writer.writeheader()
    for row in rows:
        writer.writerow({field: row.get(field) for field in csv_fields})

approved_charge_count = int(stage3_approval.get("refund_eligible_charge_count", 0) or 0)
approved_total_cents = int(stage3_approval.get("refund_total_cents", 0) or 0)
refund_attempt_dispositions = {
    "refund_created",
    "refund_response_without_id",
    "already_refunded_noop",
    "refund_request_failed",
}
refund_post_count = sum(1 for row in rows if row.get("execution_disposition") in refund_attempt_dispositions)
created_refund_count = sum(1 for row in rows if row.get("execution_disposition") == "refund_created")
no_op_count = sum(1 for row in rows if row.get("execution_disposition") in {"no_mutation", "already_refunded_noop"})
post_refetch_refunded_total_cents = sum(int(row.get("post_charge_amount_refunded") or 0) for row in rows if row.get("post_charge_amount_refunded") is not None)

summary = {
    "approved_refund_eligible_charge_count": approved_charge_count,
    "approved_refund_total_cents": approved_total_cents,
    "refund_post_count": refund_post_count,
    "created_refund_count": created_refund_count,
    "no_op_count": no_op_count,
    "post_refetch_refunded_total_cents": post_refetch_refunded_total_cents,
    "zero_refund_explanation": stage2_approval.get("zero_refund_explanation", ""),
    "run_dir": str(run_dir),
}
summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
PY

if [ "$RUN_LABEL" = "primary" ]; then
    cp "$RUN_DIR/10_validate_stripe_live_cutover.json" "$SCRIPT_DIR/10_validate_stripe_live_cutover_primary.json"
    cp "$RUN_DIR/20_refund_execution_plan.json" "$SCRIPT_DIR/20_refund_execution_plan.json"
    cp "$RUN_DIR/21_plan_lineage_validation.txt" "$SCRIPT_DIR/21_plan_lineage_validation.txt"
    cp "$RUN_DIR/22_plan_totals_validation.txt" "$SCRIPT_DIR/22_plan_totals_validation.txt"
    if [ -f "$RUN_DIR/23_no_mutation_execution.json" ]; then
        cp "$RUN_DIR/23_no_mutation_execution.json" "$SCRIPT_DIR/23_no_mutation_execution.json"
    fi
    cp "$RUN_DIR/30_refund_execution_dispositions.json" "$SCRIPT_DIR/30_refund_execution_dispositions.json"
    cp "$RUN_DIR/31_refund_execution_dispositions.csv" "$SCRIPT_DIR/31_refund_execution_dispositions.csv"
    cp "$RUN_DIR/40_refund_execution_summary.json" "$SCRIPT_DIR/40_refund_execution_summary.json"
fi

if [ "$RUN_LABEL" = "rerun" ]; then
    cp "$RUN_DIR/10_validate_stripe_live_cutover.json" "$SCRIPT_DIR/11_validate_stripe_live_cutover_rerun.json"

    python3 - "$SCRIPT_DIR/runs/primary/20_refund_execution_plan.json" "$RUN_DIR/20_refund_execution_plan.json" "$SCRIPT_DIR/runs/primary/30_refund_execution_dispositions.json" "$RUN_DIR/30_refund_execution_dispositions.json" "$SCRIPT_DIR/runs/primary/40_refund_execution_summary.json" "$RUN_DIR/40_refund_execution_summary.json" "$SCRIPT_DIR/50_reproducibility_check.txt" "$SCRIPT_DIR/runs/primary/23_no_mutation_execution.json" "$RUN_DIR/23_no_mutation_execution.json" <<'PY'
import json
import pathlib
import sys

primary_plan = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
rerun_plan = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
primary_dispositions = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
rerun_dispositions = json.loads(pathlib.Path(sys.argv[4]).read_text(encoding="utf-8"))
primary_summary = json.loads(pathlib.Path(sys.argv[5]).read_text(encoding="utf-8"))
rerun_summary = json.loads(pathlib.Path(sys.argv[6]).read_text(encoding="utf-8"))
out_path = pathlib.Path(sys.argv[7])
primary_nomut_path = pathlib.Path(sys.argv[8])
rerun_nomut_path = pathlib.Path(sys.argv[9])


def map_plan(plan_rows):
    mapping = {}
    for row in plan_rows:
        if row.get("stage2_disposition") != "refund_eligible":
            continue
        mapping[row.get("charge_id")] = row.get("idempotency_key")
    return dict(sorted(mapping.items()))


def disposition_counts(rows):
    counts = {}
    for row in rows:
        key = row.get("execution_disposition")
        counts[key] = counts.get(key, 0) + 1
    return dict(sorted(counts.items()))


primary_idempo = map_plan(primary_plan)
rerun_idempo = map_plan(rerun_plan)

primary_refunded_total = int(primary_summary.get("post_refetch_refunded_total_cents", 0) or 0)
rerun_refunded_total = int(rerun_summary.get("post_refetch_refunded_total_cents", 0) or 0)

primary_counts = disposition_counts(primary_dispositions)
rerun_counts = disposition_counts(rerun_dispositions)

checks = {
    "approved_charge_ids_match": sorted(primary_idempo.keys()) == sorted(rerun_idempo.keys()),
    "deterministic_idempotency_keys_match": primary_idempo == rerun_idempo,
    "execution_disposition_counts_match": primary_counts == rerun_counts,
    "post_refetch_refunded_totals_match": primary_refunded_total == rerun_refunded_total,
    "refund_post_count_match": int(primary_summary.get("refund_post_count", 0) or 0) == int(rerun_summary.get("refund_post_count", 0) or 0),
}

if int(primary_summary.get("approved_refund_eligible_charge_count", 0) or 0) == 0:
    checks["zero_refund_posts_primary"] = int(primary_summary.get("refund_post_count", 0) or 0) == 0
    checks["zero_refund_posts_rerun"] = int(rerun_summary.get("refund_post_count", 0) or 0) == 0
    checks["no_mutation_artifact_primary"] = primary_nomut_path.exists()
    checks["no_mutation_artifact_rerun"] = rerun_nomut_path.exists()

lines = [
    f"primary_approved_charge_ids={json.dumps(sorted(primary_idempo.keys()))}",
    f"rerun_approved_charge_ids={json.dumps(sorted(rerun_idempo.keys()))}",
    f"primary_idempotency_keys_by_charge={json.dumps(primary_idempo, sort_keys=True)}",
    f"rerun_idempotency_keys_by_charge={json.dumps(rerun_idempo, sort_keys=True)}",
    f"primary_execution_disposition_counts={json.dumps(primary_counts, sort_keys=True)}",
    f"rerun_execution_disposition_counts={json.dumps(rerun_counts, sort_keys=True)}",
    f"primary_post_refetch_refunded_total_cents={primary_refunded_total}",
    f"rerun_post_refetch_refunded_total_cents={rerun_refunded_total}",
]
for key, value in checks.items():
    lines.append(f"{key}={str(bool(value)).lower()}")

if all(checks.values()):
    lines.append("reproducibility=PASS")
else:
    lines.append("reproducibility=FAIL")

out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
if not all(checks.values()):
    raise SystemExit(1)
PY
fi

echo "Stage 3 refund execution run complete: $RUN_DIR"
