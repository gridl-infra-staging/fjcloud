#!/usr/bin/env bash
# Contract for the current local-ci --fast runtime budget.
#
# Current Stage 3 acceptance specimen: elapsed_seconds=1246 in
# docs/audits/test-wiring/20260730T145719Z_fast_gate_lock_and_acceptance/SUMMARY.md.
# The ceiling below is intentionally unchanged from the Stage 1 budget.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$REPO_ROOT/scripts/lib/test_reachability_manifest.sh"

BASELINE_RECEIPT_REL="docs/audits/test-wiring/20260730T145719Z_fast_gate_lock_and_acceptance/SUMMARY.md"
BASELINE_HEAD_SHA="52c453fd4d25dcf47f5c59ace5918f3ffed8de3c"
BASELINE_SUITES=159
BASELINE_ELAPSED_SECONDS=1246
BUDGET_SECONDS=1800
BASELINE_PINNED_FIELDS=(
    "local_ci_exit_code=1"
    "elapsed_seconds_exact=1247.040064"
    "manifest_count=159"
    "serial_only_count=0"
    "single_gate_count_before=0"
    "single_gate_count_after=0"
    "reachability_summary=corpus=236 reachable=235 allowlisted=1 quarantined=0 unaccounted=0"
    "reachability_gate_summary=reachability gate: 159 hermetic suite(s) run at concurrency 8, 4 failed"
)
STAGE2_RECEIPT_REL="docs/audits/test-wiring/20260729T014207Z_fast_budget_baseline/SUMMARY.md"
STAGE2_ALGOLIA_BEFORE="191 passed, 0 failed; real 67.64 user 25.74 sys 17.58"
STAGE2_ALGOLIA_AFTER="213 passed, 0 failed; real 92.49 user 28.46 sys 21.75"
STAGE2_SES_BEFORE="100 passed, 0 failed; real 20.69 user 6.38 sys 3.87"
STAGE2_SES_AFTER="108 passed, 0 failed; real 36.25 user 8.17 sys 6.18"
# A source-pinned timing row may disappear from the live manifest only through
# an explicit, dated deletion decision. Filesystem absence alone is ambiguous:
# the suite may have been renamed, which must remain a failing drift signal.
SLOW_SUITE_DELETIONS=(
    "2026-07-30|scripts/tests/security_checks_lib_test.sh"
)
FINAL_ACCEPTANCE_FIXTURE_FIELDS=(
    "local_ci_exit_code=0"
    "elapsed_seconds_exact=100.25"
    "manifest_count=3"
    "serial_only_count=1"
    "reachability_summary=corpus=3 reachable=3 allowlisted=0 quarantined=0 unaccounted=0"
    "reachability_gate_summary=reachability gate: 3 hermetic suite(s) run at concurrency 8, 0 failed"
)

