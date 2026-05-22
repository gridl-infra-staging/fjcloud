#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="/Users/stuart/parallel_development/fjcloud_dev/may21_12pm_2_prod_db_leak_cleanup/fjcloud_dev"
cd "$REPO_ROOT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE1_DIR="$REPO_ROOT/docs/runbooks/evidence/prod_db_leak_cleanup/20260521T172106Z_stage1_inventory"
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

RUN_DIR="$SCRIPT_DIR/runs/$RUN_LABEL"
mkdir -p "$RUN_DIR/20_charge_pages"

source "$REPO_ROOT/scripts/lib/env.sh"
source "$REPO_ROOT/scripts/lib/stripe_account.sh"
source "$REPO_ROOT/scripts/lib/stripe_request.sh"

load_layered_env_files "$SECRET_FILE"
stripe_account_resolve_secret_key "flapjack_cloud"

STRIPE_SECRET_KEY_EFFECTIVE="${STRIPE_SECRET_KEY}"
export STRIPE_SECRET_KEY_EFFECTIVE
STRIPE_API_BASE="https://api.stripe.com"
export STRIPE_API_BASE

PRIMARY_DISPOSITIONS_JSON="$SCRIPT_DIR/31_refund_dispositions.json"
PRIMARY_SUMMARY_JSON="$SCRIPT_DIR/40_refund_proposal_summary.json"
PRIMARY_DISPOSITIONS_CSV="$SCRIPT_DIR/30_refund_dispositions.csv"
PRIMARY_VALIDATION_COVERAGE="$SCRIPT_DIR/42_validation_coverage.txt"
PRIMARY_VALIDATION_TOTALS="$SCRIPT_DIR/43_validation_summary_totals.txt"
PRIMARY_APPROVAL_JSON="$SCRIPT_DIR/41_operator_approval_input.json"

python3 - "$STAGE1_DIR/40_stage1_summary.json" "$STAGE1_DIR/10_prod_exact_cleanup.csv" "$RUN_DIR/11_exact_rows.json" <<'PY'
import csv
import json
import pathlib
import sys

summary_path = pathlib.Path(sys.argv[1])
csv_path = pathlib.Path(sys.argv[2])
out_rows_path = pathlib.Path(sys.argv[3])

summary = json.loads(summary_path.read_text(encoding="utf-8"))
with csv_path.open("r", encoding="utf-8", newline="") as fh:
    rows = list(csv.DictReader(fh))

summary_customer_ids = sorted(summary.get("prod", {}).get("customer_ids", []))
csv_customer_ids = sorted({(row.get("customer_id") or "").strip() for row in rows if (row.get("customer_id") or "").strip()})

if summary_customer_ids != csv_customer_ids:
    missing_from_csv = sorted(set(summary_customer_ids) - set(csv_customer_ids))
    missing_from_summary = sorted(set(csv_customer_ids) - set(summary_customer_ids))
    raise SystemExit(
        "Stage 1 prod exact-customer mismatch between 40_stage1_summary.json and 10_prod_exact_cleanup.csv; "
        f"missing_from_csv={missing_from_csv}; missing_from_summary={missing_from_summary}"
    )

# Keep only the row owner fields required for Stage 2 scope.
trimmed_rows = []
for row in rows:
    trimmed_rows.append(
        {
            "customer_id": (row.get("customer_id") or "").strip(),
            "email": (row.get("email") or "").strip(),
            "stripe_customer_id": (row.get("stripe_customer_id") or "").strip(),
        }
    )

out_rows_path.write_text(json.dumps(trimmed_rows, indent=2) + "\n", encoding="utf-8")
PY

# The cutover preflight is required evidence that live-key auth works through
# the canonical non-mutating owner before any charge enumeration calls.
STRIPE_LIVE_CUTOVER=1 bash "$REPO_ROOT/scripts/validate-stripe.sh" --live-cutover \
    > "$RUN_DIR/10_validate_stripe_live_cutover.json"

python3 - "$RUN_DIR/11_exact_rows.json" "$RUN_DIR/12_non_null_stripe_rows.tsv" <<'PY'
import json
import pathlib
import sys

rows = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
out_path = pathlib.Path(sys.argv[2])

