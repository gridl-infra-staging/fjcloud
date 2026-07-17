#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="fjcloud_dev"
cd "$REPO_ROOT"

EVID_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_FILE="${FJCLOUD_SECRET_FILE:-$PWD/.secret/.env.secret}"
MATT_DIR="/Users/stuart/.matt/projects/fjcloud_dev-42da0c0f/may21_12pm_2_prod_db_leak_cleanup.md-aa5c19e4"
PYTHONPATH_ROOT="/Users/stuart/repos/gridl/mike_dev/matt_root"
VALIDATION_COMMAND="bash scripts/tests/staging_db_test.sh"

source scripts/lib/env.sh
source scripts/lib/staging_db.sh

load_layered_env_files "$SECRET_FILE"

: "${AWS_DEFAULT_REGION:=us-east-1}"
export AWS_DEFAULT_REGION

HEAD_SHA="$(git rev-parse HEAD)"
if git diff --quiet && git diff --cached --quiet; then
    CLEAN_TREE="true"
else
    CLEAN_TREE="false"
fi
CACHE_HIT_PATH="$EVID_DIR/02_staging_db_test_cache_hit.txt"

cache_hit="$({
  PYTHONPATH="$PYTHONPATH_ROOT" python3 - "$MATT_DIR" "$VALIDATION_COMMAND" "$HEAD_SHA" "$CLEAN_TREE" <<"PY"
import sys
from matt import validation_cache

matt_dir, command, head_sha, clean_tree_raw = sys.argv[1:]
clean_tree = clean_tree_raw.lower() == "true"
entry = validation_cache.check(matt_dir, command, head_sha, clean_tree)
print("hit" if entry else "miss")
PY
} || echo "miss")"

echo "$cache_hit" > "$CACHE_HIT_PATH"

if [ "$cache_hit" = "hit" ]; then
    echo "validation cache hit for $VALIDATION_COMMAND at HEAD $HEAD_SHA" > "$EVID_DIR/02_staging_db_test_stdout.txt"
    : > "$EVID_DIR/02_staging_db_test_stderr.txt"
else
    set +e
    bash scripts/tests/staging_db_test.sh > "$EVID_DIR/02_staging_db_test_stdout.txt" 2> "$EVID_DIR/02_staging_db_test_stderr.txt"
    test_rc=$?
    set -e
    passed="false"
    if [ "$test_rc" -eq 0 ]; then
        passed="true"
    fi
    summary="staging_db_test exit=$test_rc"
    PYTHONPATH="$PYTHONPATH_ROOT" python3 - "$MATT_DIR" "$VALIDATION_COMMAND" "$HEAD_SHA" "$CLEAN_TREE" "$passed" "$summary" "$EVID_DIR" <<"PY"
import sys
from matt import validation_cache

matt_dir, command, head_sha, clean_tree_raw, passed_raw, summary, session_id = sys.argv[1:]
validation_cache.record(
    matt_dir,
    command,
    head_sha,
    clean_tree_raw.lower() == "true",
    passed_raw.lower() == "true",
    summary,
    session_id,
)
PY
    if [ "$test_rc" -ne 0 ]; then
        echo "staging_db_test failed; see $EVID_DIR/02_staging_db_test_stdout.txt and $EVID_DIR/02_staging_db_test_stderr.txt" >&2
        exit "$test_rc"
    fi
fi

aws sts get-caller-identity > "$EVID_DIR/01_aws_sts_get_caller_identity.json"

PROD_DATABASE_URL="$(aws ssm get-parameter --name /fjcloud/prod/database_url --with-decryption --query Parameter.Value --output text --region "$AWS_DEFAULT_REGION")"
STAGING_DATABASE_URL="$(aws ssm get-parameter --name /fjcloud/staging/database_url --with-decryption --query Parameter.Value --output text --region "$AWS_DEFAULT_REGION")"

if [ -z "$PROD_DATABASE_URL" ] || [ "$PROD_DATABASE_URL" = "None" ]; then
    echo "Failed to resolve /fjcloud/prod/database_url" >&2
    exit 1
fi
if [ -z "$STAGING_DATABASE_URL" ] || [ "$STAGING_DATABASE_URL" = "None" ]; then
    echo "Failed to resolve /fjcloud/staging/database_url" >&2
    exit 1
fi

run_sql_capture() {
    local env_name="$1"
    local db_url="$2"
    local ssm_param="$3"
    local sql="$4"
    local stdout_file="$5"
    local stderr_file="$6"

    DATABASE_URL_SSM_PARAM="$ssm_param"
    export DATABASE_URL_SSM_PARAM
    staging_db_run_sql "$db_url" "$sql" > "$stdout_file" 2> "$stderr_file"
}

