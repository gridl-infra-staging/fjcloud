#!/usr/bin/env bash
# Security validation checks for the backend reliability gate.
#
# CANONICAL OWNER (consolidated 2026-07-30).
# This file is the single tracked `security_checks.sh` in the repo. Two rivals
# were deleted in the same commit that repointed their pointers:
#   - scripts/lib/security_checks.sh          (rival library)
#   - scripts/reliability/security_checks.sh  (CLI orchestrator)
# This file won because it has the callers and the downstream contract:
#   - sourced by scripts/local-ci.sh and
#     scripts/reliability/run_backend_reliability_gate.sh,
#   - sole owner of check_sql_guard / check_cmd_injection / run_security_suite,
#   - run_security_suite is exposed as raw JSON by
#     scripts/reliability/run_security_suite.sh and wrapped for human use by
#     local-ci's opt-in security-suite gate, while its JSON/counting contract
#     lives in security_suite_summary.py,
#   - sole owner of the SECURITY_* reason codes that the reliability gate and
#     the RC evidence collectors parse.
# The rival's one *better* behaviour — failing closed when cargo-audit is
# absent — was ported into check_dep_audit here rather than kept over there.
# `scripts/tests/security_checks_test.sh` is the sole test owner of this file.
#
# This library provides security checks that can be run individually or
# as a grouped security suite. Each check function follows the existing
# gate pattern: exit 0 = pass, exit 1 = fail, with REASON: code output.
#
# Functions:
#   check_secret_scan        — Scan for AWS keys / secrets in codebase
#   check_dep_audit          — Run cargo audit against workspace
#   check_sql_guard          — Scan for unsafe sqlx::query patterns
#   check_cmd_injection      — Scan for unsafe Command::new with variable args
#   run_security_suite       — Execute all checks and emit JSON summary
#
# Reason Codes:
#   SECURITY_SECRET_FOUND        — Secret detected in source
#   SECURITY_SECRET_CLEAN        — No secrets found in scanned paths
#   SECURITY_DEP_AUDIT_PASS      — Dependency audit passed
#   SECURITY_DEP_AUDIT_FAIL_ADVISORIES
#                                  — Critical/high vulnerabilities found
#   SECURITY_DEP_AUDIT_FAIL      — Audit output was unusable
#   SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING  — cargo-audit not installed (FAILS the
#                                  check; the code stays distinct from
#                                  SECURITY_DEP_AUDIT_FAIL so callers can still
#                                  tell "tool absent" from "vulnerabilities found")
#   SECURITY_DEP_AUDIT_WARN      — Advisory/low/medium/info vulnerabilities found
#   SECURITY_SQL_UNSAFE          — Unsafe SQL pattern detected
#   SECURITY_SQL_CLEAN           — No unsafe SQL patterns found
#   SECURITY_CMD_INJECTION_FOUND  — Command::new used with non-literal argument
#   SECURITY_CMD_CLEAN            — No unsafe command construction patterns found
#   SECURITY_CHECK_ERROR         — Check itself encountered an error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/scripts/lib/live_gate.sh"

# grep --exclude-dir only matches base directory names, not paths.
# Use SECURITY_EXCLUDED_DIRS for directories and SECURITY_EXCLUDED_FILES for file patterns.
SECURITY_EXCLUDED_DIRS=(
    ".secret"
    ".hashbrown"
    "target"
    ".git"
    "node_modules"
    ".matt"
    # chats/ and chatting/ hold AI-coding-agent checklist artifacts and
    # session-end status notes (markdown). They legitimately quote pattern
    # strings and filename slugs that match the secret-detection heuristics
    # (e.g. Stripe key prefixes discussed in prose). These are not leaked
    # secrets — they document the rejection contract the implementation must
    # satisfy. Excluding both dirs mirrors the existing IMPLEMENTATION_CHECKLIST/
    # exclusion. Note: a tighter `\<fj_` word-boundary regex (above) handles
    # most filename-slug false positives even outside these dirs.
    "chats"
    "chatting"
    "data"
    "tests"
    "IMPLEMENTATION_CHECKLIST"
    ".mike"
)

SECURITY_EXCLUDED_FILES=(
    "tests_stage7_*"
    "*.test.*"
)