with out_path.open("w", encoding="utf-8") as fh:
    for row in rows:
        stripe_customer_id = (row.get("stripe_customer_id") or "").strip()
        if not stripe_customer_id:
            continue
        fh.write(
            "\t".join(
                [
                    row["customer_id"],
                    row["email"],
                    stripe_customer_id,
                ]
            )
            + "\n"
        )
PY

# Enumerate full /v1/charges pages for each exact-customer stripe id.
while IFS=$'\t' read -r customer_id email stripe_customer_id; do
    [ -n "${customer_id:-}" ] || continue

    customer_dir="$RUN_DIR/20_charge_pages/${customer_id}"
    mkdir -p "$customer_dir"

    starting_after=""
    page_index=1
    while :; do
        request_args=(
            -G
            --data-urlencode "customer=${stripe_customer_id}"
            --data-urlencode "limit=100"
        )
        if [ -n "$starting_after" ]; then
            request_args+=(--data-urlencode "starting_after=${starting_after}")
        fi

        if ! stripe_request GET "/v1/charges" "${request_args[@]}"; then
            echo "stripe_request failed for customer_id=${customer_id} stripe_customer_id=${stripe_customer_id}" >&2
            exit 1
        fi

        if [ "${STRIPE_HTTP_CODE}" != "200" ]; then
            printf '%s\n' "$STRIPE_BODY" > "$customer_dir/error_http_${STRIPE_HTTP_CODE}.json"
            echo "Stripe GET /v1/charges returned HTTP ${STRIPE_HTTP_CODE} for customer_id=${customer_id}" >&2
            exit 1
        fi

        page_tag="$(printf '%03d' "$page_index")"
        body_path="$customer_dir/page_${page_tag}.json"
        meta_path="$customer_dir/page_${page_tag}.meta.json"
        printf '%s\n' "$STRIPE_BODY" > "$body_path"

        python3 - "$meta_path" "$STRIPE_REQUEST_ID" "$customer_id" "$email" "$stripe_customer_id" "$starting_after" <<'PY'
import json
import pathlib
import sys

meta_path = pathlib.Path(sys.argv[1])
meta = {
    "stripe_request_id": sys.argv[2],
    "customer_id": sys.argv[3],
    "email": sys.argv[4],
    "stripe_customer_id": sys.argv[5],
    "starting_after": sys.argv[6],
}
meta_path.write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
PY

        readarray -t pagination < <(python3 - "$body_path" <<'PY'
import json
import pathlib
import sys

body = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
items = body.get("data", [])
has_more = bool(body.get("has_more", False))
last_charge_id = ""
if items:
    last_charge_id = str(items[-1].get("id", ""))
print("true" if has_more else "false")
print(last_charge_id)
PY
)

        has_more="${pagination[0]:-false}"
        last_charge_id="${pagination[1]:-}"
        if [ "$has_more" != "true" ]; then
            break
        fi
        if [ -z "$last_charge_id" ]; then
            echo "Stripe pagination indicated has_more=true but no last charge id for customer_id=${customer_id}" >&2
            exit 1
        fi
        starting_after="$last_charge_id"
        page_index=$((page_index + 1))
    done

done < "$RUN_DIR/12_non_null_stripe_rows.tsv"

python3 - "$STAGE1_DIR/40_stage1_summary.json" "$STAGE1_DIR/10_prod_exact_cleanup.csv" "$RUN_DIR" <<'PY'
import csv
import json
import pathlib
import sys
from collections import defaultdict
from datetime import datetime, timezone

summary_path = pathlib.Path(sys.argv[1])
csv_path = pathlib.Path(sys.argv[2])
run_dir = pathlib.Path(sys.argv[3])

summary = json.loads(summary_path.read_text(encoding="utf-8"))
with csv_path.open("r", encoding="utf-8", newline="") as fh:
    exact_rows = list(csv.DictReader(fh))

summary_customer_ids = sorted(summary.get("prod", {}).get("customer_ids", []))
summary_customer_id_set = set(summary_customer_ids)

exact_by_customer = {}
for row in exact_rows:
    customer_id = (row.get("customer_id") or "").strip()
    if not customer_id:
        continue
    exact_by_customer[customer_id] = {
        "customer_id": customer_id,
        "email": (row.get("email") or "").strip(),
        "stripe_customer_id": (row.get("stripe_customer_id") or "").strip(),
    }

