#!/usr/bin/env bash
# Proof that the migration-preview statelessness guard cannot report green
# without executing its before/after algolia_import_jobs row-count assertions.
#
# WHY THIS EXISTS:
# `algolia_preview_does_not_create_import_job_row` is the only automated proof
# that preview stays stateless. Its predecessors in this repo acquired the
# PostgreSQL harness through the Option-returning `connect_and_migrate` and
# returned early when DATABASE_URL was absent, so on a host without a database
# the test reported success while asserting nothing at all. That is a
# false-green: the row-count comparison never ran, yet the suite was green.
#
# The behavioural half of the guard is already load-bearing — with DATABASE_URL
# unset the test panics in `connect_and_migrate_required`. But a behavioural run
# cannot catch the second false-green shape: deleting the before-count read or
# comparing the after-count against a literal instead of the recorded baseline.
# Both mutations leave a test that still touches PostgreSQL and still passes.
#
# So this guard reads the structure of the statelessness test itself and fails
# when the load-bearing shape is gone. Every check below is proved capable of
# failing: the same checker is run against synthetic mutants that each remove
# exactly one load-bearing element, and each mutant must be rejected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREVIEW_SOURCE="$REPO_ROOT/infra/api/tests/integration/migration_routes_test/preview.rs"
HARNESS_SOURCE="$REPO_ROOT/infra/api/tests/integration/migration_routes_test.rs"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

CHECKER="$WORK_DIR/audit_statelessness_guard.py"

cat > "$CHECKER" <<'PY'
"""Audit the structural contract of the preview statelessness test.

argv: <preview_source> <harness_source>
Prints GUARD_OK on success, or one GUARD_VIOLATION line per broken rule.
Exit status is 0 only when every rule holds.
"""
import re
import sys

STATELESSNESS_TEST = "algolia_preview_does_not_create_import_job_row"
REQUIRED_HARNESS_FN = "connect_and_migrate_required"
ROW_COUNT_FN = "count_algolia_import_jobs"


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def split_macro_args(args):
    """Split macro argument text on top-level commas.

    Parenthesis/bracket/brace depth and string literals are tracked so that
    `count_algolia_import_jobs(&db.pool).await` and a message literal
    containing a comma both stay in one argument.
    """
    parts = []
    current = []
    depth = 0
    in_string = False
    escaped = False
    for char in args:
        if in_string:
            current.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
            current.append(char)
        elif char in "([{":
            depth += 1
            current.append(char)
        elif char in ")]}":
            depth -= 1
            current.append(char)
        elif char == "," and depth == 0:
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
    parts.append("".join(current))
    return [part.strip() for part in parts if part.strip()]


def asserts_row_count_identity(args, baseline_name):
    """True only for `assert_eq!(<row-count call>, <baseline>)` in either order.

    Requiring one operand to be the bare baseline identifier is what rejects a
    derived comparison such as `before_count + 1`, which would let preview
    create a row while the guard still reported green.
    """
    operands = split_macro_args(args)[:2]
    if len(operands) != 2:
        return False
    is_baseline = [operand == baseline_name for operand in operands]
    is_row_count = [
        re.search(rf"\b{ROW_COUNT_FN}\s*\(", operand) is not None for operand in operands
    ]
    return any(
        is_baseline[index] and is_row_count[1 - index] for index in (0, 1)
    )