# Candidate discovery deliberately uses a broad fj_ branch. GNU and BSD grep
# disagree about the `\<` word-boundary extension, so the authoritative,
# portable boundary and placeholder classification lives in
# _contains_non_placeholder_secret_token below.
SECURITY_SECRET_PATTERN='AKIA[0-9A-Z]{16}|sk_live_[A-Za-z0-9]{24,}|sk_test_[A-Za-z0-9]{24,}|rk_live_[A-Za-z0-9]{24,}|rk_test_[A-Za-z0-9]{24,}|whsec_[A-Za-z0-9]{20,}|fj_[A-Za-z0-9_]{20,}'

# _ms_now is provided by live_gate.sh (shared across all gate libs)

_validate_include_fixtures() {
    case "${1:-false}" in
        true)  printf 'true\n' ;;
        false|"") printf 'false\n' ;;
        *)
            echo "REASON: SECURITY_CHECK_ERROR" >&2
            echo "invalid include_fixtures flag" >&2
            return 2
            ;;
    esac
}

_is_security_fixture_path() {
    local path="$1"
    case "$path" in
        */scripts/reliability/fixtures/security/*|scripts/reliability/fixtures/security/*|\
        */scripts/reliability/fixtures/security|scripts/reliability/fixtures/security)
            return 0
            ;;
    esac
    return 1
}

