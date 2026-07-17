#!/usr/bin/env bash
# Contract tests for scripts/audit_prod_secret_distinctness.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUDIT_SCRIPT="$REPO_ROOT/scripts/audit_prod_secret_distinctness.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

run_audit() {
    local output_file="$1"
    shift

    set +e
    bash "$AUDIT_SCRIPT" "$@" >"$output_file" 2>&1
    local status=$?
    set -e
    echo "$status"
}

write_manifest_fixture() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'MD'
# Secret Distinctness Manifest

## Distinctness Contract Table

| env_var | prod_ssm_key | staging_ssm_key | constraint_type | pattern_contract | rationale |
| --- | --- | --- | --- | --- | --- |
| `STRIPE_SECRET_KEY` | `/fjcloud/prod/stripe_secret_key` | `/fjcloud/staging/stripe_secret_key` | `must_differ` + `prod_prefix` + `staging_prefix` | prod must match `^sk_live_[A-Za-z0-9]+$`; staging must match `^sk_test_[A-Za-z0-9]+$` | fixture |
| `STRIPE_PUBLISHABLE_KEY` | `/fjcloud/prod/stripe_publishable_key` | `/fjcloud/staging/stripe_publishable_key` | `must_differ` + `prod_prefix` + `staging_prefix` | prod must match `^pk_live_[A-Za-z0-9]+$`; staging must match `^pk_test_[A-Za-z0-9]+$` | fixture |
| `STRIPE_WEBHOOK_SECRET` | `/fjcloud/prod/stripe_webhook_secret` | `/fjcloud/staging/stripe_webhook_secret` | `must_differ` | both envs must match `^whsec_[A-Za-z0-9]+$`; prod and staging values must differ | fixture |
MD
}

write_aws_mock() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" != "ssm" || "$2" != "get-parameter" ]]; then
  echo "unexpected command: $*" >&2
  exit 99
fi

name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      name="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -z "$name" ]]; then
  echo "missing --name" >&2
  exit 98
fi

line="$(grep -F "${name}=" "$AUDIT_FIXTURE_DATA" || true)"
if [[ -z "$line" ]]; then
  exit 254
fi

value="${line#*=}"
printf '%s\n' "$value"
MOCK
    chmod +x "$path"
}

test_missing_key_and_identical_value_detection() {
    local tmpdir mockbin fixture manifest output status content
    tmpdir="$(mktemp -d)"
    mockbin="$tmpdir/mockbin"
    fixture="$tmpdir/fixture.txt"
    manifest="$tmpdir/manifest.md"
    output="$tmpdir/output.log"

    mkdir -p "$mockbin"
    write_manifest_fixture "$manifest"
    write_aws_mock "$mockbin/aws"

    cat > "$fixture" <<'DATA'
/fjcloud/prod/stripe_secret_key=sk_live_prodA123
/fjcloud/staging/stripe_secret_key=sk_test_stageA123
/fjcloud/prod/stripe_publishable_key=pk_live_SHARED111
/fjcloud/staging/stripe_publishable_key=pk_live_SHARED111
/fjcloud/prod/stripe_webhook_secret=whsec_prod_only
DATA

    status="$(AUDIT_FIXTURE_DATA="$fixture" PATH="$mockbin:$PATH" run_audit "$output" --manifest "$manifest")"
    assert_eq "$status" "1" "audit exits non-zero when identical or missing values exist"

    content="$(cat "$output")"
    assert_contains "$content" "finding|STRIPE_PUBLISHABLE_KEY|/fjcloud/prod/stripe_publishable_key|identical" "identical prod/staging values are reported"
    assert_contains "$content" "finding|STRIPE_WEBHOOK_SECRET|/fjcloud/staging/stripe_webhook_secret|missing" "missing parameter is reported"
    assert_contains "$content" "status|RED|" "mixed defect set classifies as RED"
    assert_not_contains "$content" "pk_live_SHARED111" "raw values never appear in output"

    rm -rf "$tmpdir"
}

