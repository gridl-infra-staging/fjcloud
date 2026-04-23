#!/usr/bin/env bash
# Security validation checks for the backend reliability gate.
#
# Three automated checks:
#   check_cargo_audit         — cargo audit for known vulnerable dependencies
#   check_secret_scan         — scan tracked files for leaked secrets/key patterns
#   check_unsafe_code_patterns — grep Rust source for SQL interpolation and unsafe Command::new
#
# Each function prints a single JSON line to stdout and returns 0 (pass) or 1 (fail/skip).
# On failure, emits REASON:<code> to stderr for structured reason extraction.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --------------------------------------------------------------------------
# check_cargo_audit
# Runs `cargo audit` against a Cargo.lock file.
#
# Arguments:
#   $1 — path to Cargo.lock (default: infra/Cargo.lock relative to REPO_ROOT)
#
# Outcomes:
#   - cargo-audit not installed → REASON:cargo_audit_not_installed, status=skip, return 1
#   - advisories found          → REASON:vulnerable_dependencies, status=fail, return 1
#   - clean                     → status=pass, return 0
# --------------------------------------------------------------------------
check_cargo_audit() {
    local cargo_lock="${1:-}"
    if [ -z "$cargo_lock" ]; then
        local repo_root
        repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
        cargo_lock="$repo_root/infra/Cargo.lock"
    fi

    if ! command -v cargo-audit >/dev/null 2>&1; then
        echo "REASON:cargo_audit_not_installed" >&2
        echo '{"check":"cargo_audit","status":"skip","reason":"cargo_audit_not_installed"}'
        return 1
    fi

    if [ ! -f "$cargo_lock" ]; then
        echo "REASON:cargo_lock_missing" >&2
        echo '{"check":"cargo_audit","status":"fail","reason":"cargo_lock_missing"}'
        return 1
    fi

    # Run from infra/ directory so .cargo/audit.toml ignore list is picked up.
    local audit_dir
    audit_dir="$(dirname "$cargo_lock")"
    local audit_output exit_code=0
    audit_output="$(cd "$audit_dir" && cargo audit -f "$cargo_lock" 2>&1)" || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        local advisory_count
        advisory_count="$(echo "$audit_output" | grep -c 'RUSTSEC-' || true)"
        echo "REASON:vulnerable_dependencies" >&2
        echo "{\"check\":\"cargo_audit\",\"status\":\"fail\",\"reason\":\"vulnerable_dependencies\",\"advisory_count\":$advisory_count}"
        return 1
    fi

    echo '{"check":"cargo_audit","status":"pass","reason":""}'
    return 0
}