_is_command_new_literal_arg() {
    local arg="$1"
    # Safe command name literals: "cmd", &"cmd", r"cmd", r#"cmd"#, b"cmd", br#"cmd"#
    if [[ "$arg" =~ ^\&?\" ]] || [[ "$arg" =~ ^\&?r[#]*\" ]] || [[ "$arg" =~ ^\&?b\" ]] || [[ "$arg" =~ ^\&?br[#]*\" ]]; then
        return 0
    fi
    return 1
}

_contains_non_placeholder_secret_token() {
    local path="$1"
    python3 - "$path" <<'PY'
import re
import sys

text = open(sys.argv[1], "r", encoding="utf-8", errors="ignore").read()
pattern = re.compile(
    r"AKIA[0-9A-Z]{16}"
    r"|sk_(?:live|test)_[A-Za-z0-9]{24,}"
    r"|rk_(?:live|test)_[A-Za-z0-9]{24,}"
    r"|whsec_[A-Za-z0-9]{20,}"
    r"|(?<![A-Za-z0-9_])fj_[A-Za-z0-9_]{20,}"
)
for match in pattern.finditer(text):
    token = match.group(0)
    if token.startswith(("fj_local_dev_", "fj_ts_migration_", "fj_stage5_probe_")):
        continue
    if token.endswith("_placeholder"):
        continue
    raise SystemExit(0)
raise SystemExit(1)
PY
}

_path_matches_excluded_file_pattern() {
    local path="$1"
    local base_name
    base_name="$(basename "$path")"

    case "$base_name" in
        tests_stage7_*|*.test.*)
            return 0
            ;;
    esac

    return 1
}

_path_contains_excluded_dir() {
    local path="$1"
    local excluded_dir
    for excluded_dir in "${SECURITY_EXCLUDED_DIRS[@]}"; do
        case "$path" in
            "$excluded_dir"/*|*/"$excluded_dir"/*|"$excluded_dir")
                return 0
                ;;
        esac
    done

    return 1
}

_scan_path_has_git_index() {
    local scan_path="$1"
    git -C "$scan_path" rev-parse --show-toplevel >/dev/null 2>&1
}

_git_tracked_secret_matches() {
    local scan_path="$1"
    local git_root
    git_root="$(git -C "$scan_path" rev-parse --show-toplevel)"

    local scan_abs
    scan_abs="$(cd "$scan_path" && pwd)"

    local scan_rel="."
    if [ "$scan_abs" != "$git_root" ]; then
        scan_rel="${scan_abs#"$git_root"/}"
    fi

    local git_matches_raw
    git_matches_raw="$(git -C "$git_root" grep -l -I -E \
        "$SECURITY_SECRET_PATTERN" -- "$scan_rel" 2>/dev/null || true)"

    local findings=""
    local rel_path
    while IFS= read -r rel_path; do
        [ -z "$rel_path" ] && continue
        if _path_contains_excluded_dir "$rel_path"; then
            continue
        fi
        if _is_security_fixture_path "$git_root/$rel_path"; then
            continue
        fi
        if _path_matches_excluded_file_pattern "$rel_path"; then
            continue
        fi
        if ! _contains_non_placeholder_secret_token "$git_root/$rel_path"; then
            continue
        fi
        findings+="$git_root/$rel_path"$'\n'
    done <<< "$git_matches_raw"

    printf '%s' "$findings"
}

check_secret_scan() {
    local scan_path="${1:-"$REPO_ROOT"}"
    local include_fixtures
    include_fixtures="$(_validate_include_fixtures "${2:-false}")" || return $?
    local start_ms
    start_ms="$(_ms_now)"

    local findings_raw
    if [ "$include_fixtures" != "true" ] && [ -d "$scan_path" ] && _scan_path_has_git_index "$scan_path"; then
        # For repo-backed scans, search tracked files directly instead of walking the
        # whole checkout. This avoids local build artifacts dominating scan time.
        findings_raw="$(_git_tracked_secret_matches "$scan_path")"
    else
        local grep_cmd=("grep" "-r" "-E" "--files-with-matches" "$SECURITY_SECRET_PATTERN" "$scan_path")
        if [ "$include_fixtures" != "true" ]; then
            for dir in "${SECURITY_EXCLUDED_DIRS[@]}"; do
                grep_cmd+=("--exclude-dir=$dir")
            done
            for pattern in "${SECURITY_EXCLUDED_FILES[@]}"; do
                grep_cmd+=("--exclude=$pattern")
            done
        fi
        findings_raw="$("${grep_cmd[@]}" 2>/dev/null || true)"
    fi

    local findings=""
    if [ "$include_fixtures" != "true" ] && [ -d "$scan_path" ] && _scan_path_has_git_index "$scan_path"; then
        findings="$findings_raw"
    elif [ "$include_fixtures" != "true" ]; then
        # Exclude only the seeded security fixture path, not arbitrary "fixtures" dirs.
        while IFS= read -r path; do
            [ -z "$path" ] && continue
            if _is_security_fixture_path "$path"; then
                continue
            fi
            # Keep local-dev placeholders from triggering false positives while still
            # failing when any other secret token is present in the same file.
            if ! _contains_non_placeholder_secret_token "$path"; then
                continue
            fi
            findings+="$path"$'\n'
        done <<< "$findings_raw"
    else
        findings="$findings_raw"
    fi

    if [ -n "$findings" ]; then
        echo "REASON: SECURITY_SECRET_FOUND" >&2
        echo "Found secrets in: $(echo "$findings" | tr '\n' ' ')" >&2
        return 1
    fi

    echo "REASON: SECURITY_SECRET_CLEAN" >&2
    return 0
}

check_cmd_injection() {
    local scan_path="${1:-"$REPO_ROOT/infra"}"
    local include_fixtures
    include_fixtures="$(_validate_include_fixtures "${2:-false}")" || return $?
    local grep_excludes=()
    if [ "$include_fixtures" != "true" ]; then
        grep_excludes+=("--exclude-dir=target")
        grep_excludes+=("--exclude-dir=tests")
    fi

    local matches
    if [ "${#grep_excludes[@]}" -gt 0 ]; then
        matches="$(grep -r -n -E 'std::process::Command::new\(|Command::new\(' "$scan_path" --include="*.rs" "${grep_excludes[@]}" 2>/dev/null || true)"
    else
        matches="$(grep -r -n -E 'std::process::Command::new\(|Command::new\(' "$scan_path" --include="*.rs" 2>/dev/null || true)"
    fi

    local findings=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue

        local match_file
        match_file="${line%%:*}"
        if [ "$include_fixtures" != "true" ] && _is_security_fixture_path "$match_file"; then
            continue
        fi

        local arg
        arg="$(echo "$line" | sed -E 's/.*Command::new\s*\(\s*([^,)]*).*/\1/')"

        if [ -z "$arg" ]; then
            continue
        fi

        arg="${arg#"${arg%%[![:space:]]*}"}"

        if _is_command_new_literal_arg "$arg"; then
            continue
        fi

        findings+="$line"$'\n'
    done <<< "$matches"

    if [ -n "$findings" ]; then
        echo "REASON: SECURITY_CMD_INJECTION_FOUND" >&2
        echo "Found unsafe Command::new usage in: $(echo "$findings" | tr '\n' ' ')" >&2
        return 1
    fi

    echo "REASON: SECURITY_CMD_CLEAN" >&2
    return 0
}

# check_dep_audit — run `cargo audit` over the infra workspace.
#
# Exit contract:
#   0 — audit ran and found nothing at critical/high severity
#       (SECURITY_DEP_AUDIT_PASS, or SECURITY_DEP_AUDIT_WARN for advisory/low/
#       medium/info findings)
#   1 — audit found critical/high vulnerabilities
#       (SECURITY_DEP_AUDIT_FAIL_ADVISORIES),
#       the audit output was unparsable (SECURITY_DEP_AUDIT_FAIL), or
#       cargo-audit is not installed (SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING)
#
# Missing tooling FAILS CLOSED. A dependency audit that never ran proves
# nothing about the dependency tree, so reporting it as a pass would be a guard
# that cannot fail. The distinct SKIP_TOOL_MISSING reason code is retained so
# callers can still tell "install cargo-audit" from "you have a live CVE".
check_dep_audit() {
    if ! command -v cargo-audit &>/dev/null; then
        echo "REASON: SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING" >&2
        return 1
    fi

    local audit_output_file

    audit_output_file="$(mktemp)"

    if ! (cd "$REPO_ROOT/infra" && cargo audit --json >"$audit_output_file" 2>/dev/null); then
        :
    fi

    # Severity classification lives in scripts/lib/cvss_severity.py. It was
    # extracted from an embedded heredoc: bash 3.2 scans a $( ... ) command
    # substitution for quote balance even inside a quoted heredoc, so a single
    # apostrophe in that Python broke this whole library at parse time. The
    # script prints one of pass/warn/fail on stdout, names blocking advisories
    # on stderr, and exits non-zero only when the report is unparsable — in
    # which case we fail closed rather than trust an unreadable audit.
    local audit_verdict
    if ! audit_verdict="$(python3 "$REPO_ROOT/scripts/lib/cvss_severity.py" "$audit_output_file")"; then
        rm -f "$audit_output_file"
        echo "REASON: SECURITY_DEP_AUDIT_FAIL" >&2
        echo "Unable to parse cargo audit JSON output" >&2
        return 1
    fi

    rm -f "$audit_output_file"

    case "$audit_verdict" in
        pass)
            echo "REASON: SECURITY_DEP_AUDIT_PASS" >&2
            return 0
            ;;
        warn)
            echo "REASON: SECURITY_DEP_AUDIT_WARN" >&2
            return 0
            ;;
        fail)
            echo "REASON: SECURITY_DEP_AUDIT_FAIL_ADVISORIES" >&2
            echo "Vulnerabilities found by cargo audit" >&2
            return 1
            ;;
        *)
            echo "REASON: SECURITY_DEP_AUDIT_FAIL" >&2
            echo "cargo audit returned unparsable vulnerability data" >&2
            return 1
            ;;
    esac
}