if set(exact_by_customer.keys()) != summary_customer_id_set:
    missing_from_csv = sorted(summary_customer_id_set - set(exact_by_customer.keys()))
    missing_from_summary = sorted(set(exact_by_customer.keys()) - summary_customer_id_set)
    raise SystemExit(
        "Stage 1 exact customer mismatch while building Stage 2 dispositions; "
        f"missing_from_csv={missing_from_csv}; missing_from_summary={missing_from_summary}"
    )

charges_by_customer = defaultdict(list)
for customer_dir in sorted((run_dir / "20_charge_pages").glob("*")):
    if not customer_dir.is_dir():
        continue
    customer_id = customer_dir.name
    for page_file in sorted(customer_dir.glob("page_*.json")):
        body = json.loads(page_file.read_text(encoding="utf-8"))
        for charge in body.get("data", []):
            charges_by_customer[customer_id].append(charge)

# Build canonical dispositions.
dispositions = []
for customer_id in summary_customer_ids:
    row = exact_by_customer[customer_id]
    email = row["email"]
    stripe_customer_id = row["stripe_customer_id"] or None

    if not stripe_customer_id:
        dispositions.append(
            {
                "customer_id": customer_id,
                "email": email,
                "stripe_customer_id": None,
                "charge_id": None,
                "charge_created": None,
                "amount": None,
                "currency": None,
                "disposition": "no_stripe_account",
                "reason": "exact_row_has_null_stripe_customer_id",
                "livemode": None,
                "status": None,
                "amount_refunded": None,
                "refunded": None,
            }
        )
        continue

    customer_charges = charges_by_customer.get(customer_id, [])
    if not customer_charges:
        dispositions.append(
            {
                "customer_id": customer_id,
                "email": email,
                "stripe_customer_id": stripe_customer_id,
                "charge_id": None,
                "charge_created": None,
                "amount": None,
                "currency": None,
                "disposition": "no_qualifying_charges",
                "reason": "stripe_returned_no_charges",
                "livemode": None,
                "status": None,
                "amount_refunded": None,
                "refunded": None,
            }
        )
        continue

    qualifying_count = 0
    for charge in customer_charges:
        charge_id = charge.get("id")
        charge_customer = charge.get("customer")
        livemode = bool(charge.get("livemode", False))
        status = str(charge.get("status", ""))
        amount_refunded = int(charge.get("amount_refunded", 0) or 0)
        refunded = bool(charge.get("refunded", False))

        disposition = "excluded"
        reason = []

        if charge_customer != stripe_customer_id:
            reason.append("customer_mismatch")
        if not livemode:
            reason.append("not_livemode")
        if status != "succeeded":
            reason.append("status_not_succeeded")
        if amount_refunded != 0:
            reason.append("already_partially_or_fully_refunded")
        if refunded:
            reason.append("already_refunded")

        if not reason:
            disposition = "refund_eligible"
            reason_text = "eligible_live_succeeded_unrefunded"
            qualifying_count += 1
        else:
            reason_text = ",".join(reason)

        dispositions.append(
            {
                "customer_id": customer_id,
                "email": email,
                "stripe_customer_id": stripe_customer_id,
                "charge_id": charge_id,
                "charge_created": charge.get("created"),
                "amount": charge.get("amount"),
                "currency": charge.get("currency"),
                "disposition": disposition,
                "reason": reason_text,
                "livemode": livemode,
                "status": status,
                "amount_refunded": amount_refunded,
                "refunded": refunded,
            }
        )

    if qualifying_count == 0 and customer_charges:
        # Ensure at least one final row still communicates no eligibility even
        # when every returned charge was excluded.
        dispositions.append(
            {
                "customer_id": customer_id,
                "email": email,
                "stripe_customer_id": stripe_customer_id,
                "charge_id": None,
                "charge_created": None,
                "amount": None,
                "currency": None,
                "disposition": "no_qualifying_charges",
                "reason": "all_returned_charges_excluded",
                "livemode": None,
                "status": None,
                "amount_refunded": None,
                "refunded": None,
            }
        )