test_manifest_parity_drift_detected() {
    local tmpdir mockbin fixture manifest output status content
    tmpdir="$(mktemp -d)"
    mockbin="$tmpdir/mockbin"
    fixture="$tmpdir/fixture.txt"
    manifest="$tmpdir/manifest.md"
    output="$tmpdir/output.log"

    mkdir -p "$mockbin"
    write_aws_mock "$mockbin/aws"

    cat > "$manifest" <<'MD'
# Secret Distinctness Manifest

## Distinctness Contract Table

| env_var | prod_ssm_key | staging_ssm_key | constraint_type | pattern_contract | rationale |
| --- | --- | --- | --- | --- | --- |
| `STRIPE_SECRET_KEY` | `/fjcloud/prod/stripe_secret_key` | `/fjcloud/staging/stripe_secret_key` | `must_differ` | none | fixture |
| `DRIFT_ROW` | `/fjcloud/qa/DRIFT_ROW` | `/fjcloud/staging/DRIFT_ROW` | `must_differ` | none | fixture |
MD

    cat > "$fixture" <<'DATA'
/fjcloud/prod/stripe_secret_key=sk_live_prodA123
/fjcloud/staging/stripe_secret_key=sk_test_stageA123
DATA

    status="$(AUDIT_FIXTURE_DATA="$fixture" PATH="$mockbin:$PATH" run_audit "$output" --manifest "$manifest")"
    assert_eq "$status" "1" "parity drift causes non-zero exit"

    content="$(cat "$output")"
    assert_contains "$content" "finding|DRIFT_ROW|/fjcloud/qa/DRIFT_ROW|parity_error" "manifest parity drift is reported"
    assert_contains "$content" "status|YELLOW|" "parity-only drift classifies as YELLOW"

    rm -rf "$tmpdir"
}

test_canonical_lowercase_ssm_suffixes_are_accepted() {
    local tmpdir mockbin fixture manifest output status content
    tmpdir="$(mktemp -d)"
    mockbin="$tmpdir/mockbin"
    fixture="$tmpdir/fixture.txt"
    manifest="$tmpdir/manifest.md"
    output="$tmpdir/output.log"

    mkdir -p "$mockbin"
    write_aws_mock "$mockbin/aws"

    cat > "$manifest" <<'MD'
# Secret Distinctness Manifest

## Distinctness Contract Table

| env_var | prod_ssm_key | staging_ssm_key | constraint_type | pattern_contract | rationale |
| --- | --- | --- | --- | --- | --- |
| `STRIPE_SECRET_KEY` | `/fjcloud/prod/stripe_secret_key` | `/fjcloud/staging/stripe_secret_key` | `must_differ` + `prod_prefix` + `staging_prefix` | prod must match `^sk_live_[A-Za-z0-9]+$`; staging must match `^sk_test_[A-Za-z0-9]+$` | fixture |
MD

    cat > "$fixture" <<'DATA'
/fjcloud/prod/stripe_secret_key=sk_live_prodA123
/fjcloud/staging/stripe_secret_key=sk_test_stageA123
DATA

    status="$(AUDIT_FIXTURE_DATA="$fixture" PATH="$mockbin:$PATH" run_audit "$output" --manifest "$manifest")"
    assert_eq "$status" "0" "canonical lowercase SSM suffixes should pass when values differ and match pattern contracts"

    content="$(cat "$output")"
    assert_not_contains "$content" "parity_error" "canonical lowercase runtime suffixes are not parity drift"
    assert_contains "$content" "status|GREEN|" "matching canonical runtime keys classify as GREEN"

    rm -rf "$tmpdir"
}

test_single_regex_contract_applies_to_staging_value() {
    local tmpdir mockbin fixture manifest output status content
    tmpdir="$(mktemp -d)"
    mockbin="$tmpdir/mockbin"
    fixture="$tmpdir/fixture.txt"
    manifest="$tmpdir/manifest.md"
    output="$tmpdir/output.log"

    mkdir -p "$mockbin"
    write_aws_mock "$mockbin/aws"

    cat > "$manifest" <<'MD'
# Secret Distinctness Manifest

## Distinctness Contract Table

| env_var | prod_ssm_key | staging_ssm_key | constraint_type | pattern_contract | rationale |
| --- | --- | --- | --- | --- | --- |
| `STRIPE_WEBHOOK_SECRET` | `/fjcloud/prod/stripe_webhook_secret` | `/fjcloud/staging/stripe_webhook_secret` | `must_differ` | both envs must match `^whsec_[A-Za-z0-9]+$`; prod and staging values must differ | fixture |
MD

    cat > "$fixture" <<'DATA'
/fjcloud/prod/stripe_webhook_secret=whsec_prodA123
/fjcloud/staging/stripe_webhook_secret=not_a_webhook_secret
DATA

    status="$(AUDIT_FIXTURE_DATA="$fixture" PATH="$mockbin:$PATH" run_audit "$output" --manifest "$manifest")"
    assert_eq "$status" "1" "single-regex rows should fail when staging violates the shared pattern"

    content="$(cat "$output")"
    assert_contains "$content" "finding|STRIPE_WEBHOOK_SECRET|/fjcloud/staging/stripe_webhook_secret|pattern_violation" "shared regex contract is enforced on staging values"
    assert_contains "$content" "status|RED|" "shared-pattern staging violation classifies as RED"

    rm -rf "$tmpdir"
}

main() {
    echo "=== audit_prod_secret_distinctness.sh contract tests ==="
    echo ""

    test_missing_key_and_identical_value_detection
    test_manifest_parity_drift_detected
    test_canonical_lowercase_ssm_suffixes_are_accepted
    test_single_regex_contract_applies_to_staging_value

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
