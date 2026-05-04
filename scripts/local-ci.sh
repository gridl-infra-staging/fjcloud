#!/usr/bin/env bash
## HELP-TEXT-BEGIN
# local-ci.sh — Run every gate the staging deploy-staging job depends on,
# locally, in parallel where safe. Designed to catch CI failures BEFORE the
# staging CI cycle so dev iteration is fast.
#
# ---------------------------------------------------------------------------
# Why this exists
# ---------------------------------------------------------------------------
# Staging CI on private→public mirror typically runs 30-50 minutes per
# cycle (rust-test + deploy-staging dominate). Many failures are catchable
# in seconds locally (formatter, file sizes, lint, static contract tests,
# secret scan). Burning a 30+ min cycle on a `cargo fmt --check` violation
# is wasteful and slow.
#
# This script mirrors the deploy-staging needs[] list from
# .github/workflows/ci.yml:
#   rust-test, rust-lint, migration-test, web-test,
#   check-sizes, web-lint, secret-scan
#
# Each gate maps to its CI counterpart line-for-line where possible. When
# the local equivalent diverges (e.g. gitleaks may not be installed
# locally, postgres may not be running) the script either auto-installs,
# falls back to the repo's reliability secret-scan, or marks the gate as
# SKIP with a clear remediation hint — never as silent PASS.
#
# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
#   --fast (default) Skip the cold cargo workspace test (slow: 5-10 min
#                    on a clean target/, ~1-2 min cached). All other
#                    gates run in well under 2 minutes total.
#   --full           Include `cargo test --workspace`. Use before pushing
#                    a non-trivial Rust change.
#   --gate <NAME>    Run only one gate (rust-test, rust-lint,
#                    migration-test, web-test, check-sizes, web-lint,
#                    secret-scan).
#   --help           This message.
#
# ---------------------------------------------------------------------------
# Exit codes
# ---------------------------------------------------------------------------
#   0    All requested gates passed (SKIP counts as pass with a banner).
#   1    Any gate FAILed.
#   2    Usage / argument parsing error.
## HELP-TEXT-END

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

MODE="fast"
SINGLE_GATE=""

# Extract the help block bounded by `## HELP-TEXT-BEGIN/END` sentinels in
# this script's own comments. Using sentinels (rather than line numbers
# like `sed -n '1,42p'`) keeps the help text robust against future header
# edits — if someone adds or removes a comment line, the help still works.
usage() {
    awk '
        /^## HELP-TEXT-END$/   { exit }
        in_block               { sub(/^# ?/, ""); print }
        /^## HELP-TEXT-BEGIN$/ { in_block=1 }
    ' "$0"
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --fast)  MODE="fast";  shift ;;
        --full)  MODE="full";  shift ;;
        --gate)  SINGLE_GATE="${2:-}"; shift 2 ;;
        --help|-h) usage 0 ;;
        *) echo "ERROR: unknown arg: $1" >&2; usage 2 ;;
    esac
done

# Color helpers — write directly to /dev/tty so summary stays readable even
# when the script's own stdout is captured by a wrapper.
if [ -t 1 ]; then
    C_RED='\033[31m'; C_GRN='\033[32m'; C_YEL='\033[33m'
    C_BLU='\033[34m'; C_BOLD='\033[1m';   C_RESET='\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BOLD=''; C_RESET=''
fi

LOG_DIR="$(mktemp -d)"
# Keep logs until next run so the summary's log paths stay readable for
# investigation. Cleanup runs at the START of the next invocation rather
# than on EXIT — otherwise the paths printed in the summary point at
# already-deleted files. (Real bug found 2026-04-30 self-review.)
KEEP_LOG_DIR="${TMPDIR:-/tmp}/local-ci-last-logs"
rm -rf "$KEEP_LOG_DIR"
trap 'mv "$LOG_DIR" "$KEEP_LOG_DIR" 2>/dev/null || true' EXIT

# Per-gate result registry: name | status | seconds | log_path
RESULTS_FILE="$LOG_DIR/results.txt"
: > "$RESULTS_FILE"