json_path = run_dir / "31_refund_dispositions.json"
json_path.write_text(json.dumps(dispositions, indent=2) + "\n", encoding="utf-8")

csv_path_out = run_dir / "30_refund_dispositions.csv"
csv_fields = [
    "customer_id",
    "email",
    "stripe_customer_id",
    "charge_id",
    "charge_created",
    "amount",
    "currency",
    "disposition",
    "reason",
]

with csv_path_out.open("w", encoding="utf-8", newline="") as fh:
    writer = csv.DictWriter(fh, fieldnames=csv_fields)
    writer.writeheader()
    for row in dispositions:
        writer.writerow({field: row.get(field) for field in csv_fields})

eligible_rows = [row for row in dispositions if row.get("disposition") == "refund_eligible"]
refund_total_cents = sum(int(row.get("amount") or 0) for row in eligible_rows)

eligible_ids_by_customer = defaultdict(list)
for row in eligible_rows:
    eligible_ids_by_customer[row["customer_id"]].append(row["charge_id"])

for customer_id in list(eligible_ids_by_customer.keys()):
    eligible_ids_by_customer[customer_id] = sorted(eligible_ids_by_customer[customer_id])

customers_no_stripe = sorted(
    {
        row["customer_id"]
        for row in dispositions
        if row.get("disposition") == "no_stripe_account"
    }
)

customers_no_qualifying = sorted(
    {
        row["customer_id"]
        for row in dispositions
        if row.get("disposition") == "no_qualifying_charges"
    }
)

proposal_summary = {
    "generated_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "stage1_sources": {
        "summary_json": str(summary_path),
        "exact_csv": str(csv_path),
    },
    "run_label": run_dir.name,
    "exact_customer_count": len(summary_customer_ids),
    "customers_with_no_stripe_account_count": len(customers_no_stripe),
    "customers_with_no_stripe_account": customers_no_stripe,
    "customers_with_no_qualifying_charges_count": len(customers_no_qualifying),
    "customers_with_no_qualifying_charges": customers_no_qualifying,
    "refund_eligible_charge_count": len(eligible_rows),
    "refund_total_cents": refund_total_cents,
    "refund_eligible_charge_ids_by_customer": dict(sorted(eligible_ids_by_customer.items())),
}

summary_out = run_dir / "40_refund_proposal_summary.json"
summary_out.write_text(json.dumps(proposal_summary, indent=2) + "\n", encoding="utf-8")

# Validation step 1: coverage + lineage + JSON->CSV row equivalence.
failures = []
dispositions_customer_ids = {row.get("customer_id") for row in dispositions if row.get("customer_id")}
missing_customers = sorted(summary_customer_id_set - dispositions_customer_ids)
if missing_customers:
    failures.append(f"missing_customers_in_dispositions={missing_customers}")

allowed_stripe_customer_ids = {
    row["stripe_customer_id"]
    for row in exact_by_customer.values()
    if row["stripe_customer_id"]
}

for row in dispositions:
    stripe_customer_id = row.get("stripe_customer_id")
    if stripe_customer_id and stripe_customer_id not in allowed_stripe_customer_ids:
        failures.append(
            f"disposition_stripe_customer_not_in_exact_csv:customer_id={row.get('customer_id')},stripe_customer_id={stripe_customer_id}"
        )

# Proposed charge rows must trace back to an exact customer row and matching stripe id.
for row in eligible_rows:
    customer_id = row.get("customer_id")
    charge_id = row.get("charge_id")
    exact = exact_by_customer.get(customer_id)
    if not exact:
        failures.append(f"eligible_charge_without_exact_customer:charge_id={charge_id},customer_id={customer_id}")
        continue
    expected_stripe = exact.get("stripe_customer_id")
    if expected_stripe != row.get("stripe_customer_id"):
        failures.append(
            "eligible_charge_stripe_customer_mismatch:"
            f"charge_id={charge_id},customer_id={customer_id},expected={expected_stripe},actual={row.get('stripe_customer_id')}"
        )

with csv_path_out.open("r", encoding="utf-8", newline="") as fh:
    csv_rows = list(csv.DictReader(fh))

normalized_json_rows = []
for row in dispositions:
    normalized_json_rows.append(
        {
            field: "" if row.get(field) is None else str(row.get(field))
            for field in csv_fields
        }
    )