check_sql_guard() {
    local scan_path="${1:-"$REPO_ROOT/infra"}"
    local include_fixtures
    include_fixtures="$(_validate_include_fixtures "${2:-false}")" || return $?

    local unsafe_patterns=(
        'sqlx::query\(&format!'
        'sqlx::query\(&.*\+'
        'sqlx::query\(&concat!'
    )

    local grep_excludes=()
    if [ "$include_fixtures" != "true" ]; then
        # Production guard should scan source paths, not test-only fixtures.
        grep_excludes+=("--exclude-dir=tests")
        grep_excludes+=("--exclude-dir=target")
    fi

    local findings=""
    for pattern in "${unsafe_patterns[@]}"; do
        local matches
        if [ "${#grep_excludes[@]}" -gt 0 ]; then
            matches="$(grep -r -E "$pattern" "$scan_path" --include="*.rs" "${grep_excludes[@]}" 2>/dev/null || true)"
        else
            matches="$(grep -r -E "$pattern" "$scan_path" --include="*.rs" 2>/dev/null || true)"
        fi
        if [ -n "$matches" ]; then
            while IFS= read -r line; do
                if [ "$include_fixtures" = "true" ] || [[ ! "$line" =~ fixtures/security ]]; then
                    findings+="$line"$'\n'
                fi
            done <<< "$matches"
        fi
    done

    if [ -n "$findings" ]; then
        local count
        count="$(echo "$findings" | grep -c '.' || echo 0)"
        echo "REASON: SECURITY_SQL_UNSAFE" >&2
        echo "Found $count unsafe sqlx::query patterns" >&2
        return 1
    fi

    echo "REASON: SECURITY_SQL_CLEAN" >&2
    return 0
}