capture_schema() {
    local env_name="$1"
    local db_url="$2"
    local ssm_param="$3"

    run_sql_capture "$env_name" "$db_url" "$ssm_param" "\\d customers" "$EVID_DIR/03_${env_name}_schema_customers.txt" "$EVID_DIR/03_${env_name}_schema_customers.stderr.txt"
    run_sql_capture "$env_name" "$db_url" "$ssm_param" "\\d customer_tenants" "$EVID_DIR/04_${env_name}_schema_customer_tenants.txt" "$EVID_DIR/04_${env_name}_schema_customer_tenants.stderr.txt"
    run_sql_capture "$env_name" "$db_url" "$ssm_param" "\\d customer_deployments" "$EVID_DIR/05_${env_name}_schema_customer_deployments.txt" "$EVID_DIR/05_${env_name}_schema_customer_deployments.stderr.txt"
}

cat > "$EVID_DIR/06_filter_contract.txt" <<"CONTRACT"
exact_filter=email LIKE 'signup-paid-%@e2e.griddle.test'
canary_filter=email LIKE 'canary+%@test.flapjack.foo'
suspicious_filter=(email LIKE '%test%' OR email LIKE '%example%') excluding exact and canary
created_at_floor=customers.created_at >= '2026-05-14'
source_fixture=web/tests/fixtures/fixtures.ts::buildFreshSignupIdentity
source_canary=scripts/lib/customer_lifecycle_steps.sh::run_signup_step
source_db_owner=scripts/lib/staging_db.sh::staging_db_run_sql
CONTRACT

cat infra/migrations/001_customers.sql infra/migrations/002_deployments.sql infra/migrations/009_deployment_extensions.sql infra/migrations/040_customers_deleted_at.sql > "$EVID_DIR/07_schema_owner_migrations.sql"

BASE_SELECT="SELECT
  c.id::text AS customer_id,
  c.email,
  c.status,
  c.deleted_at,
  c.stripe_customer_id,
  ct.tenant_id,
  cd.id::text AS deployment_id,
  cd.status AS deployment_status,
  cd.provider_vm_id,
  cd.hostname,
  cd.flapjack_url,
  cd.ip_address,
  c.created_at
FROM customers c
LEFT JOIN customer_tenants ct ON ct.customer_id = c.id
LEFT JOIN customer_deployments cd ON cd.id = ct.deployment_id"

BASE_WHERE="c.created_at >= '2026-05-14'::timestamptz"
EXACT_FILTER="c.email LIKE 'signup-paid-%@e2e.griddle.test'"
CANARY_FILTER="c.email LIKE 'canary+%@test.flapjack.foo'"
SUSPICIOUS_FILTER="(c.email LIKE '%test%' OR c.email LIKE '%example%') AND NOT (c.email LIKE 'signup-paid-%@e2e.griddle.test') AND NOT (c.email LIKE 'canary+%@test.flapjack.foo')"
ORDER_BY="ORDER BY c.created_at, c.id, ct.tenant_id, cd.id"

build_copy_sql() {
    local filter_sql="$1"
    printf "COPY (\n%s\nWHERE %s AND %s\n%s\n) TO STDOUT WITH CSV HEADER;" "$BASE_SELECT" "$BASE_WHERE" "$filter_sql" "$ORDER_BY"
}

capture_schema "prod" "$PROD_DATABASE_URL" "/fjcloud/prod/database_url"
capture_schema "staging" "$STAGING_DATABASE_URL" "/fjcloud/staging/database_url"

run_sql_capture "prod" "$PROD_DATABASE_URL" "/fjcloud/prod/database_url" "$(build_copy_sql "$EXACT_FILTER")" "$EVID_DIR/10_prod_exact_cleanup.csv" "$EVID_DIR/10_prod_exact_cleanup.stderr.txt"
run_sql_capture "staging" "$STAGING_DATABASE_URL" "/fjcloud/staging/database_url" "$(build_copy_sql "$EXACT_FILTER")" "$EVID_DIR/11_staging_exact_cleanup.csv" "$EVID_DIR/11_staging_exact_cleanup.stderr.txt"

run_sql_capture "prod" "$PROD_DATABASE_URL" "/fjcloud/prod/database_url" "$(build_copy_sql "$SUSPICIOUS_FILTER")" "$EVID_DIR/20_prod_suspicious_inventory.csv" "$EVID_DIR/20_prod_suspicious_inventory.stderr.txt"
run_sql_capture "staging" "$STAGING_DATABASE_URL" "/fjcloud/staging/database_url" "$(build_copy_sql "$SUSPICIOUS_FILTER")" "$EVID_DIR/21_staging_suspicious_inventory.csv" "$EVID_DIR/21_staging_suspicious_inventory.stderr.txt"