record_result() {
    local name="$1" status="$2" seconds="$3" log="$4"
    printf '%s|%s|%s|%s\n' "$name" "$status" "$seconds" "$log" >> "$RESULTS_FILE"
}

# now_seconds — coarse-grained start/stop timer in plain seconds. We don't
# need subsecond accuracy because the slowest gate is ~5 min and the
# fastest is 1s — integer seconds is plenty of resolution and keeps the
# implementation portable across BSD/GNU date.
now_seconds() { date +%s; }

# Sentinel exit code: a gate function returns this when its environment
# can't satisfy the prereqs (e.g. missing sqlx-cli, no postgres). The gate
# is recorded as SKIP rather than FAIL so the operator knows the
# difference between "your code broke this" and "your machine can't run
# this" — both should produce visible output, but only one should fail
# the overall run.
SKIP_EXIT_CODE=100

# run_gate <name> <function...> — run a gate in the background, capture
# its stdout+stderr, record exit code + duration when it finishes.
# A zero exit recorded as PASS, $SKIP_EXIT_CODE as SKIP, anything else as
# FAIL.
run_gate() {
    local name="$1"; shift
    local start log
    start=$(now_seconds)
    log="$LOG_DIR/${name}.log"
    {
        local rc=0
        "$@" > "$log" 2>&1 || rc=$?
        local dur=$(( $(now_seconds) - start ))
        case "$rc" in
            0)                  record_result "$name" "PASS" "$dur" "$log" ;;
            "$SKIP_EXIT_CODE")  record_result "$name" "SKIP" "$dur" "$log" ;;
            *)                  record_result "$name" "FAIL" "$dur" "$log" ;;
        esac
    } &
}

skip_gate() {
    local name="$1" reason="$2"
    local log="$LOG_DIR/${name}.log"
    printf 'SKIPPED: %s\n' "$reason" > "$log"
    record_result "$name" "SKIP" "0" "$log"
}

# ---------------------------------------------------------------------------
# Gate implementations — each mirrors the corresponding CI job. Where the
# local form diverges from the CI form, the divergence is documented inline.
# ---------------------------------------------------------------------------

gate_check_sizes() {
    bash "$REPO_ROOT/scripts/check-sizes.sh"
}

node_modules_fresh_or_fail() {
    # CI runs `npm ci` before web-lint and web-test, so the install is
    # deterministic. Locally we trust the working tree's node_modules,
    # which means a stale install (package-lock.json updated but
    # `npm install` not re-run) silently passes locally and fails in CI.
    # This guard makes that drift visible. (Real bug found 2026-04-30.)
    local lock="$REPO_ROOT/web/package-lock.json"
    local installed="$REPO_ROOT/web/node_modules/.package-lock.json"
    if [ ! -d "$REPO_ROOT/web/node_modules" ]; then
        echo "ERROR: web/node_modules missing — run 'cd web && npm install' first" >&2
        return 1
    fi
    if [ ! -f "$installed" ]; then
        echo "ERROR: web/node_modules looks corrupt — run 'cd web && rm -rf node_modules && npm install'" >&2
        return 1
    fi
    if [ "$lock" -nt "$installed" ]; then
        echo "ERROR: web/package-lock.json is newer than installed node_modules — run 'cd web && npm install' first" >&2
        echo "       (CI runs 'npm ci' which would catch this; local-ci skips that step for speed.)" >&2
        return 1
    fi
}