# Execute all canonical checks and emit their shared machine-readable summary.
run_security_suite() {
    # Counting has a single owner: security_suite_summary.py rebuilds every
    # counter from the TSV and decides the suite verdict via its exit status.
    # The bash loop only classifies each check into a TSV row — it must not
    # keep its own failure/run/skip counters, or the exit code and the JSON
    # `passed` field would be two copies of the same rule that can drift apart.
    local suite_start_ms
    suite_start_ms="$(_ms_now)"

    local data_file
    data_file="$(mktemp)"

    local checks=(
        "check_secret_scan:$REPO_ROOT"
        "check_dep_audit:"
        "check_sql_guard:$REPO_ROOT/infra"
        "check_cmd_injection:$REPO_ROOT/infra"
    )

    for check_entry in "${checks[@]}"; do
        local check_name="${check_entry%%:*}"
        local check_arg="${check_entry#*:}"

        local check_start_ms
        check_start_ms="$(_ms_now)"

        local output
        local exit_code=0

        if [ -n "$check_arg" ]; then
            output="$("$check_name" "$check_arg" 2>&1)" || exit_code=$?
        else
            output="$("$check_name" 2>&1)" || exit_code=$?
        fi

        local reason_line
        reason_line="$(echo "$output" | grep -m1 '^REASON:' || true)"
        local reason_code
        reason_code="$(_strip_reason_prefix "$reason_line")"

        local error_class=""
        local check_end_ms
        check_end_ms="$(_ms_now)"
        local elapsed=$(( check_end_ms - check_start_ms ))

        local status
        case "$exit_code" in
            0)
                if [[ "$reason_code" == *"SKIP"* ]]; then
                    # The check chose to skip and still exited success — a
                    # genuine non-failing skip (status vocabulary matches
                    # live-backend-gate.sh, where "skipped" does not fail).
                    status="skipped"
                    error_class="precondition"
                else
                    status="pass"
                fi
                ;;
            1|*)
                if [[ "$reason_code" == *"SKIP"* ]]; then
                    # A precondition failure (e.g. cargo-audit not installed):
                    # the check never ran its substantive logic AND exited
                    # non-zero, so it FAILS the suite — a guard that never ran
                    # proves nothing. It is a real failure, so it carries
                    # status="fail" (aligned with live-backend-gate.sh, which
                    # treats "skipped" as non-failing). error_class="precondition"
                    # is what preserves the "tool absent" vs "vulnerability found"
                    # distinction and keeps it out of checks_run.
                    status="fail"
                    error_class="precondition"
                else
                    status="fail"
                    error_class="runtime"
                    if [ -z "$reason_code" ]; then
                        reason_code="SECURITY_CHECK_ERROR"
                    fi
                fi
                ;;
        esac

        # Write TSV row: name, status, elapsed_ms, reason, error_class
        # Column order matches build_json in live-backend-gate.sh (first 4 cols aligned)
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$check_name" "$status" "$elapsed" "$reason_code" "$error_class" >> "$data_file"
    done

    local suite_end_ms
    suite_end_ms="$(_ms_now)"
    local total_elapsed=$(( suite_end_ms - suite_start_ms ))

    local suite_exit=0
    # The helper owns both the JSON `passed` field and the exit code, so those
    # two representations of the suite verdict cannot drift.
    python3 "$REPO_ROOT/scripts/lib/security_suite_summary.py" \
        "$data_file" "$total_elapsed" || suite_exit=$?

    rm -f "$data_file"

    return "$suite_exit"
}

__SECURITY_CHECKS_SOURCED=1
