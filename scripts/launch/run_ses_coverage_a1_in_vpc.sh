#!/usr/bin/env bash
# run_ses_coverage_a1_in_vpc.sh — canonical §1 six-probe in-VPC coverage runner.
#
# Packages the repo at --sha via `git archive`, hydrates the sole SSM-online
# staging instance, and runs the six §1 SES-coverage probe owners THROUGH
# scripts/launch/ssm_exec_staging.sh (the reuse seam — no new SSM code here).
# It then generates the evidence bundle (per-probe sidecars, probe_results.tsv,
# all_green.txt, failure_classifications.json) and the canonical
# run_manifest.json + run_status.json using the imported detection logic in
# scripts/lib/ses_coverage_a1_integrity.py (the single canonical owner).
#
# Exit taxonomy (spec-fixed; only 0/10 authorize downstream classification):
#     0  green             — all six probes green
#     10 complete_red      — clean run, §1 red (per-probe detail in the manifest)
#     20 setup_failed      — `git archive` packaging failure
#     21 structural_failed — host hydration / SSM offline / checkout / emit failure
#     22 cleanup_failed    — S3 / remote-temp cleanup trap failure
#
# This runner makes no live customer claim and performs no external mutation of
# customer state; its live execution against real Stripe/SES/CloudWatch/S3 is
# Wave 3's job. It is hermetically testable via
# scripts/tests/run_ses_coverage_a1_in_vpc_test.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSM_EXEC="$SCRIPT_DIR/ssm_exec_staging.sh"
INTEGRITY_LIB="$REPO_ROOT/scripts/lib/ses_coverage_a1_integrity.py"
DEPLOYABLE_CURRENCY_LIB="$REPO_ROOT/scripts/lib/deployable_currency.sh"

# shellcheck source=../lib/deployable_currency.sh
source "$DEPLOYABLE_CURRENCY_LIB"

RC_GREEN=0
RC_COMPLETE_RED=10
RC_SETUP_FAILED=20
RC_STRUCTURAL_FAILED=21
RC_CLEANUP_FAILED=22

S3_BUCKET="${SES_COVERAGE_A1_S3_BUCKET:-fjcloud-releases-staging}"

# Six §1 probe owners, in the spec-required order. The command substrings are
# the stable seam ssm_exec_staging.sh transports to the staging host.
PROBE_IDS=(
    verify_email_clickthrough
    password_reset_clickthrough
    dunning_email_inbox
    ses_bounce
    ses_complaint
    staging_dunning_delivery
)

# --- run state (populated as the run progresses) ---
ORIGINAL_ARGV=("$@")
SOURCE_SHA=""
ARTIFACT_DIR_REL=""
CREDENTIAL_ENV_FILE=""
BILLING_MONTH=""
BUNDLE_DIR=""
INSTANCE_ID=""
ARCHIVE_DIGEST=""
TREE_DIGEST=""
S3_PREFIX=""
WORK_TMP=""
SOURCE_ARCHIVE=""
DEPLOYABLE_CURRENCY_FILE=""
DEPLOYABLE_CURRENCY_DIGEST=""
PROBE_RUNS_FILE=""
EMIT_HELPER=""
PHASE="init"
RESULT_STATUS=""
RESULT_RC=0
TERMINAL_STATUS=""
TERMINAL_RC=0

die() {
    echo "ERROR: $1" >&2
    exit 2
}

# Record a non-classifiable terminal state and exit with its taxonomy rc. Any
# partial run_manifest.json is removed so only rc 0/10 leave a classifiable
# manifest; the EXIT trap writes run_status.json with this status.
fail_terminal() {
    TERMINAL_STATUS="$1"
    TERMINAL_RC="$2"
    [ -n "$BUNDLE_DIR" ] && rm -f "$BUNDLE_DIR/run_manifest.json"
    exit "$TERMINAL_RC"
}

