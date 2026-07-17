#!/usr/bin/env bash
set -euo pipefail
EVID_DIR="$1"
set +u
[ -f .secret/.env.secret ] && set -a && source .secret/.env.secret && set +a
set -u
aws sts get-caller-identity > "$EVID_DIR/00_sts_identity.json" 2> "$EVID_DIR/00_sts_identity_stderr.txt"
aws ssm get-parameters-by-path --region us-east-1 --path /fjcloud/staging/ --recursive --query "Parameters[?starts_with(Name, /fjcloud/staging/stripe_price_)].Name" --output text > "$EVID_DIR/01_staging_lookup_stdout.txt" 2> "$EVID_DIR/01_staging_lookup_stderr.txt"
aws ssm get-parameters-by-path --region us-east-1 --path /fjcloud/prod/ --recursive --query "Parameters[?starts_with(Name, /fjcloud/prod/stripe_price_)].Name" --output text > "$EVID_DIR/02_prod_lookup_stdout.txt" 2> "$EVID_DIR/02_prod_lookup_stderr.txt"
tr "\t" "\n" < "$EVID_DIR/01_staging_lookup_stdout.txt" | sed /^$/d > "$EVID_DIR/01_staging_lookup_names.txt"
tr "\t" "\n" < "$EVID_DIR/02_prod_lookup_stdout.txt" | sed /^$/d > "$EVID_DIR/02_prod_lookup_names.txt"
cat "$EVID_DIR/01_staging_lookup_names.txt" "$EVID_DIR/02_prod_lookup_names.txt" > "$EVID_DIR/03_delete_targets.txt"
: > "$EVID_DIR/04_delete_results.txt"
while IFS= read -r name; do
  [ -z "$name" ] && continue
  set +e
  out=$(aws ssm delete-parameter --region us-east-1 --name "$name" 2>&1)
  rc=$?
  set -e
  printf "%s\trc=%s\t%s\n" "$name" "$rc" "$out" >> "$EVID_DIR/04_delete_results.txt"
done < "$EVID_DIR/03_delete_targets.txt"
aws ssm get-parameters-by-path --region us-east-1 --path /fjcloud/staging/ --recursive --query "Parameters[?starts_with(Name, /fjcloud/staging/stripe_price_)].Name" --output text > "$EVID_DIR/05_staging_recheck_stdout.txt" 2> "$EVID_DIR/05_staging_recheck_stderr.txt"
aws ssm get-parameters-by-path --region us-east-1 --path /fjcloud/prod/ --recursive --query "Parameters[?starts_with(Name, /fjcloud/prod/stripe_price_)].Name" --output text > "$EVID_DIR/06_prod_recheck_stdout.txt" 2> "$EVID_DIR/06_prod_recheck_stderr.txt"
set +e
scripts/launch/ssm_exec_staging.sh "grep -E ^STRIPE_PRICE_ /etc/fjcloud/env || true" > "$EVID_DIR/07_staging_runtime_stripe_price_stdout.txt" 2> "$EVID_DIR/07_staging_runtime_stripe_price_stderr.txt"
RUNTIME_RC=$?
set -e
printf "runtime_rc=%s\n" "$RUNTIME_RC" > "$EVID_DIR/runtime_exit_code.txt"