# --------------------------------------------------------------------------
# check_secret_scan
# Scans tracked files for known secret patterns.
#
# Arguments:
#   $1 — repo root directory (default: detected from SCRIPT_DIR)
#   $2 — optional scan path override (for testing against fixture dirs)
#
# Patterns:
#   AKIA[A-Z0-9]{16}          — AWS access key IDs
#   fj_live_[a-z0-9]{32,}     — Flapjack live keys
#
# Exclusions:
#   .secret/, *.pem, *_accessKeys.csv, Cargo.lock, *.json,
#   scripts/tests/fixtures/
#
# Outcomes:
#   - secret found → REASON:secret_leaked, return 1
#   - clean        → status=pass, return 0
# --------------------------------------------------------------------------
check_secret_scan() {
    local repo_root="${1:-}"
    if [ -z "$repo_root" ]; then
        repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
    fi
    local scan_target="${2:-}"

    local -a patterns=(
        'AKIA[A-Z0-9]{16}'
        'fj_live_[a-z0-9]{32,}'
    )

    # Post-filter patterns to exclude test files and non-source artifacts.
    # git pathspec '*' does not match '/' so we filter after git ls-files.
    local -a exclude_filters=(
        '_test\.rs$'
        '_test\.ts$'
        '_test\.sh$'
        '\.test\.ts$'
        '\.test\.js$'
        'tests_stage'
        '\.secret/'
        '\.pem$'
        '_accessKeys\.csv$'
        'Cargo\.lock$'
        '\.json$'
        'scripts/tests/fixtures/'
        'scripts/reliability/fixtures/'
        'IMPLEMENTATION_CHECKLIST/'
    )

    local found_secrets=false
    local leaked_files=""

    if [ -n "$scan_target" ]; then
        # Direct file/directory scan (for testing)
        for pattern in "${patterns[@]}"; do
            local matches
            matches="$(grep -rEn "$pattern" "$scan_target" 2>/dev/null || true)"
            if [ -n "$matches" ]; then
                found_secrets=true
                while IFS= read -r line; do
                    leaked_files="${leaked_files}${line}\n"
                done <<< "$matches"
            fi
        done
    else
        # Git-tracked file scan (production mode)
        cd "$repo_root"

        # Build a combined exclude regex from filter patterns
        local exclude_regex
        exclude_regex="$(printf '%s|' "${exclude_filters[@]}")"
        exclude_regex="${exclude_regex%|}"  # strip trailing |

        local tracked_files
        tracked_files="$(git ls-files 2>/dev/null | grep -Ev "$exclude_regex" || true)"

        if [ -z "$tracked_files" ]; then
            echo '{"check":"secret_scan","status":"pass","reason":""}'
            return 0
        fi

        for pattern in "${patterns[@]}"; do
            local matches
            matches="$(echo "$tracked_files" | xargs grep -En "$pattern" 2>/dev/null || true)"
            if [ -n "$matches" ]; then
                found_secrets=true
                while IFS= read -r line; do
                    leaked_files="${leaked_files}${line}\n"
                done <<< "$matches"
            fi
        done
    fi

    if $found_secrets; then
        echo "REASON:secret_leaked" >&2
        echo "{\"check\":\"secret_scan\",\"status\":\"fail\",\"reason\":\"secret_leaked\"}"
        return 1
    fi

    echo '{"check":"secret_scan","status":"pass","reason":""}'
    return 0
}

# --------------------------------------------------------------------------
# check_unsafe_code_patterns
# Scans Rust source for dangerous patterns:
#   1. format!() with SQL keywords and {} interpolation
#   2. Command::new() with variable arguments (not string literals)
#
# Arguments:
#   $1 — scan directory (default: infra/api/src/ relative to REPO_ROOT)
#
# Outcomes:
#   - sql interpolation found → REASON:sql_interpolation, return 1
#   - unsafe command found    → REASON:unsafe_command, return 1
#   - clean                   → status=pass, return 0
# --------------------------------------------------------------------------
check_unsafe_code_patterns() {
    local scan_dir="${1:-}"
    if [ -z "$scan_dir" ]; then
        local repo_root
        repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
        scan_dir="$repo_root/infra/api/src"
    fi

    if [ ! -d "$scan_dir" ] && [ ! -f "$scan_dir" ]; then
        echo '{"check":"unsafe_code_patterns","status":"pass","reason":"scan_dir_not_found"}'
        return 0
    fi

    local found_issues=false
    local issue_type=""

    # Pattern 1: format! with SQL keywords and {} interpolation
    # Matches: format!("SELECT ... {}", var) or format!("INSERT ... {var}")
    local sql_matches
    sql_matches="$(grep -rEn 'format!\s*\(.*\b(SELECT|INSERT|UPDATE|DELETE|DROP|CREATE|ALTER)\b.*\{' "$scan_dir" --include='*.rs' 2>/dev/null || true)"

    if [ -n "$sql_matches" ]; then
        found_issues=true
        issue_type="sql_interpolation"
        echo "REASON:sql_interpolation" >&2
        echo "{\"check\":\"unsafe_code_patterns\",\"status\":\"fail\",\"reason\":\"sql_interpolation\"}"
        return 1
    fi

    # Pattern 2: Command::new with variable argument (not a string literal)
    # Matches: Command::new(variable) but NOT Command::new("literal")
    local cmd_matches
    cmd_matches="$(grep -rEn 'Command::new\([^"'"'"']' "$scan_dir" --include='*.rs' 2>/dev/null || true)"

    if [ -n "$cmd_matches" ]; then
        found_issues=true
        issue_type="unsafe_command"
        echo "REASON:unsafe_command" >&2
        echo "{\"check\":\"unsafe_code_patterns\",\"status\":\"fail\",\"reason\":\"unsafe_command\"}"
        return 1
    fi

    echo '{"check":"unsafe_code_patterns","status":"pass","reason":""}'
    return 0
}