sha256_file() {
    python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

is_lowercase_40_hex() {
    printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}

s3_object_uri() {
    printf 's3://%s/%s/%s' "$S3_BUCKET" "$S3_PREFIX" "$1"
}

remote_command_for() {
    local env_file=".runtime/host.env"
    local currency_json=".runtime/deployable_currency.json"
    local currency_prefix="FJCLOUD_DEPLOYABLE_CURRENCY_JSON=$currency_json FJCLOUD_DEPLOYABLE_CURRENCY_SOURCE_SHA=$SOURCE_SHA"
    case "$1" in
        verify_email_clickthrough)   echo "$currency_prefix bash scripts/probe_verify_email_clickthrough_e2e.sh --env-file $env_file" ;;
        password_reset_clickthrough) echo "$currency_prefix bash scripts/probe_password_reset_clickthrough_e2e.sh --env-file $env_file" ;;
        dunning_email_inbox)         echo "$currency_prefix bash scripts/probe_dunning_email_inbox_e2e.sh --env-file $env_file --month $BILLING_MONTH" ;;
        ses_bounce)                  echo "$currency_prefix bash scripts/probe_ses_bounce_complaint_e2e.sh bounce $env_file" ;;
        ses_complaint)               echo "$currency_prefix bash scripts/probe_ses_bounce_complaint_e2e.sh complaint $env_file" ;;
        staging_dunning_delivery)    echo "$currency_prefix bash scripts/validate_staging_dunning_delivery.sh --env-file $env_file --month $BILLING_MONTH --confirm-live-mutation" ;;
    esac
}

parse_args() {
    [ "${#ORIGINAL_ARGV[@]}" -gt 0 ] || return 0
    local arg
    for arg in "${ORIGINAL_ARGV[@]}"; do
        case "$arg" in
            --sha=*)                 SOURCE_SHA="${arg#--sha=}" ;;
            --artifact-dir=*)        ARTIFACT_DIR_REL="${arg#--artifact-dir=}" ;;
            --credential-env-file=*) CREDENTIAL_ENV_FILE="${arg#--credential-env-file=}" ;;
            --billing-month=*)       BILLING_MONTH="${arg#--billing-month=}" ;;
            *) die "unknown argument: $arg" ;;
        esac
    done
}