gate_web_lint() {
    # Mirrors web-lint job: svelte-check, eslint, browser-unmocked lint,
    # screen spec coverage contract, SES IAM/configset coupling contract.
    set -e
    # Explicit `|| return` because bash 3.2 (macOS default) does not
    # reliably propagate `set -e` from a function called inside another
    # function. Verified locally — without this, a stale lockfile
    # printed the error and continued instead of aborting the gate.
    node_modules_fresh_or_fail || return $?
    cd "$REPO_ROOT/web" || return $?
    # `npm ci` is omitted intentionally — local devs already have
    # node_modules from `npm install`. CI does `npm ci` for a clean
    # install; the node_modules_fresh_or_fail check above catches the
    # stale-lockfile divergence that would otherwise pass locally and
    # fail in CI.
    #
    # Explicit `|| return $?` after every command — when this gate is
    # invoked from a `||`-chained dispatcher (e.g. `gate_web_lint || ...`),
    # bash 3.2 (macOS default) disables `set -e` inside the function, so
    # bare commands silently swallow non-zero exits. Without these guards,
    # a real svelte-check / eslint failure would log to the gate file but
    # report PASS — the failure mode that masked a TS bug + eslint regression
    # in the LB-9 fixture rewrite for ~24h on 2026-05-02.
    npm run check || return $?
    npx eslint . || return $?
    npm run lint:e2e || return $?
    cd "$REPO_ROOT" || return $?
    bash "$REPO_ROOT/scripts/tests/screen_specs_coverage_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/ses_iam_configset_coupling_test.sh" || return $?
}

gate_web_test() {
    set -e
    # Explicit `|| return $?` after every command — same bash 3.2 set -e
    # pitfall handled in gate_web_lint and gate_rust_lint. Without these
    # guards, a `cd` failure or non-final command failure would be
    # silently swallowed and the gate would report the last command's
    # status instead. Pinned by scripts/tests/local_ci_gate_set_e_test.sh
    # (currently rust-lint-scoped; extend if more gates need explicit
    # regression coverage post-launch).
    node_modules_fresh_or_fail || return $?
    cd "$REPO_ROOT/web" || return $?
    npm test || return $?
}

gate_rust_lint() {
    # Mirrors rust-lint: ci_workflow_test, generate_ssm_env_test,
    # local_ci_gate_set_e_test, support email unit seams, cargo fmt
    # --check, cargo clippy --workspace -- -D warnings.
    #
    # Explicit `|| return $?` after every command — same bash 3.2 set -e
    # pitfall already handled in gate_web_lint/gate_web_test. Without
    # this, `cargo fmt --check` could print its diff, exit non-zero, and
    # the gate would still record PASS because run_gate invokes the body
    # via `"$@" || rc=$?`, which silently disables `set -e` inside the
    # called function. Pinned by scripts/tests/local_ci_gate_set_e_test.sh.
    bash "$REPO_ROOT/scripts/tests/ci_workflow_test.sh" || return $?
    # On macOS bash 3.2, generate_ssm_env_test.sh reports SKIP because
    # generate_ssm_env.sh requires bash>=4 associative arrays. Treat that
    # sentinel as a sub-check skip and continue, so rust-lint still runs
    # fmt/clippy and remains aligned with CI contract coverage.
    local generate_ssm_env_rc=0
    bash "$REPO_ROOT/scripts/tests/generate_ssm_env_test.sh" || generate_ssm_env_rc=$?
    if [ "$generate_ssm_env_rc" -ne 0 ] && [ "$generate_ssm_env_rc" -ne "$SKIP_EXIT_CODE" ]; then
        return "$generate_ssm_env_rc"
    fi
    # local_ci_gate_set_e_test shells back into `scripts/local-ci.sh --gate
    # rust-lint` with an intentional rustfmt violation. Skip the nested
    # invocation's copy of this same regression test so the proof runs once
    # per top-level gate execution instead of recursing forever.
    if [ "${LOCAL_CI_SKIP_SET_E_REGRESSION_TEST:-0}" != "1" ]; then
        bash "$REPO_ROOT/scripts/tests/local_ci_gate_set_e_test.sh" || return $?
    fi
    bash "$REPO_ROOT/scripts/tests/validate_inbound_email_roundtrip_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/support_email_deliverability_test.sh" || return $?
    cd "$REPO_ROOT/infra" || return $?
    cargo fmt --check || return $?
    cargo clippy --workspace -- -D warnings || return $?
}