extract_receipt_value() {
    local receipt="$1" key="$2"
    awk -v key="$key" '
        $1 == key {
            print $2
            found = 1
            exit
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$receipt"
}

extract_receipt_value_rest() {
    local receipt="$1" key="$2"
    awk -v key="$key" '
        $1 == key {
            sub("^[^=]+=[[:space:]]*", "")
            print
            found = 1
            exit
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$receipt"
}

validate_pinned_receipt_fields() {
    local receipt_abs="$1" spec key expected actual
    shift

    for spec in "$@"; do
        if [[ "$spec" != *=* ]]; then
            printf 'ERROR: pinned receipt field expectation must use key=value: %s\n' "$spec" >&2
            return 1
        fi
        key="${spec%%=*}"
        expected="${spec#*=}"
        if [[ "$key" = '' || "$key" = *[![:alnum:]_]* ]]; then
            printf 'ERROR: pinned receipt field name is invalid: %s\n' "$key" >&2
            return 1
        fi
        actual="$(extract_receipt_value_rest "$receipt_abs" "$key=")" || {
            printf 'ERROR: receipt missing pinned field: %s\n' "$key" >&2
            return 1
        }
        if [ "$actual" != "$expected" ]; then
            printf 'ERROR: %s mismatch: expected %s actual %s\n' "$key" "$expected" "$actual" >&2
            return 1
        fi
    done
}

validate_budget_receipt() {
    local receipt_rel="$1" expected_head="$2" expected_suites="$3"
    local expected_elapsed="$4" expected_budget="$5" enforce_budget="$6"
    local receipt_abs raw_log_rel raw_log_abs slow_tsv_rel slow_tsv_abs
    local recorded_head suites elapsed exit_code budget
    local recorded_raw_log_sha actual_raw_log_sha tsv_rows unique_suite_paths
    shift 6

    if [[ "$receipt_rel" != docs/audits/test-wiring/*/SUMMARY.md ]]; then
        printf 'ERROR: receipt must live under docs/audits/test-wiring/: %s\n' "$receipt_rel" >&2
        return 1
    fi
    if [[ "$receipt_rel" = /* ]] || [[ "$receipt_rel" = *..* ]]; then
        printf 'ERROR: receipt path must be repo-relative and stay in-tree: %s\n' "$receipt_rel" >&2
        return 1
    fi

    receipt_abs="$REPO_ROOT/$receipt_rel"
    if [ ! -f "$receipt_abs" ]; then
        printf 'ERROR: baseline receipt missing: %s\n' "$receipt_rel" >&2
        return 1
    fi

    raw_log_rel="$(extract_receipt_value "$receipt_abs" "raw_log_path=")" || {
        printf 'ERROR: receipt missing raw_log_path\n' >&2
        return 1
    }
    recorded_raw_log_sha="$(extract_receipt_value "$receipt_abs" "raw_log_sha256=")" || {
        printf 'ERROR: receipt missing raw_log_sha256\n' >&2
        return 1
    }
    slow_tsv_rel="$(extract_receipt_value "$receipt_abs" "slow_suite_tsv_path=")" || {
        printf 'ERROR: receipt missing slow_suite_tsv_path\n' >&2
        return 1
    }
    recorded_head="$(extract_receipt_value "$receipt_abs" "head_sha=")" || {
        printf 'ERROR: receipt missing head_sha\n' >&2
        return 1
    }
    suites="$(extract_receipt_value "$receipt_abs" "suites=")" || {
        printf 'ERROR: receipt missing suites\n' >&2
        return 1
    }
    elapsed="$(extract_receipt_value "$receipt_abs" "elapsed_seconds=")" || {
        printf 'ERROR: receipt missing elapsed_seconds\n' >&2
        return 1
    }
    exit_code="$(extract_receipt_value "$receipt_abs" "local_ci_exit_code=")" || {
        printf 'ERROR: receipt missing local_ci_exit_code\n' >&2
        return 1
    }
    budget="$(extract_receipt_value "$receipt_abs" "budget_seconds=")" || {
        printf 'ERROR: receipt missing budget_seconds\n' >&2
        return 1
    }

    if [[ "$raw_log_rel" = /* ]] || [[ "$raw_log_rel" = *..* ]]; then
        printf 'ERROR: raw log path must be repo-relative and stay in-tree: %s\n' "$raw_log_rel" >&2
        return 1
    fi
    raw_log_abs="$REPO_ROOT/$raw_log_rel"
    if [ ! -s "$raw_log_abs" ]; then
        printf 'ERROR: raw local-ci log missing or empty: %s\n' "$raw_log_rel" >&2
        return 1
    fi
    if grep -Fq '<redacted-test-fixture>' "$raw_log_abs"; then
        printf 'ERROR: raw local-ci log contains a redaction marker: %s\n' "$raw_log_rel" >&2
        return 1
    fi
    if grep -Eiq \
        '(^|[^[:alnum:]_])[[:alnum:]_]*(secret|token|password|passwd|api_key|access_key|private_key|credential|admin_key|encryption_key)[[:alnum:]_]*=[^[:space:]]+' \
        "$raw_log_abs" ||
        grep -Eiq \
            '(^|[^[:alnum:]_])[[:alnum:]_]*url=[[:alnum:]+.-]+://[^[:space:]/:@]+:[^[:space:]@]+@' \
            "$raw_log_abs"; then
        printf 'ERROR: raw local-ci log contains secret-bearing assignment or credential output: %s\n' \
            "$raw_log_rel" >&2
        return 1
    fi
    case "$recorded_raw_log_sha" in
        *[!0-9a-f]*|'')
            printf 'ERROR: raw_log_sha256 must be lowercase hexadecimal: %s\n' \
                "$recorded_raw_log_sha" >&2
            return 1
            ;;
    esac
    if [ "${#recorded_raw_log_sha}" -ne 64 ]; then
        printf 'ERROR: raw_log_sha256 must contain exactly 64 characters: %s\n' \
            "$recorded_raw_log_sha" >&2
        return 1
    fi
    actual_raw_log_sha="$(shasum -a 256 "$raw_log_abs" | awk '{ print $1 }')"
    if [ "$actual_raw_log_sha" != "$recorded_raw_log_sha" ]; then
        printf 'ERROR: raw local-ci log checksum mismatch: expected %s actual %s\n' \
            "$recorded_raw_log_sha" "$actual_raw_log_sha" >&2
        return 1
    fi

    if [[ "$slow_tsv_rel" = /* ]] || [[ "$slow_tsv_rel" = *..* ]]; then
        printf 'ERROR: slow-suite TSV path must be repo-relative and stay in-tree: %s\n' "$slow_tsv_rel" >&2
        return 1
    fi
    slow_tsv_abs="$REPO_ROOT/$slow_tsv_rel"
    if [ ! -s "$slow_tsv_abs" ]; then
        printf 'ERROR: slow-suite TSV missing or empty: %s\n' "$slow_tsv_rel" >&2
        return 1
    fi
    if ! awk -F '\t' '
        NF != 3 ||
        $1 !~ /^[0-9]+([.][0-9]+)?$/ ||
        $2 !~ /^scripts\/tests\/[[:alnum:]_]+_test[.]sh$/ ||
        $3 !~ /^[0-9]+$/ {
            exit 1
        }
    ' "$slow_tsv_abs"; then
        printf 'ERROR: slow-suite TSV has a malformed row: %s\n' "$slow_tsv_rel" >&2
        return 1
    fi
    tsv_rows="$(awk 'END { print NR }' "$slow_tsv_abs")"
    if [ "$tsv_rows" != "$suites" ]; then
        printf 'ERROR: slow-suite TSV row count mismatch: expected %s actual %s\n' \
            "$suites" "$tsv_rows" >&2
        return 1
    fi
    unique_suite_paths="$(cut -f 2 "$slow_tsv_abs" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
    if [ "$unique_suite_paths" != "$suites" ]; then
        printf 'ERROR: slow-suite TSV suite paths must be unique: expected %s actual %s\n' \
            "$suites" "$unique_suite_paths" >&2
        return 1
    fi
    if ! awk -F '\t' '
        NR > 1 && ($1 + 0) > previous {
            exit 1
        }
        {
            previous = $1 + 0
        }
    ' "$slow_tsv_abs"; then
        printf 'ERROR: slow-suite TSV must be sorted by descending elapsed time: %s\n' \
            "$slow_tsv_rel" >&2
        return 1
    fi

    if [ "$recorded_head" != "$expected_head" ]; then
        printf 'ERROR: receipt head_sha mismatch: expected %s actual %s\n' "$expected_head" "$recorded_head" >&2
        return 1
    fi
    case "$suites" in ''|*[!0-9]*)
        printf 'ERROR: suites must be an integer: %s\n' "$suites" >&2
        return 1
        ;;
    esac
    case "$elapsed" in ''|*[!0-9]*)
        printf 'ERROR: elapsed_seconds must be an integer: %s\n' "$elapsed" >&2
        return 1
        ;;
    esac
    case "$exit_code" in ''|*[!0-9]*)
        printf 'ERROR: local_ci_exit_code must be an integer: %s\n' "$exit_code" >&2
        return 1
        ;;
    esac
    case "$budget" in ''|*[!0-9]*)
        printf 'ERROR: budget_seconds must be an integer: %s\n' "$budget" >&2
        return 1
        ;;
    esac

    if [ "$suites" != "$expected_suites" ]; then
        printf 'ERROR: suites mismatch: expected %s actual %s\n' "$expected_suites" "$suites" >&2
        return 1
    fi
    if [ "$elapsed" != "$expected_elapsed" ]; then
        printf 'ERROR: elapsed_seconds mismatch: expected %s actual %s\n' "$expected_elapsed" "$elapsed" >&2
        return 1
    fi
    if [ "$budget" != "$expected_budget" ]; then
        printf 'ERROR: budget_seconds mismatch: expected %s actual %s\n' "$expected_budget" "$budget" >&2
        return 1
    fi

    if [ "$#" -gt 0 ]; then
        validate_pinned_receipt_fields "$receipt_abs" "$@" || return 1
    fi

    if [ "$enforce_budget" = "1" ] && [ "$elapsed" -gt "$budget" ]; then
        printf 'ERROR: local-ci --fast over budget: elapsed_seconds=%s budget_seconds=%s suites=%s\n' \
            "$elapsed" "$budget" "$suites" >&2
        return 1
    fi
}

write_fixture_receipt() {
    local root="$1" receipt_rel="$2" head_sha="$3" raw_log_rel="$4" slow_tsv_rel="$5"
    local raw_log_sha
    mkdir -p "$(dirname "$root/$receipt_rel")" "$(dirname "$root/$raw_log_rel")" "$(dirname "$root/$slow_tsv_rel")"
    printf 'fixture raw log\n' > "$root/$raw_log_rel"
    printf '2\tscripts/tests/fixture_slow_test.sh\t0\n' > "$root/$slow_tsv_rel"
    printf '1\tscripts/tests/fixture_fast_test.sh\t0\n' >> "$root/$slow_tsv_rel"
    raw_log_sha="$(shasum -a 256 "$root/$raw_log_rel" | awk '{ print $1 }')"
    cat > "$root/$receipt_rel" <<EOF
capture_timestamp= 2026-07-28T20:00:50Z
head_sha= $head_sha
suites= 2
elapsed_seconds= 100
elapsed_seconds_exact= 100.25
budget_seconds= 1800
local_ci_exit_code= 0
raw_log_path= $raw_log_rel
raw_log_sha256= $raw_log_sha
slow_suite_tsv_path= $slow_tsv_rel
manifest_count= 3
serial_only_count= 1
reachability_summary= corpus=3 reachable=3 allowlisted=0 quarantined=0 unaccounted=0
reachability_gate_summary= reachability gate: 3 hermetic suite(s) run at concurrency 8, 0 failed
EOF
}

test_fixture_receipt_passes_when_evidence_is_complete() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"

    REPO_ROOT="$tmpdir" validate_budget_receipt "$receipt_rel" "fixture-head" "2" "100" "$BUDGET_SECONDS" "1"
    assert_eq "$?" "0" "complete fixture receipt satisfies the budget contract"
    rm -rf "$tmpdir"
}

test_fixture_rejects_missing_receipt() {
    local tmpdir receipt_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "2" "100" "$BUDGET_SECONDS" "1" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "missing fixture receipt fails closed"
    assert_contains "$output" "baseline receipt missing" "missing receipt failure names the absent artifact"
    rm -rf "$tmpdir"
}

test_fixture_rejects_missing_raw_log() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"
    : > "$tmpdir/$raw_log_rel"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "2" "100" "$BUDGET_SECONDS" "1" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "empty raw log makes fixture receipt fail"
    assert_contains "$output" "raw local-ci log missing or empty" "missing raw log failure names the evidence gap"
    rm -rf "$tmpdir"
}

test_fixture_rejects_redacted_raw_log() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"
    printf 'JWT_SECRET=<redacted-test-fixture>\n' > "$tmpdir/$raw_log_rel"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "2" "100" "$BUDGET_SECONDS" "1" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "redacted raw log makes fixture receipt fail"
    assert_contains "$output" "raw local-ci log contains a redaction marker" \
        "redacted raw log failure names the evidence mutation"
    rm -rf "$tmpdir"
}

test_fixture_rejects_secret_assignment_raw_log() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"
    {
        printf 'JWT_SECRET=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
        printf 'ADMIN_KEY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n'
        printf 'STORAGE_ENCRYPTION_KEY=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n'
    } > "$tmpdir/$raw_log_rel"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "2" "100" "$BUDGET_SECONDS" "1" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "secret assignment raw log makes fixture receipt fail"
    assert_contains "$output" "secret-bearing assignment or credential output" \
        "secret assignment raw log failure names the secret hygiene gap"
    rm -rf "$tmpdir"
}

test_fixture_rejects_additional_secret_material_raw_log() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel secret_line output rc
    local secret_lines=(
        'AWS_SECRET_ACCESS_KEY=fixture_not_a_real_credential'
        'STRIPE_SECRET_KEY=fixture_not_a_real_credential'
        'DATABASE_URL=postgresql://fixture_user:fixture_password@localhost/fixture'
    )

    for secret_line in "${secret_lines[@]}"; do
        tmpdir="$(mktemp -d)"
        receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
        raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
        slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
        write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"
        printf '%s\n' "$secret_line" > "$tmpdir/$raw_log_rel"

        rc=0
        output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
            "$receipt_rel" "fixture-head" "2" "100" "$BUDGET_SECONDS" "1" 2>&1)" || rc=$?
        assert_eq "$rc" "1" "additional secret material in a raw log fails closed"
        assert_contains "$output" "secret-bearing" \
            "additional secret material failure names the secret hygiene gap"
        rm -rf "$tmpdir"
    done
}

test_fixture_rejects_modified_raw_log() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"
    printf 'post-processed line\n' >> "$tmpdir/$raw_log_rel"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "2" "100" "$BUDGET_SECONDS" "1" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "post-processed raw log makes fixture receipt fail"
    assert_contains "$output" "raw local-ci log checksum mismatch" \
        "raw log checksum failure names the evidence mutation"
    rm -rf "$tmpdir"
}

test_fixture_rejects_incomplete_slow_suite_tsv() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"
    printf '1\tscripts/tests/fixture_fast_test.sh\t0\n' > "$tmpdir/$slow_tsv_rel"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "2" "100" "$BUDGET_SECONDS" "1" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "incomplete slow-suite TSV makes fixture receipt fail"
    assert_contains "$output" "slow-suite TSV row count mismatch" \
        "incomplete slow-suite TSV failure names the missing population"
    rm -rf "$tmpdir"
}

test_fixture_rejects_stale_head() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "old-head" "$raw_log_rel" "$slow_tsv_rel"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "current-head" "2" "100" "$BUDGET_SECONDS" "1" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "stale head makes fixture receipt fail"
    assert_contains "$output" "receipt head_sha mismatch" "stale head failure explains the mismatch"
    rm -rf "$tmpdir"
}

test_fixture_rejects_malformed_elapsed_seconds() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"
    perl -0pi -e 's/elapsed_seconds= 100/elapsed_seconds= slow/' "$tmpdir/$receipt_rel"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "2" "100" "$BUDGET_SECONDS" "1" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "malformed elapsed_seconds makes fixture receipt fail"
    assert_contains "$output" "elapsed_seconds must be an integer" "malformed elapsed failure names the bad field"
    rm -rf "$tmpdir"
}

test_fixture_rejects_suite_count_drift() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "3" "100" "$BUDGET_SECONDS" "1" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "receipt suite count must match the measured specimen"
    assert_contains "$output" "suites mismatch" "suite-count drift failure names the changed field"
    rm -rf "$tmpdir"
}

test_fixture_rejects_elapsed_value_drift() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "2" "101" "$BUDGET_SECONDS" "1" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "receipt elapsed value must match the measured specimen"
    assert_contains "$output" "elapsed_seconds mismatch" "elapsed drift failure names the changed field"
    rm -rf "$tmpdir"
}

test_fixture_rejects_budget_drift() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "2" "100" "1799" "1" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "receipt budget must match the test-owned ceiling"
    assert_contains "$output" "budget_seconds mismatch" "budget drift failure names the changed field"
    rm -rf "$tmpdir"
}

test_fixture_rejects_receipt_owned_budget_escape() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"
    perl -0pi -e 's/elapsed_seconds= 100/elapsed_seconds= 2158/; s/budget_seconds= 1800/budget_seconds= 2158/' \
        "$tmpdir/$receipt_rel"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "2" "2158" "$BUDGET_SECONDS" "1" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "receipt cannot raise its own budget ceiling"
    assert_contains "$output" "budget_seconds mismatch" "receipt-owned budget escape failure names the changed field"
    rm -rf "$tmpdir"
}

test_fixture_accepts_final_acceptance_pinned_fields() {
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"

    REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "2" "100" "$BUDGET_SECONDS" "1" \
        "${FINAL_ACCEPTANCE_FIXTURE_FIELDS[@]}"
    assert_eq "$?" "0" "final acceptance fixture receipt satisfies all pinned fields"
    rm -rf "$tmpdir"
}

assert_final_acceptance_fixture_drift_fails() {
    local field="$1" mutation="$2" message="$3"
    local tmpdir receipt_rel raw_log_rel slow_tsv_rel output rc=0
    tmpdir="$(mktemp -d)"
    receipt_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/SUMMARY.md"
    raw_log_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/raw_local_ci_fast.log"
    slow_tsv_rel="docs/audits/test-wiring/fixture_fast_budget_baseline/slow_suites.tsv"
    write_fixture_receipt "$tmpdir" "$receipt_rel" "fixture-head" "$raw_log_rel" "$slow_tsv_rel"
    perl -0pi -e "$mutation" "$tmpdir/$receipt_rel"

    output="$(REPO_ROOT="$tmpdir" validate_budget_receipt \
        "$receipt_rel" "fixture-head" "2" "100" "$BUDGET_SECONDS" "1" \
        "${FINAL_ACCEPTANCE_FIXTURE_FIELDS[@]}" 2>&1)" || rc=$?
    assert_eq "$rc" "1" "$message"
    assert_contains "$output" "$field mismatch" \
        "final acceptance $field failure names the changed field"
    rm -rf "$tmpdir"
}

test_fixture_rejects_final_acceptance_field_drift() {
    assert_final_acceptance_fixture_drift_fails \
        "local_ci_exit_code" \
        's/local_ci_exit_code= 0/local_ci_exit_code= 1/' \
        "final acceptance receipt must reject a nonzero local-ci exit"
    assert_final_acceptance_fixture_drift_fails \
        "elapsed_seconds_exact" \
        's/elapsed_seconds_exact= 100[.]25/elapsed_seconds_exact= 100.26/' \
        "final acceptance receipt must pin exact elapsed seconds"
    assert_final_acceptance_fixture_drift_fails \
        "manifest_count" \
        's/manifest_count= 3/manifest_count= 4/' \
        "final acceptance receipt must pin manifest count"
    assert_final_acceptance_fixture_drift_fails \
        "serial_only_count" \
        's/serial_only_count= 1/serial_only_count= 2/' \
        "final acceptance receipt must pin serial-only count"
    assert_final_acceptance_fixture_drift_fails \
        "reachability_summary" \
        's/reachability_summary= corpus=3 reachable=3/reachability_summary= corpus=3 reachable=2/' \
        "final acceptance receipt must pin reachability summary"
    assert_final_acceptance_fixture_drift_fails \
        "reachability_gate_summary" \
        's/reachability gate: 3 hermetic suite[(]s[)] run at concurrency 8, 0 failed/reachability gate: 3 hermetic suite(s) run at concurrency 8, 1 failed/' \
        "final acceptance receipt must pin reachability gate summary"
}

test_real_baseline_evidence_is_present_and_current() {
    validate_budget_receipt \
        "$BASELINE_RECEIPT_REL" \
        "$BASELINE_HEAD_SHA" \
        "$BASELINE_SUITES" \
        "$BASELINE_ELAPSED_SECONDS" \
        "$BUDGET_SECONDS" \
        "0" \
        "${BASELINE_PINNED_FIELDS[@]}"
    assert_eq "$?" "0" "real baseline receipt has current, parseable, non-empty evidence"
}

test_real_stage2_timing_evidence_is_present_and_source_pinned() {
    local receipt_abs
    receipt_abs="$REPO_ROOT/$STAGE2_RECEIPT_REL"

    assert_eq "$(extract_receipt_value_rest "$receipt_abs" "stage_02_before_algolia_import_catalog_live_probe_test=")" \
        "$STAGE2_ALGOLIA_BEFORE" \
        "Stage 2 receipt records exact Algolia before timing"
    assert_eq "$(extract_receipt_value_rest "$receipt_abs" "stage_02_after_algolia_import_catalog_live_probe_test=")" \
        "$STAGE2_ALGOLIA_AFTER" \
        "Stage 2 receipt records exact Algolia after timing"
    assert_eq "$(extract_receipt_value_rest "$receipt_abs" "stage_02_before_apply_ses_log_read_policy_test=")" \
        "$STAGE2_SES_BEFORE" \
        "Stage 2 receipt records exact SES before timing"
    assert_eq "$(extract_receipt_value_rest "$receipt_abs" "stage_02_after_apply_ses_log_read_policy_test=")" \
        "$STAGE2_SES_AFTER" \
        "Stage 2 receipt records exact SES after timing"
    assert_contains "$(extract_receipt_value_rest "$receipt_abs" "stage_02_timing_note=")" \
        "fake-sleep request order" \
        "Stage 2 receipt explains why added fake-sleep coverage changed timing"
}

# Cross-check a pinned slow-suite TSV against the CURRENT manifest.
#
# Every pinned suite must still be registered unless its path is present in the
# explicit dated deletion ledger above. Filesystem absence is not deletion
# evidence because a renamed suite is also absent at its old path.
#
# Args: <slow_tsv_abs> <suite_root> <manifest_path>...
validate_slow_suite_tsv_manifest_residency() {
    local slow_tsv_abs="$1" suite_root="$2"
    shift 2
    local manifest_paths suite_path deletion_entry deleted_path rc=0

    manifest_paths="$(mktemp)"
    printf '%s\n' "$@" | LC_ALL=C sort -u > "$manifest_paths"
    while IFS=$'\t' read -r _ suite_path _; do
        if [ ! -e "$suite_root/$suite_path" ]; then
            if grep -Fxq "$suite_path" "$manifest_paths"; then
                printf 'ERROR: deleted slow-suite path still registered in manifest: %s\n' \
                    "$suite_path" >&2
                rc=1
                break
            fi
            deleted_path=""
            for deletion_entry in "${SLOW_SUITE_DELETIONS[@]}"; do
                if [ "${deletion_entry#*|}" = "$suite_path" ]; then
                    deleted_path="$suite_path"
                    break
                fi
            done
            if [ "$deleted_path" = "$suite_path" ]; then
                continue
            fi
        fi
        if ! grep -Fxq "$suite_path" "$manifest_paths"; then
            printf 'ERROR: slow-suite TSV path absent from current manifest: %s\n' \
                "$suite_path" >&2
            rc=1
            break
        fi
    done < "$slow_tsv_abs"
    rm -f "$manifest_paths"

    return "$rc"
}

test_real_slow_suite_tsv_matches_registered_manifest() {
    local receipt_abs slow_tsv_rel output rc=0
    receipt_abs="$REPO_ROOT/$STAGE2_RECEIPT_REL"
    slow_tsv_rel="$(extract_receipt_value "$receipt_abs" "slow_suite_tsv_path=")"

    output="$(validate_slow_suite_tsv_manifest_residency \
        "$REPO_ROOT/$slow_tsv_rel" \
        "$REPO_ROOT" \
        "${TEST_REACHABILITY_HERMETIC_TESTS[@]}" 2>&1)" || rc=$?

    assert_eq "$rc" "0" "every source-pinned slow-suite TSV path remains registered"
}

test_source_pinned_slow_suite_tsv_survives_later_manifest_growth() {
    local receipt_abs slow_tsv_rel appended_index output rc=0
    receipt_abs="$REPO_ROOT/$STAGE2_RECEIPT_REL"
    slow_tsv_rel="$(extract_receipt_value "$receipt_abs" "slow_suite_tsv_path=")"
    appended_index="${#TEST_REACHABILITY_HERMETIC_TESTS[@]}"
    TEST_REACHABILITY_HERMETIC_TESTS+=("scripts/tests/synthetic_later_manifest_test.sh")

    output="$(validate_slow_suite_tsv_manifest_residency \
        "$REPO_ROOT/$slow_tsv_rel" \
        "$REPO_ROOT" \
        "${TEST_REACHABILITY_HERMETIC_TESTS[@]}" 2>&1)" || rc=$?
    unset "TEST_REACHABILITY_HERMETIC_TESTS[$appended_index]"

    assert_eq "$rc" "0" \
        "source-pinned slow-suite TSV remains valid after later manifest growth"
}

test_fixture_rejects_slow_suite_path_absent_from_manifest() {
    local tmpdir slow_tsv_abs output rc=0
    tmpdir="$(mktemp -d)"
    slow_tsv_abs="$tmpdir/slow_suites.tsv"
    printf '1\tscripts/tests/fixture_absent_test.sh\t0\n' > "$slow_tsv_abs"
    # The suite must exist under suite_root, otherwise this specimen would
    # exercise the deletion branch instead of the drift branch.
    mkdir -p "$tmpdir/scripts/tests"
    : > "$tmpdir/scripts/tests/fixture_absent_test.sh"

    output="$(validate_slow_suite_tsv_manifest_residency \
        "$slow_tsv_abs" \
        "$tmpdir" \
        "scripts/tests/fixture_present_test.sh" 2>&1)" || rc=$?

    assert_eq "$rc" "1" "slow-suite TSV path absent from the manifest fails closed"
    assert_contains "$output" \
        "slow-suite TSV path absent from current manifest: scripts/tests/fixture_absent_test.sh" \
        "missing manifest residency failure names the absent suite path"
    rm -rf "$tmpdir"
}

test_fixture_rejects_deleted_slow_suite_still_registered_in_manifest() {
    local tmpdir slow_tsv_abs output rc=0
    tmpdir="$(mktemp -d)"
    slow_tsv_abs="$tmpdir/slow_suites.tsv"
    # No file is created under $tmpdir, so the suite reads as deleted while the
    # manifest still lists it — the state that breaks the reachability gate.
    printf '0\tscripts/tests/fixture_deleted_test.sh\t0\n' > "$slow_tsv_abs"

    output="$(validate_slow_suite_tsv_manifest_residency \
        "$slow_tsv_abs" \
        "$tmpdir" \
        "scripts/tests/fixture_deleted_test.sh" 2>&1)" || rc=$?

    assert_eq "$rc" "1" "a deleted suite left registered in the manifest fails closed"
    assert_contains "$output" \
        "deleted slow-suite path still registered in manifest: scripts/tests/fixture_deleted_test.sh" \
        "deleted-suite failure names the stale manifest entry"
    rm -rf "$tmpdir"
}

test_fixture_accepts_deleted_slow_suite_dropped_from_manifest() {
    local tmpdir slow_tsv_abs output rc=0
    tmpdir="$(mktemp -d)"
    slow_tsv_abs="$tmpdir/slow_suites.tsv"
    printf '0\tscripts/tests/security_checks_lib_test.sh\t0\n' > "$slow_tsv_abs"

    output="$(validate_slow_suite_tsv_manifest_residency \
        "$slow_tsv_abs" \
        "$tmpdir" \
        "scripts/tests/fixture_present_test.sh" 2>&1)" || rc=$?

    assert_eq "$rc" "0" \
        "a suite deleted from the repo and dropped from the manifest is not drift"
    assert_eq "$output" "" "clean deletion should emit no residency error"
    rm -rf "$tmpdir"
}

test_fixture_rejects_renamed_slow_suite_dropped_from_manifest() {
    local tmpdir slow_tsv_abs output rc=0
    tmpdir="$(mktemp -d)"
    slow_tsv_abs="$tmpdir/slow_suites.tsv"
    printf '0\tscripts/tests/renamed_old_test.sh\t0\n' > "$slow_tsv_abs"
    mkdir -p "$tmpdir/scripts/tests"
    : > "$tmpdir/scripts/tests/renamed_new_test.sh"

    output="$(validate_slow_suite_tsv_manifest_residency \
        "$slow_tsv_abs" \
        "$tmpdir" \
        "scripts/tests/renamed_new_test.sh" 2>&1)" || rc=$?

    assert_eq "$rc" "1" "a renamed suite cannot silently orphan its pinned timing row"
    assert_contains "$output" \
        "slow-suite TSV path absent from current manifest: scripts/tests/renamed_old_test.sh" \
        "renamed-suite drift names the orphaned pinned path"
    rm -rf "$tmpdir"
}

test_real_baseline_is_under_budget() {
    local output rc=0

    output="$(validate_budget_receipt \
        "$BASELINE_RECEIPT_REL" \
        "$BASELINE_HEAD_SHA" \
        "$BASELINE_SUITES" \
        "$BASELINE_ELAPSED_SECONDS" \
        "$BUDGET_SECONDS" \
        "1" \
        "${BASELINE_PINNED_FIELDS[@]}" 2>&1)" || rc=$?
    assert_eq "$rc" "0" "local-ci --fast must stay within the Stage 1 budget"
    if [ "$rc" = "0" ]; then
        assert_not_contains "$output" "over budget" "budget failure output should be absent when within budget"
    else
        assert_contains "$output" \
            "ERROR: local-ci --fast over budget: elapsed_seconds=$BASELINE_ELAPSED_SECONDS budget_seconds=$BUDGET_SECONDS suites=$BASELINE_SUITES" \
            "real over-budget receipt names the exact elapsed, budget, and suite values"
    fi
}

test_fixture_receipt_passes_when_evidence_is_complete
test_fixture_rejects_missing_receipt
test_fixture_rejects_missing_raw_log
test_fixture_rejects_redacted_raw_log
test_fixture_rejects_secret_assignment_raw_log
test_fixture_rejects_additional_secret_material_raw_log
test_fixture_rejects_modified_raw_log
test_fixture_rejects_incomplete_slow_suite_tsv
test_fixture_rejects_stale_head
test_fixture_rejects_malformed_elapsed_seconds
test_fixture_rejects_suite_count_drift
test_fixture_rejects_elapsed_value_drift
test_fixture_rejects_budget_drift
test_fixture_rejects_receipt_owned_budget_escape
test_fixture_accepts_final_acceptance_pinned_fields
test_fixture_rejects_final_acceptance_field_drift
test_real_baseline_evidence_is_present_and_current
test_real_stage2_timing_evidence_is_present_and_source_pinned
test_real_slow_suite_tsv_matches_registered_manifest
test_source_pinned_slow_suite_tsv_survives_later_manifest_growth
test_fixture_rejects_slow_suite_path_absent_from_manifest
test_fixture_rejects_deleted_slow_suite_still_registered_in_manifest
test_fixture_accepts_deleted_slow_suite_dropped_from_manifest
test_fixture_rejects_renamed_slow_suite_dropped_from_manifest
test_real_baseline_is_under_budget

run_test_summary