validate_args() {
    [ -n "$SOURCE_SHA" ] || die "--sha is required (40-char lowercase hex)"
    is_lowercase_40_hex "$SOURCE_SHA" \
        || die "--sha must be a 40-char lowercase hex string: $SOURCE_SHA"
    [ -n "$ARTIFACT_DIR_REL" ] || die "--artifact-dir is required (repo-relative path)"
    [ -n "$CREDENTIAL_ENV_FILE" ] || die "--credential-env-file is required (absolute path)"
    case "$CREDENTIAL_ENV_FILE" in
        /*) : ;;
        *) die "--credential-env-file must be an absolute path: $CREDENTIAL_ENV_FILE" ;;
    esac
    [ -f "$CREDENTIAL_ENV_FILE" ] || die "--credential-env-file not found: $CREDENTIAL_ENV_FILE"
    [ -n "$BILLING_MONTH" ] || die "--billing-month is required (YYYY-MM)"
    printf '%s' "$BILLING_MONTH" | grep -Eq '^[0-9]{4}-[0-9]{2}$' \
        || die "--billing-month must be YYYY-MM: $BILLING_MONTH"
    printf '%s' "$S3_BUCKET" | grep -Eq '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$' \
        || die "SES_COVERAGE_A1_S3_BUCKET must be a DNS-compatible bucket name: $S3_BUCKET"
    case "$S3_BUCKET" in
        *..*|*.-*|*-.*) die "SES_COVERAGE_A1_S3_BUCKET has an invalid bucket label layout: $S3_BUCKET" ;;
    esac
    S3_PREFIX="ses-coverage-a1/$SOURCE_SHA"
}

# Harden and normalize the artifact-dir destination: repo-relative only, no
# '..', no symlink component, and never a pre-existing non-empty directory.
harden_artifact_dir() {
    case "$ARTIFACT_DIR_REL" in
        /*) die "--artifact-dir must be repo-relative, not absolute: $ARTIFACT_DIR_REL" ;;
    esac
    case "$ARTIFACT_DIR_REL" in
        *..*) die "--artifact-dir must not contain '..': $ARTIFACT_DIR_REL" ;;
    esac

    local abs="$REPO_ROOT/$ARTIFACT_DIR_REL"
    local accum="$REPO_ROOT" seg oldifs="$IFS"
    IFS='/'
    set -f
    for seg in $ARTIFACT_DIR_REL; do
        [ -n "$seg" ] || continue
        accum="$accum/$seg"
        if [ -L "$accum" ]; then
            IFS="$oldifs"; set +f
            die "--artifact-dir path contains a symlink component: $accum"
        fi
    done
    IFS="$oldifs"; set +f

    if [ -e "$abs" ]; then
        [ -d "$abs" ] || die "--artifact-dir exists and is not a directory: $abs"
        [ -z "$(ls -A "$abs" 2>/dev/null)" ] \
            || die "--artifact-dir already exists and is non-empty: $abs"
    fi
    mkdir -p "$abs"
    BUNDLE_DIR="$(cd "$abs" && pwd)"
}

load_credentials() {
    set -a
    # shellcheck disable=SC1090
    . "$CREDENTIAL_ENV_FILE"
    set +a
}

setup_work_tmp() {
    WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ses_cov_a1.XXXXXX")"
    PROBE_RUNS_FILE="$WORK_TMP/probe_runs.tsv"
    EMIT_HELPER="$WORK_TMP/emit_bundle.py"
    DEPLOYABLE_CURRENCY_FILE="$WORK_TMP/deployable_currency.json"
    write_emit_helper > "$EMIT_HELPER"
}

extract_staging_dev_sha() {
    local status_json="$1"
    local fields dev_sha status_deployable_drift status_doc_only_ahead extra
    fields="$(staging_deployable_currency_fields_from_status_json "$status_json")"
    local fields_without_delimiters="${fields//|/}"
    local delimiter_count=$((${#fields} - ${#fields_without_delimiters}))
    if [ "$delimiter_count" -ne 2 ]; then
        return 1
    fi
    IFS='|' read -r dev_sha status_deployable_drift status_doc_only_ahead extra <<< "$fields"
    if [ -n "${extra:-}" ] || [ -z "$dev_sha" ] || \
       [ -z "$status_deployable_drift" ] || [ -z "$status_doc_only_ahead" ]; then
        return 1
    fi
    if ! is_lowercase_40_hex "$dev_sha"; then
        return 1
    fi
    printf '%s\n' "$dev_sha"
}

field_value() {
    local name="$1"
    awk -F= -v wanted="$name" '$1 == wanted { print $2 }'
}

acquire_deployable_currency() {
    PHASE="setup"
    local status_output status_rc=0 dev_sha classification
    set +e
    status_output="$(cd "$REPO_ROOT" && bash scripts/deploy_status.sh --json --env staging 2>"$WORK_TMP/deploy_status.err")"
    status_rc=$?
    set -e
    if [ "$status_rc" -ne 0 ]; then
        fail_terminal "setup_failed" "$RC_SETUP_FAILED"
    fi

    if ! dev_sha="$(extract_staging_dev_sha "$status_output")"; then
        fail_terminal "setup_failed" "$RC_SETUP_FAILED"
    fi
    if ! classification="$(classify_deployable_currency "$REPO_ROOT" "$dev_sha" "$SOURCE_SHA")"; then
        fail_terminal "setup_failed" "$RC_SETUP_FAILED"
    fi
    local deployable_drift doc_only_ahead
    deployable_drift="$(printf '%s\n' "$classification" | field_value deployable_drift)"
    doc_only_ahead="$(printf '%s\n' "$classification" | field_value doc_only_ahead)"
    case "$deployable_drift:$doc_only_ahead" in
        true:false|false:true|false:false) : ;;
        *) fail_terminal "setup_failed" "$RC_SETUP_FAILED" ;;
    esac

    if ! serialize_deployable_currency_verdict_json \
            "$SOURCE_SHA" "$dev_sha" "$deployable_drift" "$doc_only_ahead" \
            > "$DEPLOYABLE_CURRENCY_FILE" 2>"$WORK_TMP/deployable_currency_serialize.err"; then
        fail_terminal "setup_failed" "$RC_SETUP_FAILED"
    fi

    local verdict_fields verdict_source verdict_dev verdict_drift verdict_doc
    if ! verdict_fields="$(deployable_currency_verdict_fields_from_file "$DEPLOYABLE_CURRENCY_FILE" 2>"$WORK_TMP/deployable_currency_validate.err")"; then
        fail_terminal "setup_failed" "$RC_SETUP_FAILED"
    fi
    IFS='|' read -r verdict_source verdict_dev verdict_drift verdict_doc <<< "$verdict_fields"
    if [ "$verdict_source" != "$SOURCE_SHA" ] || [ "$verdict_dev" != "$dev_sha" ] || \
       [ "$verdict_drift" != "$deployable_drift" ] || [ "$verdict_doc" != "$doc_only_ahead" ]; then
        fail_terminal "setup_failed" "$RC_SETUP_FAILED"
    fi
    if ! DEPLOYABLE_CURRENCY_DIGEST="$(sha256_file "$DEPLOYABLE_CURRENCY_FILE")"; then
        fail_terminal "setup_failed" "$RC_SETUP_FAILED"
    fi
}

remote_deployable_currency_digest_check() {
    printf '%s\n' \
        "python3 -c 'import hashlib,sys; expected,path=sys.argv[1:3]; actual=hashlib.sha256(open(path,\"rb\").read()).hexdigest(); raise SystemExit(0 if actual == expected else 1)' $DEPLOYABLE_CURRENCY_DIGEST .runtime/deployable_currency.json"
}

# Package the checkout at --sha (never dirty-worktree bytes). The tarball is a
# transport artifact only (uploaded to S3, hydrated on-host), so it is staged in
# WORK_TMP — which the EXIT trap removes — and never lands in the durable
# evidence bundle. A packaging failure is setup_failed (rc 20).
package_archive() {
    PHASE="setup"
    SOURCE_ARCHIVE="$WORK_TMP/source.tar"
    if ! git archive --format=tar --prefix="ses-coverage-a1/" \
            --output="$SOURCE_ARCHIVE" "$SOURCE_SHA" 2>"$WORK_TMP/archive.err"; then
        fail_terminal "setup_failed" "$RC_SETUP_FAILED"
    fi
    if ! ARCHIVE_DIGEST="$(sha256_file "$SOURCE_ARCHIVE")"; then
        fail_terminal "setup_failed" "$RC_SETUP_FAILED"
    fi
    TREE_DIGEST="$(git rev-parse --verify "$SOURCE_SHA" 2>/dev/null || echo "$SOURCE_SHA")"
}

# Resolve the SSM-online staging instance, upload the archive, and check it out
# on the host through the SSM seam. Any host/SSM failure is structural (rc 21).
hydrate_host() {
    PHASE="hydrate"
    local source_uri verdict_uri
    INSTANCE_ID="$(aws ec2 describe-instances \
        --region "${AWS_DEFAULT_REGION:-us-east-1}" \
        --filters "Name=tag:Name,Values=fjcloud-api-staging" \
                  "Name=instance-state-name,Values=running" \
        --query "Reservations[0].Instances[0].InstanceId" \
        --output text 2>/dev/null || true)"
    if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
        fail_terminal "structural_failed" "$RC_STRUCTURAL_FAILED"
    fi

    source_uri="$(s3_object_uri source.tar)"
    verdict_uri="$(s3_object_uri deployable_currency.json)"

    if ! aws s3 cp "$SOURCE_ARCHIVE" "$source_uri" >/dev/null 2>&1; then
        fail_terminal "structural_failed" "$RC_STRUCTURAL_FAILED"
    fi
    if ! aws s3 cp "$DEPLOYABLE_CURRENCY_FILE" "$verdict_uri" >/dev/null 2>&1; then
        fail_terminal "structural_failed" "$RC_STRUCTURAL_FAILED"
    fi

    local out="$WORK_TMP/checkout.out" rc=0
    "$SSM_EXEC" "rm -rf /opt/ses-coverage-a1 && mkdir -p /opt/ses-coverage-a1 && aws s3 cp $source_uri /tmp/source.tar && tar xf /tmp/source.tar -C /opt/ses-coverage-a1 --strip-components=1" \
        >"$out" 2>"$WORK_TMP/checkout.err" || rc=$?
    # Unlike a probe, hydration has no "red but valid" outcome: any nonzero rc
    # means the workspace was not fully staged, so treat it as structural even
    # when partial stdout (e.g. mkdir succeeded, s3 cp errored) landed in $out.
    if [ "$rc" -ne 0 ]; then
        fail_terminal "structural_failed" "$RC_STRUCTURAL_FAILED"
    fi
}

# Materialize .runtime/host.env on the staging host by running the SSM hydrator.
# The env file supplies every probe's --env-file / positional env-file argument.
# Fail-closed: if the hydrator exits nonzero, the env file is missing or
# incomplete and every probe would die with "env file is required" — structural.
materialize_host_env() {
    PHASE="materialize"
    local out="$WORK_TMP/materialize.out" rc=0
    local digest_check
    digest_check="$(remote_deployable_currency_digest_check)"
    "$SSM_EXEC" "cd /opt/ses-coverage-a1 && mkdir -p .runtime && aws s3 cp $(s3_object_uri deployable_currency.json) .runtime/deployable_currency.json && $digest_check && bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging > .runtime/host.env" \
        >"$out" 2>"$WORK_TMP/materialize.err" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail_terminal "structural_failed" "$RC_STRUCTURAL_FAILED"
    fi
}

# Run each probe owner on the host through the SSM seam. A nonzero exit with no
# probe output means the host/SSM never produced a log — that is structural
# (rc 21), not a red probe result. A red probe still emits its log.
run_probes() {
    PHASE="probes"
    : > "$PROBE_RUNS_FILE"
    local probe_id remote_cmd log_file rc
    for probe_id in "${PROBE_IDS[@]}"; do
        remote_cmd="$(remote_command_for "$probe_id")"
        log_file="$BUNDLE_DIR/${probe_id}.log"
        rc=0
        "$SSM_EXEC" "cd /opt/ses-coverage-a1 && $remote_cmd" \
            >"$log_file" 2>"$BUNDLE_DIR/${probe_id}.stderr.log" || rc=$?
        if [ "$rc" -ne 0 ] && [ ! -s "$log_file" ]; then
            fail_terminal "structural_failed" "$RC_STRUCTURAL_FAILED"
        fi
        printf '%s\t%s\t%s\n' "$probe_id" "$rc" "$log_file" >> "$PROBE_RUNS_FILE"
    done
}

build_emit_input() {
    python3 - "$BUNDLE_DIR" "$SOURCE_SHA" "$BILLING_MONTH" "$ARCHIVE_DIGEST" \
        "$TREE_DIGEST" "$INTEGRITY_LIB" "$INSTANCE_ID" "$PROBE_RUNS_FILE" \
        "$DEPLOYABLE_CURRENCY_FILE" <<'PY'
import json, sys
(bundle_dir, sha, month, archive_digest, tree_digest,
 lib_path, instance_id, runs_file, deployable_currency_file) = sys.argv[1:10]
probes = []
with open(runs_file) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        probe_id, rc, log_path = line.split("\t")
        probes.append({"probe_id": probe_id, "rc": int(rc), "log_path": log_path})
with open(deployable_currency_file) as fh:
    deployable_currency = json.load(fh)
json.dump({
    "bundle_dir": bundle_dir,
    "source_sha": sha,
    "billing_month": month,
    "archive_digest": archive_digest,
    "tree_digest": tree_digest,
    "integrity_lib_path": lib_path,
    "instance_id": instance_id,
    "schema_version": "1",
    "deployable_currency": deployable_currency,
    "probes": probes,
}, sys.stdout)
PY
}

# Emit all evidence artifacts + the canonical manifest via the library's
# detection logic, then bind the manifest to --sha/--billing-month via the
# library's `validate` subcommand (receipt lands OUTSIDE the bundle). Any
# emit/integrity failure is structural (rc 21).
emit_bundle() {
    PHASE="emit"
    local emit_input="$WORK_TMP/emit_input.json" status
    if ! build_emit_input > "$emit_input"; then
        fail_terminal "structural_failed" "$RC_STRUCTURAL_FAILED"
    fi
    if ! status="$(python3 "$EMIT_HELPER" "$emit_input")"; then
        fail_terminal "structural_failed" "$RC_STRUCTURAL_FAILED"
    fi
    if ! python3 "$INTEGRITY_LIB" validate \
            --manifest="$BUNDLE_DIR/run_manifest.json" \
            --sha="$SOURCE_SHA" \
            --billing-month="$BILLING_MONTH" \
            --validation-output="$WORK_TMP/validation_receipt.json" \
            >/dev/null 2>"$WORK_TMP/validate.err"; then
        fail_terminal "structural_failed" "$RC_STRUCTURAL_FAILED"
    fi

    RESULT_STATUS="$status"
    if [ "$RESULT_STATUS" = "green" ]; then
        RESULT_RC=$RC_GREEN
    else
        RESULT_RC=$RC_COMPLETE_RED
    fi
    PHASE="complete"
}

write_run_status() {
    local status="$1" rc="$2"
    [ -n "$BUNDLE_DIR" ] || return 0
    python3 - "$BUNDLE_DIR/run_status.json" "$status" "$rc" "$INSTANCE_ID" \
        "${ORIGINAL_ARGV[@]}" <<'PY'
import json, os, sys
out, status, rc, instance_id = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
argv = sys.argv[5:]
tmp = out + ".tmp"
with open(tmp, "w") as fh:
    json.dump({"status": status, "rc": rc, "argv": argv,
               "instance_id": instance_id}, fh, indent=2)
    fh.write("\n")
os.replace(tmp, out)
PY
}

# Rewrite the retained manifest's cleanup_status to the real terminal outcome.
# Only called for a manifest that survives (complete run whose cleanup succeeded).
finalize_manifest_cleanup_status() {
    local status="$1" manifest="$BUNDLE_DIR/run_manifest.json"
    [ -f "$manifest" ] || return 0
    python3 - "$manifest" "$status" <<'PY'
import json, os, sys
path, status = sys.argv[1], sys.argv[2]
with open(path) as fh:
    manifest = json.load(fh)
manifest["cleanup_status"] = status
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(manifest, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PY
}

# S3 + remote-temp cleanup. Returns 1 only when the S3 cleanup itself fails,
# which the EXIT trap turns into cleanup_failed (rc 22).
do_cleanup() {
    [ -n "$S3_PREFIX" ] || return 0
    "$SSM_EXEC" "rm -rf /opt/ses-coverage-a1 /tmp/source.tar /tmp/deployable_currency.json" >/dev/null 2>&1 || true
    if ! aws s3 rm "s3://$S3_BUCKET/$S3_PREFIX" --recursive >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# EXIT trap: always attempt cleanup, then finalize run_status.json and the exit
# rc. Only a fully-complete run whose cleanup also succeeds keeps its
# classifiable run_manifest.json; a cleanup failure downgrades to
# cleanup_failed and drops the manifest.
on_exit() {
    local prev_rc=$?
    trap - EXIT
    set +e
    do_cleanup
    local cleanup_rc=$? final_rc final_status=""
    if [ "$PHASE" = "complete" ]; then
        if [ "$cleanup_rc" -eq 0 ]; then
            final_status="$RESULT_STATUS"; final_rc="$RESULT_RC"
            finalize_manifest_cleanup_status "clean"
        else
            rm -f "$BUNDLE_DIR/run_manifest.json"
            final_status="cleanup_failed"; final_rc="$RC_CLEANUP_FAILED"
        fi
    else
        final_status="$TERMINAL_STATUS"; final_rc="$prev_rc"
    fi
    if [ -n "$BUNDLE_DIR" ] && [ -n "$final_status" ]; then
        write_run_status "$final_status" "$final_rc"
    fi
    [ -n "$WORK_TMP" ] && rm -rf "$WORK_TMP"
    exit "$final_rc"
}

write_emit_helper() {
    cat <<'PY'
#!/usr/bin/env python3
"""Emit the §1 in-VPC evidence bundle + canonical run_manifest.json.

Applies the canonical integrity library's detect_from_log / classify_failure
logic to each probe log and writes the per-probe sidecars, probe_results.tsv,
all_green.txt, failure_classifications.json, and run_manifest.json. Prints
'green' (all six probes green) or 'complete_red' (clean run, §1 red) to stdout.
"""
import hashlib
import json
import os
import shutil
import sys


def sha256_file(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def main():
    with open(sys.argv[1]) as fh:
        spec = json.load(fh)
    bundle_dir = spec["bundle_dir"]
    lib_path = spec["integrity_lib_path"]
    sys.path.insert(0, os.path.dirname(os.path.abspath(lib_path)))
    import ses_coverage_a1_integrity as lib

    # Copy the canonical library into the bundle for provenance.
    shutil.copyfile(lib_path, os.path.join(bundle_dir, os.path.basename(lib_path)))
    integrity_sha = sha256_file(lib_path)

    probes, failures, green_rows = [], [], []
    tsv = ["probe_id\trc\tpass\tlog_path"]
    all_green = True

    for entry in spec["probes"]:
        probe_id, rc, log_path = entry["probe_id"], entry["rc"], entry["log_path"]
        with open(log_path) as fh:
            passed, evidence = lib.detect_from_log(probe_id, fh.read())
        detect_kind = lib.DETECT_KIND[probe_id]

        with open(os.path.join(bundle_dir, probe_id + ".json"), "w") as fh:
            json.dump({"probe_id": probe_id, "detect_kind": detect_kind,
                       "log_path": log_path, "pass": passed, "rc": rc,
                       "parsed_evidence": evidence}, fh, indent=2)
            fh.write("\n")

        tsv.append("%s\t%s\t%s\t%s" % (probe_id, rc, "1" if passed else "0", log_path))
        row = {"probe_id": probe_id, "pass": passed, "rc": rc,
               "log_path": log_path, "detect_kind": detect_kind}

        if passed and rc == 0:
            green_rows.append(probe_id)
        else:
            all_green = False
            final = evidence.get("final_json")
            final = final if isinstance(final, dict) else {}
            classification = final.get("classification") or "unclassified"
            category = lib.classify_failure(classification)
            row["classification"] = classification
            row["classification_category"] = category
            failures.append({"probe_id": probe_id, "rc": rc,
                             "classification": classification,
                             "classification_category": category,
                             "detail": final.get("detail") or ""})
        probes.append(row)

    with open(os.path.join(bundle_dir, "probe_results.tsv"), "w") as fh:
        fh.write("\n".join(tsv) + "\n")
    with open(os.path.join(bundle_dir, "all_green.txt"), "w") as fh:
        fh.write("1\n" if all_green else "0\n")
    with open(os.path.join(bundle_dir, "failure_classifications.json"), "w") as fh:
        json.dump({"all_green": all_green, "n": len(spec["probes"]),
                   "failures": failures, "green_rows": green_rows}, fh, indent=2)
        fh.write("\n")
    with open(os.path.join(bundle_dir, "GAP_SPEC.md"), "w") as fh:
        if all_green:
            fh.write("# Section 1 GAP_SPEC\n\nAll six probes passed; no gaps recorded.\n")
        else:
            fh.write("# Section 1 GAP_SPEC\n\n")
            fh.write("Complete-red Section 1 probe failures:\n")
            for failure in failures:
                fh.write(
                    "- {probe_id}: rc={rc}; classification={classification}; "
                    "category={classification_category}; detail={detail}\n".format(
                        probe_id=failure["probe_id"],
                        rc=failure["rc"],
                        classification=failure["classification"],
                        classification_category=failure["classification_category"],
                        detail=(failure.get("detail") or "").replace("\n", " "),
                    )
                )

    # Real hygiene check: the bundle is evidence-only, so no transport artifact
    # (the git-archive tarball, staged in WORK_TMP) may have leaked into it.
    stray = [name for name in os.listdir(bundle_dir)
             if name.endswith((".tar", ".tar.gz", ".tgz"))]
    hygiene_status = "clean" if not stray else "polluted"

    manifest = {
        "schema_version": spec["schema_version"],
        "source_sha": spec["source_sha"],
        "billing_month": spec["billing_month"],
        "tree_digest": spec["tree_digest"],
        "archive_digest": spec["archive_digest"],
        "bundle_path": bundle_dir,
        "instance_id": spec["instance_id"],
        "n": len(probes),
        "all_green": all_green,
        "probes": probes,
        "deployable_currency": spec["deployable_currency"],
        "integrity_status": "validated",
        "hygiene_status": hygiene_status,
        # Cleanup runs in the runner's EXIT trap, after this manifest is written;
        # the trap finalizes this field to the real terminal outcome for any
        # retained manifest. "pending" is the pre-cleanup placeholder only.
        "cleanup_status": "pending",
        "integrity_library_source": "scripts/lib/ses_coverage_a1_integrity.py",
        "owner_digests": {"integrity_library": integrity_sha},
    }
    with open(os.path.join(bundle_dir, "run_manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)
        fh.write("\n")

    print("green" if all_green else "complete_red")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
}

main() {
    trap on_exit EXIT
    parse_args
    validate_args
    harden_artifact_dir
    load_credentials
    setup_work_tmp
    acquire_deployable_currency
    package_archive
    hydrate_host
    materialize_host_env
    run_probes
    emit_bundle
    exit "$RESULT_RC"
}

main