run_sql_capture "prod" "$PROD_DATABASE_URL" "/fjcloud/prod/database_url" "$(build_copy_sql "$CANARY_FILTER")" "$EVID_DIR/30_prod_canary_control.csv" "$EVID_DIR/30_prod_canary_control.stderr.txt"
run_sql_capture "staging" "$STAGING_DATABASE_URL" "/fjcloud/staging/database_url" "$(build_copy_sql "$CANARY_FILTER")" "$EVID_DIR/31_staging_canary_control.csv" "$EVID_DIR/31_staging_canary_control.stderr.txt"

python3 - "$EVID_DIR" <<"PY"
import csv
import json
import pathlib
import sys

out_dir = pathlib.Path(sys.argv[1])


def read_rows(path: pathlib.Path):
    with path.open("r", encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))


def unique_nonempty(rows, column):
    return sorted({(row.get(column) or "").strip() for row in rows if (row.get(column) or "").strip()})


def build_env_summary(prefix: str):
    exact = read_rows(out_dir / f"10_{prefix}_exact_cleanup.csv") if prefix == "prod" else read_rows(out_dir / f"11_{prefix}_exact_cleanup.csv")
    suspicious = read_rows(out_dir / f"20_{prefix}_suspicious_inventory.csv") if prefix == "prod" else read_rows(out_dir / f"21_{prefix}_suspicious_inventory.csv")
    canary = read_rows(out_dir / f"30_{prefix}_canary_control.csv") if prefix == "prod" else read_rows(out_dir / f"31_{prefix}_canary_control.csv")

    return {
        "counts": {
            "exact_rows": len(exact),
            "suspicious_rows": len(suspicious),
            "canary_rows": len(canary),
        },
        "customer_ids": unique_nonempty(exact, "customer_id"),
        "stripe_customer_ids": unique_nonempty(exact, "stripe_customer_id"),
        "tenant_ids": unique_nonempty(exact, "tenant_id"),
        "deployment_ids": unique_nonempty(exact, "deployment_id"),
    }

summary = {
    "generated_at_utc": __import__("datetime").datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
    "filters": {
        "created_at_floor": "customers.created_at >= '2026-05-14'",
        "exact": "email LIKE 'signup-paid-%@e2e.griddle.test'",
        "canary": "email LIKE 'canary+%@test.flapjack.foo'",
        "suspicious": "(email LIKE '%test%' OR email LIKE '%example%') excluding exact and canary",
    },
    "prod": build_env_summary("prod"),
    "staging": build_env_summary("staging"),
}

(out_dir / "40_stage1_summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
PY

python3 - "$EVID_DIR" <<"PY"
import csv
import pathlib
import sys

out_dir = pathlib.Path(sys.argv[1])


def read_rows(name):
    with (out_dir / name).open("r", encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))


def id_set(rows):
    return {(row.get("customer_id") or "").strip() for row in rows if (row.get("customer_id") or "").strip()}


def email_set(rows):
    return {(row.get("email") or "").strip() for row in rows if (row.get("email") or "").strip()}

failures = []

for env in ("prod", "staging"):
    exact_file = f"10_{env}_exact_cleanup.csv" if env == "prod" else f"11_{env}_exact_cleanup.csv"
    suspicious_file = f"20_{env}_suspicious_inventory.csv" if env == "prod" else f"21_{env}_suspicious_inventory.csv"
    canary_file = f"30_{env}_canary_control.csv" if env == "prod" else f"31_{env}_canary_control.csv"

    exact_rows = read_rows(exact_file)
    suspicious_rows = read_rows(suspicious_file)
    canary_rows = read_rows(canary_file)

    exact_ids, suspicious_ids, canary_ids = id_set(exact_rows), id_set(suspicious_rows), id_set(canary_rows)
    exact_emails, suspicious_emails, canary_emails = email_set(exact_rows), email_set(suspicious_rows), email_set(canary_rows)

    overlap_checks = [
        ("exact_vs_suspicious_customer_id", exact_ids & suspicious_ids),
        ("exact_vs_canary_customer_id", exact_ids & canary_ids),
        ("suspicious_vs_canary_customer_id", suspicious_ids & canary_ids),
        ("exact_vs_suspicious_email", exact_emails & suspicious_emails),
        ("exact_vs_canary_email", exact_emails & canary_emails),
        ("suspicious_vs_canary_email", suspicious_emails & canary_emails),
    ]

    for name, overlap in overlap_checks:
        if overlap:
            failures.append(f"{env}:{name}: overlap={sorted(overlap)}")

    canary_exact = [row.get("email", "") for row in canary_rows if row.get("email", "").startswith("signup-paid-") and row.get("email", "").endswith("@e2e.griddle.test")]
    if canary_exact:
        failures.append(f"{env}:canary_matches_exact_filter:{canary_exact}")