normalized_csv_rows = []
for row in csv_rows:
    normalized_csv_rows.append({field: (row.get(field) or "") for field in csv_fields})

if normalized_json_rows != normalized_csv_rows:
    failures.append("csv_rowset_mismatch_against_canonical_json")

coverage_result = "coverage_validation=PASS"
if failures:
    coverage_result = "coverage_validation=FAIL\n" + "\n".join(failures)
    (run_dir / "42_validation_coverage.txt").write_text(coverage_result + "\n", encoding="utf-8")
    raise SystemExit(1)

(run_dir / "42_validation_coverage.txt").write_text(coverage_result + "\n", encoding="utf-8")

# Validation step 2: recompute totals and predicate integrity from canonical JSON.
validation_failures = []
recomputed_charge_count = 0
recomputed_total = 0

for row in eligible_rows:
    recomputed_charge_count += 1
    recomputed_total += int(row.get("amount") or 0)

    if row.get("livemode") is not True:
        validation_failures.append(f"eligible_charge_not_livemode:charge_id={row.get('charge_id')}")
    if row.get("status") != "succeeded":
        validation_failures.append(f"eligible_charge_not_succeeded:charge_id={row.get('charge_id')},status={row.get('status')}")
    if int(row.get("amount_refunded") or 0) != 0:
        validation_failures.append(f"eligible_charge_amount_refunded_nonzero:charge_id={row.get('charge_id')}")
    if row.get("refunded") is not False:
        validation_failures.append(f"eligible_charge_refunded_true:charge_id={row.get('charge_id')}")

if recomputed_charge_count != int(proposal_summary["refund_eligible_charge_count"]):
    validation_failures.append(
        "refund_eligible_charge_count_mismatch:"
        f"summary={proposal_summary['refund_eligible_charge_count']},recomputed={recomputed_charge_count}"
    )
if recomputed_total != int(proposal_summary["refund_total_cents"]):
    validation_failures.append(
        f"refund_total_cents_mismatch:summary={proposal_summary['refund_total_cents']},recomputed={recomputed_total}"
    )

totals_result = "summary_totals_validation=PASS"
if validation_failures:
    totals_result = "summary_totals_validation=FAIL\n" + "\n".join(validation_failures)
    (run_dir / "43_validation_summary_totals.txt").write_text(totals_result + "\n", encoding="utf-8")
    raise SystemExit(1)

(run_dir / "43_validation_summary_totals.txt").write_text(totals_result + "\n", encoding="utf-8")

approval = {
    "generated_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "derived_from_summary": str(summary_out),
    "evidence_files": {
        "canonical_dispositions_json": str(json_path),
        "canonical_dispositions_csv": str(csv_path_out),
        "validation_coverage": str(run_dir / "42_validation_coverage.txt"),
        "validation_summary_totals": str(run_dir / "43_validation_summary_totals.txt"),
    },
    "exact_customer_count": proposal_summary["exact_customer_count"],
    "refund_eligible_charge_count": proposal_summary["refund_eligible_charge_count"],
    "refund_total_cents": proposal_summary["refund_total_cents"],
    "refund_eligible_charge_ids_by_customer": proposal_summary["refund_eligible_charge_ids_by_customer"],
    "zero_refund_explanation": ""
    if proposal_summary["refund_eligible_charge_count"] > 0
    else "All exact prod cohort rows have null stripe_customer_id in Stage 1 exact CSV; Stage 2 correctly emits no_stripe_account dispositions and proposes zero refunds.",
}

(run_dir / "41_operator_approval_input.json").write_text(json.dumps(approval, indent=2) + "\n", encoding="utf-8")
PY

if [ "$RUN_LABEL" = "primary" ]; then
    cp "$RUN_DIR/30_refund_dispositions.csv" "$PRIMARY_DISPOSITIONS_CSV"
    cp "$RUN_DIR/31_refund_dispositions.json" "$PRIMARY_DISPOSITIONS_JSON"
    cp "$RUN_DIR/40_refund_proposal_summary.json" "$PRIMARY_SUMMARY_JSON"
    cp "$RUN_DIR/41_operator_approval_input.json" "$PRIMARY_APPROVAL_JSON"
    cp "$RUN_DIR/42_validation_coverage.txt" "$PRIMARY_VALIDATION_COVERAGE"
    cp "$RUN_DIR/43_validation_summary_totals.txt" "$PRIMARY_VALIDATION_TOTALS"
    cp "$RUN_DIR/10_validate_stripe_live_cutover.json" "$SCRIPT_DIR/10_validate_stripe_live_cutover_primary.json"