gate_migration_test() {
    # CI provisions postgres in a service container. Locally, require a
    # running postgres reachable via $DATABASE_URL or the docker compose
    # default. SKIP cleanly with remediation hint if a prereq is missing
    # — and report the SPECIFIC missing prereq, since "no postgres" and
    # "no pg_isready installed" are different problems with different
    # fixes. (Real bug found 2026-04-30 self-review: previous version
    # told users with no `pg_isready` to run docker-compose, even if
    # postgres was already running.)
    local db_url="${DATABASE_URL:-postgres://griddle:griddle_local@127.0.0.1:5432/fjcloud_test}"
    if ! command -v sqlx >/dev/null 2>&1; then
        echo "SKIPPED: sqlx-cli not installed (run: cargo install sqlx-cli --version 0.8.6 --no-default-features --features postgres)" >&2
        return "$SKIP_EXIT_CODE"
    fi
    # Probe postgres via bash's built-in /dev/tcp — works on any bash
    # without requiring postgresql-client (pg_isready) to be installed.
    # Parse host:port out of the DATABASE_URL or fall back to the CI
    # default. This means "missing tool" stops being conflated with
    # "postgres unreachable".
    local host port
    if [[ "$db_url" =~ @([^:/]+):([0-9]+)/ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    else
        host="127.0.0.1"
        port="5432"
    fi
    if ! (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; then
        echo "SKIPPED: no postgres reachable at ${host}:${port} (run: docker compose up -d postgres OR scripts/local-dev-up.sh)" >&2
        return "$SKIP_EXIT_CODE"
    fi
    exec 3<&- 3>&- 2>/dev/null || true
    # Ensure the target test database exists before running migrations so a
    # fresh local stack does not require manual DB bootstrap.
    sqlx database create --database-url "$db_url" || return $?
    sqlx migrate run --source "$REPO_ROOT/infra/migrations" --database-url "$db_url"
}

gate_secret_scan() {
    # KNOWN DIVERGENCE FROM CI: the staging job runs gitleaks; we run the
    # repo's reliability secret-scan. They have OVERLAPPING but not
    # identical rule sets, so a CI gitleaks failure can still happen even
    # after a green local-ci pass. Reasons we accept the divergence:
    #   1. gitleaks needs a separate install per dev (avoid).
    #   2. Our reliability scan is SSOT-aligned with the broader
    #      backend reliability gate
    #      (scripts/reliability/run_backend_reliability_gate.sh).
    #   3. The 2026-04-30 false-positive class (regex matching
    #      identifier chains) was actually fixed in our scan and not in
    #      gitleaks — running gitleaks locally would have produced a
    #      noisier signal.
    # If a CI gitleaks-only failure ever surfaces, document the rule
    # difference here and either tighten our scan or add an opt-in
    # `--gate gitleaks` mode. Don't silently widen our scan to match.
    set -e
    source "$REPO_ROOT/scripts/reliability/lib/security_checks.sh"
    check_secret_scan "$REPO_ROOT"
}

gate_rust_test() {
    # Mirrors rust-test: seed reliability profile artifacts, then run
    # `cargo test --workspace` + the tenant-isolation proptest. SLOW —
    # only run on --full or via --gate rust-test.
    #
    # The seed-test-profiles step is load-bearing: tests in
    # `infra/api/tests/` that compare current capacity_profiles.rs
    # constants against the profile-snapshot files under
    # scripts/reliability/profiles/ FAIL when the snapshots are absent.
    # CI runs this before `cargo test`; omitting it locally was a real
    # divergence from CI behavior caught in self-review.
    #
    # We deliberately do NOT pass `-j 1` like CI does; that flag is a
    # CI-runner RAM tradeoff (single test binary with AWS SDK deps is
    # 500 MB+ with debug info; CI's 7 GB RAM + 8 GB swap can't link
    # multiple in parallel) that doesn't apply on a workstation.
    # Explicit `|| return $?` after every command — same bash 3.2 set -e
    # pitfall already handled in gate_web_lint/gate_web_test. Pinned by
    # scripts/tests/local_ci_gate_set_e_test.sh.
    bash "$REPO_ROOT/scripts/reliability/seed-test-profiles.sh" || return $?
    cd "$REPO_ROOT/infra" || return $?
    cargo test --workspace || return $?
    # tenant_isolation_proptest moved out of CI rust-test to nightly.yml on
    # 2026-05-02 (defensive regression check, not a deploy gate). To keep
    # local-ci a faithful mirror of CI's deploy-staging needs[], we drop it
    # here too. Run it ad hoc when working in tenant-isolation surfaces:
    #   cd infra && cargo test -p api --test tenant_isolation_proptest --features proptest-tests
}

# ---------------------------------------------------------------------------
# Dispatch — launch all gates, wait, then print summary
# ---------------------------------------------------------------------------

declare -a SCHEDULED_GATES=()

schedule() {
    local name="$1"
    if [ -n "$SINGLE_GATE" ] && [ "$SINGLE_GATE" != "$name" ]; then
        return
    fi
    SCHEDULED_GATES+=("$name")
}

# In --fast mode, omit rust-test (the workspace test is slow and we trust
# `cargo check` + lint to catch most things). Use --full or
# `--gate rust-test` to run it.
#
# rust-test is scheduled SEPARATELY (not in this parallel batch) because
# `cargo test --workspace` saturates the CPU and starves vitest, which
# has tight 5s per-test timeouts. CI doesn't see this because each CI
# job runs on its own runner — locally, running them concurrently
# produced false-FAIL on web-test that CI wouldn't have seen. (Real
# bug found 2026-04-30 round-2 self-review.) See post-wait section
# below for the sequential rust-test invocation.
schedule check-sizes
schedule secret-scan
schedule web-lint
schedule web-test
schedule rust-lint
schedule migration-test

# Decide whether rust-test should run, and if so when. It must NOT run
# in the parallel batch above (CPU contention with web-test). It runs
# either as a single-gate invocation or after the parallel batch
# finishes in --full mode.
RUN_RUST_TEST_SEQUENTIAL=0
if [ "$SINGLE_GATE" = "rust-test" ]; then
    RUN_RUST_TEST_SEQUENTIAL=1
elif [ "$MODE" = "full" ] && [ -z "$SINGLE_GATE" ]; then
    RUN_RUST_TEST_SEQUENTIAL=1
fi

if [ "${#SCHEDULED_GATES[@]}" -eq 0 ] && [ "$RUN_RUST_TEST_SEQUENTIAL" -eq 0 ]; then
    if [ -n "$SINGLE_GATE" ]; then
        echo "ERROR: --gate '$SINGLE_GATE' did not match any known gate" >&2
        echo "Known gates: rust-test rust-lint migration-test web-test check-sizes web-lint secret-scan" >&2
        exit 2
    fi
    echo "ERROR: no gates scheduled" >&2
    exit 2
fi

start_all=$(now_seconds)

total_gates="${#SCHEDULED_GATES[@]}"
if [ "$RUN_RUST_TEST_SEQUENTIAL" -eq 1 ]; then
    total_gates=$((total_gates + 1))
fi

gate_label_list="${SCHEDULED_GATES[*]:-}"
if [ "$RUN_RUST_TEST_SEQUENTIAL" -eq 1 ]; then
    gate_label_list="${gate_label_list:+$gate_label_list } rust-test (sequential)"
fi
printf '%bRunning %d gate(s):%b %s\n' "$C_BLU" "$total_gates" "$C_RESET" "$gate_label_list"
printf '%bMode:%b %s\n\n' "$C_BLU" "$C_RESET" "$MODE"

if [ "${#SCHEDULED_GATES[@]}" -gt 0 ]; then
    for gate in "${SCHEDULED_GATES[@]}"; do
        case "$gate" in
            check-sizes)     run_gate check-sizes     gate_check_sizes ;;
            secret-scan)     run_gate secret-scan     gate_secret_scan ;;
            web-lint)        run_gate web-lint        gate_web_lint ;;
            web-test)        run_gate web-test        gate_web_test ;;
            rust-lint)       run_gate rust-lint       gate_rust_lint ;;
            migration-test)  run_gate migration-test  gate_migration_test ;;
        esac
    done
    # Wait for all backgrounded fast gates to finish before launching
    # the heavy sequential gate.
    wait