def extract_fn_body(source, name):
    """Return the brace-matched body of `fn name(...)`, or None when absent."""
    match = re.search(rf"\bfn\s+{re.escape(name)}\s*\(", source)
    if match is None:
        return None
    open_index = source.find("{", match.end())
    if open_index == -1:
        return None
    depth = 0
    for index in range(open_index, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[open_index + 1 : index]
    return None


def audit(preview_source, harness_source):
    violations = []

    body = extract_fn_body(preview_source, STATELESSNESS_TEST)
    if body is None:
        return [f"statelessness test {STATELESSNESS_TEST} is missing"]

    # Rule 1: the harness must come from the panicking wrapper. The bare
    # Option-returning `connect_and_migrate` is what allowed the silent skip.
    if not re.search(rf"\b{REQUIRED_HARNESS_FN}\s*\(", body):
        violations.append(
            f"{STATELESSNESS_TEST} must acquire its pool via {REQUIRED_HARNESS_FN}"
        )
    if re.search(r"(?<!_)\bconnect_and_migrate\s*\(", body):
        violations.append(
            f"{STATELESSNESS_TEST} must not use the skippable connect_and_migrate"
        )

    # Rule 2: no early exit may short-circuit the row-count assertion.
    if re.search(r"\breturn\b", body):
        violations.append(
            f"{STATELESSNESS_TEST} must not contain an early return"
        )

    # Rule 3: the preview call must be bracketed by two row-count reads.
    preview_call = re.search(r"\bpost_preview\s*\(", body)
    if preview_call is None:
        return violations + [f"{STATELESSNESS_TEST} must issue a preview request"]
    before_body = body[: preview_call.start()]
    after_body = body[preview_call.end() :]

    baseline = re.search(
        rf"\blet\s+(\w+)\s*=\s*{ROW_COUNT_FN}\s*\(", before_body
    )
    if baseline is None:
        violations.append(
            f"{STATELESSNESS_TEST} must record a {ROW_COUNT_FN} baseline before preview"
        )
        return violations

    # Rule 4: the post-preview assertion must compare a fresh read against that
    # recorded baseline, and against nothing else. Asserting against a literal
    # would pass even if preview wrote a row on a seeded database; asserting
    # against a derived expression such as `before_count + 1` would positively
    # bless the write the test exists to forbid.
    baseline_name = baseline.group(1)
    assertion = re.search(r"assert_eq!\s*\((.*?)\);", after_body, re.DOTALL)
    if assertion is None:
        violations.append(
            f"{STATELESSNESS_TEST} must assert row-count identity after preview"
        )
    else:
        # Scan every assert_eq! after the preview call, not just the first one,
        # so an unrelated status assertion cannot satisfy this rule.
        identity_proved = any(
            asserts_row_count_identity(args, baseline_name)
            for args in re.findall(
                r"assert_eq!\s*\((.*?)\);", after_body, re.DOTALL
            )
        )
        if not identity_proved:
            violations.append(
                f"{STATELESSNESS_TEST} must assert {ROW_COUNT_FN} equals {baseline_name}"
            )

    # Rule 5: the wrapper itself must fail closed rather than hand back an
    # Option the caller can quietly discard.
    harness_body = extract_fn_body(harness_source, REQUIRED_HARNESS_FN)
    if harness_body is None:
        violations.append(f"{REQUIRED_HARNESS_FN} is missing")
    else:
        signature = re.search(
            rf"\bfn\s+{REQUIRED_HARNESS_FN}\s*\([^)]*\)\s*->\s*([^{{]+)",
            harness_source,
        )
        if signature is None or "Option" in signature.group(1):
            violations.append(
                f"{REQUIRED_HARNESS_FN} must return a required DbHarness, not an Option"
            )
        if "panic!" not in harness_body:
            violations.append(
                f"{REQUIRED_HARNESS_FN} must panic when DATABASE_URL is absent"
            )

    return violations


def main():
    preview_source = read(sys.argv[1])
    harness_source = read(sys.argv[2])
    violations = audit(preview_source, harness_source)
    for violation in violations:
        print(f"GUARD_VIOLATION: {violation}")
    if violations:
        return 1
    print("GUARD_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY

run_audit() {
    local preview="$1" harness="$2"
    AUDIT_EXIT_CODE=0
    AUDIT_OUTPUT="$(python3 "$CHECKER" "$preview" "$harness" 2>&1)" || AUDIT_EXIT_CODE=$?
}

# Write a mutated copy of a source file by applying one exact substitution.
# The substitution must match, otherwise the mutant silently degrades into a
# copy of the real source and the rejection assertion becomes vacuous.
mutate() {
    local source="$1" destination="$2" old="$3" new="$4"
    python3 - "$source" "$destination" "$old" "$new" <<'PY'
import sys

source, destination, old, new = sys.argv[1:5]
with open(source, encoding="utf-8") as handle:
    text = handle.read()
occurrences = text.count(old)
if occurrences != 1:
    raise SystemExit(
        f"mutation anchor matched {occurrences} times in {source}; "
        "the guard fixture is stale"
    )
with open(destination, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new))
PY
}

assert_mutant_rejected() {
    local label="$1" preview="$2" harness="$3" expected_reason="$4"
    run_audit "$preview" "$harness"
    if [ "$AUDIT_EXIT_CODE" -eq 0 ]; then
        fail "$label: mutant was accepted; the guard cannot detect this false-green"
        return
    fi
    assert_contains "$AUDIT_OUTPUT" "$expected_reason" \
        "$label should be rejected for the expected reason"
}

# ---------------------------------------------------------------------------
# The live sources must satisfy the contract.
# ---------------------------------------------------------------------------

test_live_statelessness_test_satisfies_contract() {
    run_audit "$PREVIEW_SOURCE" "$HARNESS_SOURCE"
    assert_eq "$AUDIT_EXIT_CODE" "0" \
        "live preview statelessness test must satisfy the guard contract: $AUDIT_OUTPUT"
    assert_contains "$AUDIT_OUTPUT" "GUARD_OK" \
        "live audit should report GUARD_OK"
}

# ---------------------------------------------------------------------------
# Each mutant removes exactly one load-bearing element and must be rejected.
# These are the proof that the guard can fail for a real defect.
# ---------------------------------------------------------------------------

test_silent_skip_harness_is_rejected() {
    local mutant="$WORK_DIR/preview_silent_skip.rs"
    mutate "$PREVIEW_SOURCE" "$mutant" \
        'let db = connect_and_migrate_required("algolia_preview_stateless").await;' \
        'let Some(db) = connect_and_migrate("algolia_preview_stateless").await else { return; };'
    assert_mutant_rejected "silent-skip harness" "$mutant" "$HARNESS_SOURCE" \
        "must not use the skippable connect_and_migrate"
}

test_missing_baseline_read_is_rejected() {
    local mutant="$WORK_DIR/preview_no_baseline.rs"
    mutate "$PREVIEW_SOURCE" "$mutant" \
        'let before_count = count_algolia_import_jobs(&db.pool).await;' \
        ''
    assert_mutant_rejected "missing baseline read" "$mutant" "$HARNESS_SOURCE" \
        "must record a count_algolia_import_jobs baseline before preview"
}

test_literal_row_count_assertion_is_rejected() {
    local mutant="$WORK_DIR/preview_literal_assertion.rs"
    mutate "$PREVIEW_SOURCE" "$mutant" \
        '        count_algolia_import_jobs(&db.pool).await,
        before_count,' \
        '        count_algolia_import_jobs(&db.pool).await,
        count_algolia_import_jobs(&db.pool).await,'
    assert_mutant_rejected "literal row-count assertion" "$mutant" "$HARNESS_SOURCE" \
        "must assert count_algolia_import_jobs equals before_count"
}

test_derived_baseline_assertion_is_rejected() {
    local mutant="$WORK_DIR/preview_derived_baseline.rs"
    mutate "$PREVIEW_SOURCE" "$mutant" \
        '        count_algolia_import_jobs(&db.pool).await,
        before_count,' \
        '        count_algolia_import_jobs(&db.pool).await,
        before_count + 1,'
    assert_mutant_rejected "derived baseline assertion" "$mutant" "$HARNESS_SOURCE" \
        "must assert count_algolia_import_jobs equals before_count"
}

test_baseline_named_only_in_message_is_rejected() {
    local mutant="$WORK_DIR/preview_message_only_baseline.rs"
    mutate "$PREVIEW_SOURCE" "$mutant" \
        '        before_count,
        "preview must remain stateless and avoid algolia_import_jobs writes"' \
        '        0,
        "preview must remain stateless: before_count rows must survive"'
    assert_mutant_rejected "baseline named only in message" "$mutant" "$HARNESS_SOURCE" \
        "must assert count_algolia_import_jobs equals before_count"
}

test_optional_harness_wrapper_is_rejected() {
    local mutant="$WORK_DIR/migration_routes_optional_harness.rs"
    mutate "$HARNESS_SOURCE" "$mutant" \
        'async fn connect_and_migrate_required(schema_prefix: &str) -> DbHarness {' \
        'async fn connect_and_migrate_required(schema_prefix: &str) -> Option<DbHarness> {'
    assert_mutant_rejected "optional harness wrapper" "$PREVIEW_SOURCE" "$mutant" \
        "must return a required DbHarness, not an Option"
}

test_non_panicking_harness_wrapper_is_rejected() {
    local mutant="$WORK_DIR/migration_routes_no_panic.rs"
    mutate "$HARNESS_SOURCE" "$mutant" \
        'panic!("DATABASE_URL must be set for Stage 4 PostgreSQL migration read tests")' \
        'DbHarness::default()'
    assert_mutant_rejected "non-panicking harness wrapper" "$PREVIEW_SOURCE" "$mutant" \
        "must panic when DATABASE_URL is absent"
}

test_live_statelessness_test_satisfies_contract
test_silent_skip_harness_is_rejected
test_missing_baseline_read_is_rejected
test_literal_row_count_assertion_is_rejected
test_derived_baseline_assertion_is_rejected
test_baseline_named_only_in_message_is_rejected
test_optional_harness_wrapper_is_rejected
test_non_panicking_harness_wrapper_is_rejected

run_test_summary