fi

if [ "$RUN_LABEL" = "rerun" ]; then
    if [ ! -f "$PRIMARY_DISPOSITIONS_JSON" ] || [ ! -f "$PRIMARY_SUMMARY_JSON" ]; then
        echo "Primary run artifacts missing; run $0 primary before rerun reproducibility check" >&2
        exit 1
    fi

    python3 - "$PRIMARY_DISPOSITIONS_JSON" "$RUN_DIR/31_refund_dispositions.json" "$PRIMARY_SUMMARY_JSON" "$RUN_DIR/40_refund_proposal_summary.json" "$SCRIPT_DIR/50_reproducibility_check.txt" <<'PY'
import json
import pathlib
import sys

primary_dispositions = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
rerun_dispositions = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
primary_summary = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
rerun_summary = json.loads(pathlib.Path(sys.argv[4]).read_text(encoding="utf-8"))
out_path = pathlib.Path(sys.argv[5])


def eligible_ids_by_customer(dispositions):
    mapping = {}
    for row in dispositions:
        if row.get("disposition") != "refund_eligible":
            continue
        customer_id = row.get("customer_id")
        mapping.setdefault(customer_id, []).append(row.get("charge_id"))
    for customer_id in list(mapping.keys()):
        mapping[customer_id] = sorted(mapping[customer_id])
    return dict(sorted(mapping.items()))

primary_coverage = sorted({row.get("customer_id") for row in primary_dispositions if row.get("customer_id")})
rerun_coverage = sorted({row.get("customer_id") for row in rerun_dispositions if row.get("customer_id")})

primary_ids = eligible_ids_by_customer(primary_dispositions)
rerun_ids = eligible_ids_by_customer(rerun_dispositions)

checks = {
    "customer_coverage_match": primary_coverage == rerun_coverage,
    "refund_eligible_charge_count_match": int(primary_summary.get("refund_eligible_charge_count", 0)) == int(rerun_summary.get("refund_eligible_charge_count", 0)),
    "refund_total_cents_match": int(primary_summary.get("refund_total_cents", 0)) == int(rerun_summary.get("refund_total_cents", 0)),
    "proposed_charge_ids_by_customer_match": primary_ids == rerun_ids,
}

lines = [
    f"primary_run_label={primary_summary.get('run_label')}",
    f"rerun_run_label={rerun_summary.get('run_label')}",
    f"primary_exact_customer_count={primary_summary.get('exact_customer_count')}",
    f"rerun_exact_customer_count={rerun_summary.get('exact_customer_count')}",
    f"primary_refund_eligible_charge_count={primary_summary.get('refund_eligible_charge_count')}",
    f"rerun_refund_eligible_charge_count={rerun_summary.get('refund_eligible_charge_count')}",
    f"primary_refund_total_cents={primary_summary.get('refund_total_cents')}",
    f"rerun_refund_total_cents={rerun_summary.get('refund_total_cents')}",
    f"customer_coverage_match={str(checks['customer_coverage_match']).lower()}",
    f"proposed_charge_ids_by_customer_match={str(checks['proposed_charge_ids_by_customer_match']).lower()}",
    f"primary_charge_ids_by_customer={json.dumps(primary_ids, sort_keys=True)}",
    f"rerun_charge_ids_by_customer={json.dumps(rerun_ids, sort_keys=True)}",
]

if all(checks.values()):
    lines.append("reproducibility=PASS")
else:
    lines.append("reproducibility=FAIL")

out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

if not all(checks.values()):
    raise SystemExit(1)
PY

    cp "$RUN_DIR/10_validate_stripe_live_cutover.json" "$SCRIPT_DIR/11_validate_stripe_live_cutover_rerun.json"
fi

echo "Stage 2 refund proposal run complete: $RUN_DIR"