fi

# Run rust-test serially AFTER the parallel batch — see scheduling
# rationale comment above. We invoke run_gate the same way (so it
# captures stdout/stderr to the per-gate log) but immediately wait so
# nothing else competes.
if [ "$RUN_RUST_TEST_SEQUENTIAL" -eq 1 ]; then
    run_gate rust-test gate_rust_test
    wait
fi

elapsed=$(( $(now_seconds) - start_all ))

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
fail_count=0
skip_count=0
pass_count=0

# Sort results by gate name for stable output.
printf '\n%b=== local-ci summary (wall %ds) ===%b\n' "$C_BOLD" "$elapsed" "$C_RESET"
printf '%-18s  %-6s  %5s  %s\n' "GATE" "STATUS" "SECS" "LOG"
printf '%-18s  %-6s  %5s  %s\n' "----" "------" "----" "---"
while IFS='|' read -r name status seconds log; do
    case "$status" in
        PASS) pass_count=$((pass_count+1)); color="$C_GRN" ;;
        FAIL) fail_count=$((fail_count+1)); color="$C_RED" ;;
        SKIP) skip_count=$((skip_count+1)); color="$C_YEL" ;;
        *)    color="" ;;
    esac
    # Rewrite the log path to the post-EXIT persisted location so the
    # summary's path is still readable after the script exits and the
    # EXIT trap moves $LOG_DIR → $KEEP_LOG_DIR.
    persisted_log="${log/$LOG_DIR/$KEEP_LOG_DIR}"
    printf '%-18s  %b%-6s%b  %5s  %s\n' "$name" "$color" "$status" "$C_RESET" "$seconds" "$persisted_log"