output_lines = ["cohort_disjointness=PASS"]
if failures:
    output_lines = ["cohort_disjointness=FAIL"] + failures
    (out_dir / "50_cohort_disjointness.txt").write_text("\n".join(output_lines) + "\n", encoding="utf-8")
    raise SystemExit(1)

(out_dir / "50_cohort_disjointness.txt").write_text("\n".join(output_lines) + "\n", encoding="utf-8")
PY

python3 - "$EVID_DIR" <<"PY"
import csv
import json
import pathlib
import sys

out_dir = pathlib.Path(sys.argv[1])
summary = json.loads((out_dir / "40_stage1_summary.json").read_text(encoding="utf-8"))

failures = []

def read_exact(path):
    with path.open("r", encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))

for env, exact_file in (("prod", "10_prod_exact_cleanup.csv"), ("staging", "11_staging_exact_cleanup.csv")):
    rows = read_exact(out_dir / exact_file)
    csv_sets = {
        "customer_ids": sorted({(row.get("customer_id") or "").strip() for row in rows if (row.get("customer_id") or "").strip()}),
        "stripe_customer_ids": sorted({(row.get("stripe_customer_id") or "").strip() for row in rows if (row.get("stripe_customer_id") or "").strip()}),
        "tenant_ids": sorted({(row.get("tenant_id") or "").strip() for row in rows if (row.get("tenant_id") or "").strip()}),
        "deployment_ids": sorted({(row.get("deployment_id") or "").strip() for row in rows if (row.get("deployment_id") or "").strip()}),
    }
    for key in ("customer_ids", "stripe_customer_ids", "tenant_ids", "deployment_ids"):
        summary_values = sorted(summary.get(env, {}).get(key, []))
        csv_values = csv_sets[key]
        missing_from_csv = sorted(set(summary_values) - set(csv_values))
        missing_from_summary = sorted(set(csv_values) - set(summary_values))
        if missing_from_csv:
            failures.append(f"{env}:{key}:summary_has_values_not_in_exact_csv:{missing_from_csv}")
        if missing_from_summary:
            failures.append(f"{env}:{key}:exact_csv_has_values_missing_from_summary:{missing_from_summary}")

if failures:
    (out_dir / "51_summary_validation.txt").write_text("summary_validation=FAIL\n" + "\n".join(failures) + "\n", encoding="utf-8")
    raise SystemExit(1)

(out_dir / "51_summary_validation.txt").write_text("summary_validation=PASS\n", encoding="utf-8")
PY

run_sql_capture "prod" "$PROD_DATABASE_URL" "/fjcloud/prod/database_url" "$(build_copy_sql "$EXACT_FILTER")" "$EVID_DIR/53_prod_exact_cleanup_rerun.csv" "$EVID_DIR/53_prod_exact_cleanup_rerun.stderr.txt"
run_sql_capture "staging" "$STAGING_DATABASE_URL" "/fjcloud/staging/database_url" "$(build_copy_sql "$EXACT_FILTER")" "$EVID_DIR/54_staging_exact_cleanup_rerun.csv" "$EVID_DIR/54_staging_exact_cleanup_rerun.stderr.txt"

prod_original_sha="$(shasum -a 256 "$EVID_DIR/10_prod_exact_cleanup.csv" | awk "{print \$1}")"
prod_rerun_sha="$(shasum -a 256 "$EVID_DIR/53_prod_exact_cleanup_rerun.csv" | awk "{print \$1}")"
staging_original_sha="$(shasum -a 256 "$EVID_DIR/11_staging_exact_cleanup.csv" | awk "{print \$1}")"
staging_rerun_sha="$(shasum -a 256 "$EVID_DIR/54_staging_exact_cleanup_rerun.csv" | awk "{print \$1}")"

{
    echo "prod_original_sha256=$prod_original_sha"
    echo "prod_rerun_sha256=$prod_rerun_sha"
    echo "staging_original_sha256=$staging_original_sha"
    echo "staging_rerun_sha256=$staging_rerun_sha"
    if [ "$prod_original_sha" = "$prod_rerun_sha" ] && [ "$staging_original_sha" = "$staging_rerun_sha" ]; then
        echo "reproducibility=PASS"
    else
        echo "reproducibility=FAIL"
    fi
} > "$EVID_DIR/52_reproducibility_check.txt"

if [ "$prod_original_sha" != "$prod_rerun_sha" ] || [ "$staging_original_sha" != "$staging_rerun_sha" ]; then
    echo "Exact cohort reproducibility check failed" >&2
    exit 1
fi

echo "Stage 1 inventory evidence complete: $EVID_DIR"