done < <(sort "$RESULTS_FILE")

# Print SKIP reasons inline so the remediation hint is visible without
# the operator chasing a log file. (Logs persist at $KEEP_LOG_DIR until
# the next run; the path stays usable, but skip reasons are 1-liners
# and inlining them removes a step from the feedback loop.)
if [ "$skip_count" -gt 0 ]; then
    printf '\n%b=== SKIP reasons ===%b\n' "$C_BOLD" "$C_RESET"
    while IFS='|' read -r name status seconds log; do
        if [ "$status" = "SKIP" ]; then
            local_skip_msg="$(grep -m1 '^SKIPPED:' "$log" 2>/dev/null || true)"
            printf '%b%s%b: %s\n' "$C_YEL" "$name" "$C_RESET" "${local_skip_msg:-(see log)}"
        fi
    done < <(sort "$RESULTS_FILE")
fi

# Tail failed gate logs so the operator can act without opening files.
if [ "$fail_count" -gt 0 ]; then
    printf '\n%b=== FAIL tails ===%b\n' "$C_BOLD" "$C_RESET"
    while IFS='|' read -r name status seconds log; do
        if [ "$status" = "FAIL" ]; then
            printf '\n%b--- %s (%ss) ---%b\n' "$C_RED" "$name" "$seconds" "$C_RESET"
            tail -40 "$log"
        fi
    done < <(sort "$RESULTS_FILE")
fi

printf '\n%bTotals:%b pass=%d fail=%d skip=%d\n' "$C_BOLD" "$C_RESET" "$pass_count" "$fail_count" "$skip_count"

if [ "$fail_count" -gt 0 ]; then
    printf '%bResult: FAIL%b\n' "$C_RED" "$C_RESET"
    exit 1
fi

if [ "$skip_count" -gt 0 ]; then
    printf '%bResult: PASS (with %d skipped — see remediation hints in their logs)%b\n' "$C_YEL" "$skip_count" "$C_RESET"
    exit 0
fi

printf '%bResult: PASS%b\n' "$C_GRN" "$C_RESET"
exit 0
