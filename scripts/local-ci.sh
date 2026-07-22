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
#                    migration-test, web-test, check-sizes,
#                    source-pollution, mirror-sync-contract,
#                    deploy-currency-check-contract,
#                    wave3-phase-receipt, launch-closeout, debbie-dry-run,
#                    status-doc-consistency,
#                    roadmap-v2-shape, local-dev-runbook-currency,
#                    web-lint, secret-scan, evidence-secret-hygiene,
#                    index-export-clientside-contract,
#                    engine-exposure-probe-contract,
#                    package-manager-consistency,
#                    dirmap-merge-driver).
#   --summary-only   Print prod deploy drift info without running any gate.
#                    Exits 0 immediately. Useful for a quick drift check.
#   --with-contracts Also run the opt-in live contract probes (uses real
#                    external systems; may print SKIP remediation guidance
#                    when live prereqs are unavailable).
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
source "$REPO_ROOT/scripts/lib/contract_secret_env.sh"

MODE="fast"
SINGLE_GATE=""
SUMMARY_ONLY=0
WITH_CONTRACTS=0   # set by --with-contracts; runs per-lane contract probes
                   # against live systems (outside default fast/full gates)

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
        --with-contracts) WITH_CONTRACTS=1; shift ;;
        --summary-only) SUMMARY_ONLY=1; shift ;;
        --help|-h) usage 0 ;;
        *) echo "ERROR: unknown arg: $1" >&2; usage 2 ;;
    esac
done

render_prod_drift() {
    printf '\n## Prod deploy drift (informational — does not affect exit code)\n'
    local drift_output
    if drift_output=$(bash "$REPO_ROOT/scripts/launch/post_wave_a_sync_prod.sh" --check-only 2>&1); then
        printf '%s\n' "$drift_output"
    else
        printf '  drift probe failed: %s\n' "$drift_output"
    fi
}

# --summary-only: skip all gate execution, print drift info only.
# Short-circuits BEFORE the log-dir cleanup and trap so prior-run state is
# preserved and no gates are scheduled or executed.
if [ "$SUMMARY_ONLY" -eq 1 ]; then
    printf '=== local-ci summary (summary-only) ===\n'
    printf 'Known gates: rust-test rust-lint migration-test web-test check-sizes source-pollution stripe-checks mirror-sync-contract deploy-currency-check-contract rc-wrapper-contract ses-coverage-a1 wave3-phase-receipt launch-closeout debbie-dry-run status-doc-consistency roadmap-v2-shape web-lint secret-scan evidence-secret-hygiene index-export-clientside-contract validate-bootstrap-parser validate-bootstrap-env-local publish-scripts-buildx algolia-safety-probe-contract flapjack-ami-pointer-contract engine-exposure-probe-contract package-manager-consistency dirmap-merge-driver\n'
    render_prod_drift
    exit 0
fi

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
trap 'rm -rf "$KEEP_LOG_DIR" && mv "$LOG_DIR" "$KEEP_LOG_DIR" 2>/dev/null || true' EXIT

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

gate_script_exec_bits() {
    # Anchored 2026-05-31: scripts/api-dev.sh shipped at git mode 100644 for
    # weeks. Tests passed because they all invoke scripts via `bash $script`;
    # `local_demo.sh` invokes api-dev.sh via `env ... api-dev.sh` which DOES
    # need the exec bit and crashed at runtime instead. This gate asserts on
    # top-level scripts/*.sh git modes so the next mis-permissioned script
    # fails in CI, not in a user's local-demo run 5 days later.
    bash "$REPO_ROOT/scripts/tests/script_exec_bits_test.sh"
    bash "$REPO_ROOT/scripts/tests/local_play_test.sh"
}

gate_port_collision_diagnose() {
    # Anchored 2026-05-31: local_demo.sh hit "port 5173 unavailable" with
    # no information about who held the port. Holder turned out to be a
    # vite from a different worktree's batman session 5 days earlier; took
    # interactive lsof/ps debugging to identify. The check_port_available
    # helper in scripts/lib/health.sh now surfaces PID + cmd + cwd + start
    # time + a kill command on collision. This gate asserts that diagnostic
    # output stays present so the next port-conflict failure is
    # self-explanatory.
    bash "$REPO_ROOT/scripts/tests/port_collision_diagnose_test.sh"
}

gate_compose_project() {
    # Anchored 2026-05-31: docker compose defaults its project name to the
    # basename of the working directory. Two fjcloud worktrees at paths
    # ending in `/fjcloud_dev` both named their stack `fjcloud_dev` and
    # silently clobbered each other on `docker compose up`. The
    # resolve_compose_project_name helper derives a worktree-unique name;
    # this gate guards against regressions in the resolver AND that
    # local-dev-up.sh / local-dev-down.sh wire it correctly.
    bash "$REPO_ROOT/scripts/tests/compose_project_test.sh"
}

gate_mirror_sync_contract() {
    # Anchored 2026-07-07: both mirror-sync contract test files existed but
    # were registered NOWHERE (silent guards) — post_wave_a_sync_prod.sh had
    # shipped without its exec bit and the test that catches it never ran.
    # These pin the push wrapper's staging-only default and the staging-green
    # prod promotion gate (see docs/runbooks/git_push_with_sync.md).
    bash "$REPO_ROOT/scripts/tests/git_push_with_sync_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/post_wave_a_sync_prod_test.sh" || return $?
}

gate_deploy_currency_check_contract() {
    bash "$REPO_ROOT/scripts/tests/deploy_currency_check_test.sh" || return $?
}

gate_rc_wrapper_contract() {
    # Anchored 2026-07-11: the RC wrapper test family (scripts/tests/
    # invoke_rc_with_env*_test.sh) existed but was registered NOWHERE in
    # local-ci — silent guards, same class as the mirror-sync gate above.
    # jul11_pm_1 added credential/env preflight KATs (ambient AWS unset,
    # STS identity refusal, browser-env refusal) to this family; without
    # registration those KATs never run under CI and the credential
    # hardening can silently regress — the exact failure class the
    # jul11_pm batch exists to kill. All three are hermetic (mock STS,
    # no live creds) and run in ~7s combined.
    bash "$REPO_ROOT/scripts/tests/invoke_rc_with_env_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/invoke_rc_with_env_bootstrap_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/invoke_rc_with_env_preflight_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/full_backend_validation_tier1_registry_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/rc_step_env_scoping_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/staging_billing_rehearsal_reset_test.sh" || return $?
}

gate_ses_coverage_a1() {
    # §1 six-probe in-VPC coverage runner, deployable-currency seam, and
    # manifest integrity library (scripts/launch/run_ses_coverage_a1_in_vpc.sh,
    # scripts/lib/deployable_currency.sh, scripts/lib/
    # ses_coverage_a1_integrity.py). All three suites are hermetic: they use
    # PATH stubs or temp-dir fixtures and avoid live creds, network, and the
    # live six-row bundle.
    bash "$REPO_ROOT/scripts/tests/deployable_currency_test.sh" || return $?
    python3 "$REPO_ROOT/scripts/tests/ses_coverage_a1_integrity_test.py" || return $?
    bash "$REPO_ROOT/scripts/tests/run_ses_coverage_a1_in_vpc_test.sh" || return $?
}

gate_wave3_phase_receipt() {
    # Hermetic owner test for cleanup-safe Wave 3 phase receipts. The suite
    # builds temp lane roots and does not read live creds or touch the network.
    python3 "$REPO_ROOT/scripts/tests/wave3_phase_receipt_test.py"
}

gate_launch_closeout() {
    # Hermetic anti-drift KAT for the Wave 3 launch closeout owner. The suite
    # builds checkout-shaped fixtures in temp directories and uses no network
    # or credentials.
    python3 "$REPO_ROOT/scripts/tests/validate_launch_closeout_test.py"
}

gate_debbie_dry_run() {
    # Hermetic anti-drift KAT for Debbie's advertised staging dry-run scope.
    # The suite parses hand-authored fixtures and never invokes Debbie.
    python3 "$REPO_ROOT/scripts/tests/validate_debbie_dry_run_test.py"
}

gate_source_pollution() {
    # Postmortem: chats/suggestions/jun11_pm_fjcloud_dev__polished_beta_verify_chicken_egg_and_dirmap_guard_blindspot.md Suggestion 3
    bash "$REPO_ROOT/scripts/sanitize_worktree_paths.sh" --check || return $?
    bash "$REPO_ROOT/scripts/tests/local_ci_worktree_path_leak_guard_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/source_pollution_contract_test.sh" || return $?
}

gate_stripe_checks() {
    # Hermetic KATs for scripts/lib/stripe_checks.sh (mock curl/pgrep, no live
    # creds). Covers the Stripe launch-gate parsers, incl. check_stripe_account_status
    # which backs the docs/live-state stripe_account_status receipt.
    bash "$REPO_ROOT/scripts/tests/stripe_checks_test.sh" || return $?
}

gate_status_doc_consistency() {
    # Asserts doc-system v2 status ownership stays collapsed: LAUNCH.md owns
    # launch verdicts, ROADMAP.md owns open work, PROJECT_OVERVIEW.md owns
    # durable priority rationale, and retired mutable-owner docs stay absent.
    # Costs ~10ms; covered by scripts/tests/check_status_doc_consistency_test.sh.
    bash "$REPO_ROOT/scripts/check_status_doc_consistency.sh"
}

gate_dirmap_merge_driver() {
    # Asserts the DIRMAP anti-duplication mechanism is fully wired: the
    # committed `**/DIRMAP.md merge=ours` declaration in .gitattributes AND the
    # per-clone git-config registration of that driver. A clone with only the
    # declaration is worse than plain union merge — DIRMAP.md merges conflict.
    # Fix on failure: bash scripts/setup_git_merge_drivers.sh. Captured
    # 2026-07-19; covered by scripts/tests/check_dirmap_merge_driver_test.sh.
    bash "$REPO_ROOT/scripts/check_dirmap_merge_driver.sh"
}

gate_package_manager_consistency() {
    # Asserts web/ declares exactly one package manager and that it is npm:
    # package-lock.json present, no pnpm-lock.yaml/yarn.lock/bun.lockb, and any
    # packageManager field naming npm. Captured 2026-07-19 after web/ was found
    # tracking BOTH package-lock.json and pnpm-lock.yaml while CI only ever ran
    # `npm ci`. Costs ~5ms; covered by
    # scripts/tests/check_package_manager_consistency_test.sh.
    bash "$REPO_ROOT/scripts/check_package_manager_consistency.sh"
}

gate_roadmap_v2_shape() {
    # Asserts ROADMAP.md keeps the doc-system v2 owner shape after the
    # Stage 2 refactor: Active + Planned + Archive, preserved live item
    # titles, no retired mixed-shape headings, and <=200 lines.
    bash "$REPO_ROOT/scripts/check_roadmap_v2_shape.sh"
}

gate_validate_bootstrap_parser() {
    # Regression: extract_zone_name (sourced from ops/scripts/lib/parse_cloudflare_zone.sh)
    # must extract .result.name, not .result.plan.name. Captured 2026-05-14 in
    # prod-env-provision lane post-mortem (bug 4).
    bash "$REPO_ROOT/ops/scripts/tests/validate_bootstrap_zone_parser_test.sh"
}

gate_validate_bootstrap_env_local() {
    # Regression coverage for scripts/bootstrap-env-local.sh — including the
    # LOCAL_ENV_DENY_LIST that prevents environment-targeting keys (API_URL,
    # ADMIN_KEY, DATABASE_URL) from leaking from .secret/.env.secret into a
    # local .env.local. The pre-deny-list behavior caused local_demo.sh to
    # silently seed prod + live Stripe (2026-05-22 incident). Decision +
    # damage record: decisions/2026-05-22_bootstrap_local_env_deny_list.md.
    bash "$REPO_ROOT/scripts/tests/bootstrap_env_local_test.sh"
}

gate_publish_scripts_buildx() {
    # Regression: Lambda canary publish scripts must use docker buildx with
    # --provenance=false (schema-2 manifest), not plain docker build (OCI
    # manifest Lambda rejects). Captured 2026-05-14 in prod-env-provision
    # lane post-mortem (bug 5).
    bash "$REPO_ROOT/ops/terraform/tests_publish_scripts_buildx_static.sh"
}

gate_index_export_clientside_contract() {
    # Keep the canonical Overview export browser-path probe script honest
    # without requiring a live Playwright/browser run on every local-ci
    # invocation. This hermetic contract test stubs `npx playwright`,
    # executes the probe owner, and asserts the run dir preserves exactly
    # one machine-readable verdict artifact (`summary.json`).
    bash "$REPO_ROOT/scripts/canary/contracts/index_export_browser_path_probe_contract_test.sh"
}

node_modules_fresh_or_fail() {
    # CI runs a clean package install before web-lint and web-test, so the
    # install is deterministic. Locally we trust the working tree's
    # node_modules, which means a stale install (package-lock.json updated
    # but dependencies not re-installed) silently passes locally and fails in
    # CI. This guard makes that drift visible. (Real bug found 2026-04-30.)
    #
    # npm-only as of 2026-07-19. This function previously accepted EITHER
    # npm's .package-lock.json or pnpm's .modules.yaml as proof of install,
    # while its error messages told developers to run `pnpm install` — even
    # though CI only ever runs `npm ci`. That let a pnpm-installed node_modules
    # satisfy a gate protecting an npm-installed CI, and the working tree
    # ended up carrying both markers at once. Accepting only npm's marker is
    # what makes pnpm residue visible: a pnpm-installed tree has no
    # .package-lock.json, so it now correctly reports "run npm ci".
    # The single-lockfile invariant itself is owned by
    # scripts/check_package_manager_consistency.sh (gate_package_manager_consistency).
    local lock="$REPO_ROOT/web/package-lock.json"
    local installed="$REPO_ROOT/web/node_modules/.package-lock.json"
    if [ ! -d "$REPO_ROOT/web/node_modules" ]; then
        echo "ERROR: web/node_modules missing — run 'cd web && npm ci' first" >&2
        return 1
    fi
    if [ ! -f "$installed" ]; then
        echo "ERROR: web/node_modules has no npm install marker (.package-lock.json)." >&2
        echo "       It is missing or was installed by another package manager." >&2
        echo "       Run 'cd web && rm -rf node_modules && npm ci'" >&2
        return 1
    fi
    if [ "$lock" -nt "$installed" ]; then
        echo "ERROR: web/package-lock.json is newer than installed node_modules — run 'cd web && npm ci' first" >&2
        echo "       (CI runs a clean install which would catch this; local-ci skips that step for speed.)" >&2
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
    # Hermetic (curl-stubbed) unit test for the OAuth contract probe's
    # self-test isolation. No network/secrets needed, unlike the live
    # oauth_redirect_uri_contract.sh run gated behind --with-contracts.
    bash "$REPO_ROOT/scripts/canary/contracts/oauth_redirect_uri_contract_test.sh" || return $?
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

should_skip_env_local_isolation_for_set_e_regression() {
    local fixture_path="${LOCAL_CI_SET_E_REGRESSION_FIXTURE:-}"

    if [ "${LOCAL_CI_SKIP_SET_E_REGRESSION_TEST:-0}" != "1" ]; then
        return 1
    fi
    case "$fixture_path" in
        "$REPO_ROOT"/infra/api/tests/_local_ci_set_e_regression_fixture.*.rs)
            ;;
        *)
            return 1
            ;;
    esac
    [ -f "$fixture_path" ]
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
    bash "$REPO_ROOT/scripts/tests/ci_stripe_local_mode_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/playwright_local_stack_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/local_stack_contract_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/e2e_preflight_test.sh" || return $?
    if ! should_skip_env_local_isolation_for_set_e_regression; then
        bash "$REPO_ROOT/scripts/tests/local_ci_env_local_isolation_test.sh" || return $?
    fi
    bash "$REPO_ROOT/scripts/tests/ci_e2e_deployed_pages_parity_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/ci_deploy_web_contract_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/ci_lane24_deploy_contract_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/e2e_deployed_pages_parity_probe_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/integration_test_layout_test.sh" || return $?
    # generate_ssm_env_test.sh is treated as a sub-check: non-zero exits fail
    # rust-lint except the shared SKIP sentinel code. Keeping this branch lets
    # the gate continue through fmt/clippy when the test explicitly reports a
    # prereq skip on a given host.
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
    bash "$REPO_ROOT/scripts/tests/local_ci_node_modules_guard_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/local_ci_migration_isolated_db_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/local_ci_parallel_safety_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/validate_inbound_email_roundtrip_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/support_email_deliverability_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/customer_loop_synthetic_probe_env_gap_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/customer_metrics_authenticated_probe_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/customer_metrics_endpoint_authenticated_probe_env_gap_test.sh" || return $?
    # aws_identity is the SSOT for the credential-pollution triage that the inbox
    # prereq / canary / RC skip-classification depends on; test_inbox_helpers
    # guards that integration (the 2026-07-08 false-env-gap-skip regression).
    bash "$REPO_ROOT/scripts/tests/aws_identity_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/test_inbox_helpers_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/probe_stage2_email_coverage_test.sh" || return $?
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
    # Run migrations in an isolated throwaway database so local drift in an
    # existing test DB (for example "migration X was modified") cannot
    # false-fail this gate. CI always runs against a fresh DB container.
    local db_url_without_query db_url_query db_url_prefix migration_test_db_name migration_db_url
    db_url_without_query="${db_url%%\?*}"
    db_url_query=""
    if [[ "$db_url" == *\?* ]]; then
        db_url_query="?${db_url#*\?}"
    fi
    db_url_prefix="${db_url_without_query%/*}"
    if [[ "$db_url_prefix" == "$db_url_without_query" ]]; then
        echo "ERROR: could not parse database name from DATABASE_URL: $db_url" >&2
        return 1
    fi
    migration_test_db_name="fjcloud_migration_test_${RANDOM}_$$"
    migration_db_url="${db_url_prefix}/${migration_test_db_name}${db_url_query}"

    sqlx database drop --database-url "$migration_db_url" -y >/dev/null 2>&1 || true
    sqlx database create --database-url "$migration_db_url" || return $?
    if ! sqlx migrate run --source "$REPO_ROOT/infra/migrations" --database-url "$migration_db_url"; then
        sqlx database drop --database-url "$migration_db_url" -y >/dev/null 2>&1 || true
        return 1
    fi
    sqlx database drop --database-url "$migration_db_url" -y
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

gate_evidence_secret_hygiene() {
    bash "$REPO_ROOT/scripts/tests/redact_playwright_json_test.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/check_evidence_secret_hygiene_test.sh" || return $?
    bash "$REPO_ROOT/scripts/check_evidence_secret_hygiene.sh" || return $?
}

gate_algolia_safety_probe_contract() {
    bash "$REPO_ROOT/scripts/tests/algolia_migration_safety_probe_test.sh" || return $?
}

gate_engine_exposure_probe_contract() {
    # Hermetic known-answer classifier suite; fixture mode forbids live network commands.
    bash "$REPO_ROOT/scripts/security/tests_probe_engine_exposure.sh" || return $?
}

gate_flapjack_ami_pointer_contract() {
    bash "$REPO_ROOT/ops/terraform/tests_flapjack_ami_pointer_static.sh" || return $?
    bash "$REPO_ROOT/ops/terraform/tests_flapjack_ami_pointer_plan.sh" || return $?
    bash "$REPO_ROOT/scripts/tests/set_flapjack_ami_pointer_test.sh" || return $?
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
    #   cd infra && cargo test -p api --test platform --features proptest-tests tenant_isolation_proptest::
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
# web-test and rust-test are scheduled SEPARATELY (not in this parallel
# batch) because CPU-heavy Rust gates can starve vitest, which has tight
# 5s per-test timeouts. CI doesn't see this because each CI job runs on
# its own runner — locally, running CPU-heavy gates concurrently produced
# false-FAIL on web-test that CI wouldn't have seen. See the post-wait
# section below for the sequential invocations.
schedule check-sizes
schedule script-exec-bits
schedule port-collision-diagnose
schedule compose-project
schedule mirror-sync-contract
schedule deploy-currency-check-contract
schedule rc-wrapper-contract
schedule ses-coverage-a1
schedule wave3-phase-receipt
schedule launch-closeout
schedule debbie-dry-run
schedule source-pollution
schedule stripe-checks
schedule status-doc-consistency
schedule roadmap-v2-shape
schedule package-manager-consistency
schedule dirmap-merge-driver
schedule secret-scan
schedule evidence-secret-hygiene
schedule web-lint
schedule index-export-clientside-contract
schedule rust-lint
schedule migration-test
schedule validate-bootstrap-parser
schedule publish-scripts-buildx
schedule algolia-safety-probe-contract
schedule flapjack-ami-pointer-contract
schedule engine-exposure-probe-contract

# Keep the bootstrap env-local test in the existing sequential lane until the
# Stage 3 parallel-safety cleanup retires this scheduling workaround. The test
# itself is fixture-isolated; only the local-ci sequencing contract is retained.
RUN_BOOTSTRAP_ENV_LOCAL_SEQUENTIAL=0
if [ -z "$SINGLE_GATE" ] || [ "$SINGLE_GATE" = "validate-bootstrap-env-local" ]; then
    RUN_BOOTSTRAP_ENV_LOCAL_SEQUENTIAL=1
fi

# Run web-test after the parallel batch so local CPU contention cannot turn
# Vitest's tight per-test timeout into a false deploy-gate failure.
RUN_WEB_TEST_SEQUENTIAL=0
if [ -z "$SINGLE_GATE" ] || [ "$SINGLE_GATE" = "web-test" ]; then
    RUN_WEB_TEST_SEQUENTIAL=1
fi

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

if [ "${#SCHEDULED_GATES[@]}" -eq 0 ] \
    && [ "$RUN_BOOTSTRAP_ENV_LOCAL_SEQUENTIAL" -eq 0 ] \
    && [ "$RUN_WEB_TEST_SEQUENTIAL" -eq 0 ] \
    && [ "$RUN_RUST_TEST_SEQUENTIAL" -eq 0 ]; then
    if [ -n "$SINGLE_GATE" ]; then
        echo "ERROR: --gate '$SINGLE_GATE' did not match any known gate" >&2
        echo "Known gates: rust-test rust-lint migration-test web-test check-sizes source-pollution stripe-checks mirror-sync-contract deploy-currency-check-contract rc-wrapper-contract ses-coverage-a1 wave3-phase-receipt launch-closeout debbie-dry-run status-doc-consistency roadmap-v2-shape web-lint secret-scan evidence-secret-hygiene index-export-clientside-contract validate-bootstrap-parser validate-bootstrap-env-local publish-scripts-buildx algolia-safety-probe-contract flapjack-ami-pointer-contract engine-exposure-probe-contract package-manager-consistency dirmap-merge-driver" >&2
        exit 2
    fi
    echo "ERROR: no gates scheduled" >&2
    exit 2
fi

start_all=$(now_seconds)

total_gates="${#SCHEDULED_GATES[@]}"
if [ "$RUN_BOOTSTRAP_ENV_LOCAL_SEQUENTIAL" -eq 1 ]; then
    total_gates=$((total_gates + 1))
fi
if [ "$RUN_WEB_TEST_SEQUENTIAL" -eq 1 ]; then
    total_gates=$((total_gates + 1))
fi
if [ "$RUN_RUST_TEST_SEQUENTIAL" -eq 1 ]; then
    total_gates=$((total_gates + 1))
fi

gate_label_list="${SCHEDULED_GATES[*]:-}"
if [ "$RUN_BOOTSTRAP_ENV_LOCAL_SEQUENTIAL" -eq 1 ]; then
    gate_label_list="${gate_label_list:+$gate_label_list }validate-bootstrap-env-local (sequential)"
fi
if [ "$RUN_WEB_TEST_SEQUENTIAL" -eq 1 ]; then
    gate_label_list="${gate_label_list:+$gate_label_list }web-test (sequential)"
fi
if [ "$RUN_RUST_TEST_SEQUENTIAL" -eq 1 ]; then
    gate_label_list="${gate_label_list:+$gate_label_list } rust-test (sequential)"
fi
printf '%bRunning %d gate(s):%b %s\n' "$C_BLU" "$total_gates" "$C_RESET" "$gate_label_list"
printf '%bMode:%b %s\n\n' "$C_BLU" "$C_RESET" "$MODE"

if [ "${#SCHEDULED_GATES[@]}" -gt 0 ]; then
    for gate in "${SCHEDULED_GATES[@]}"; do
        case "$gate" in
            check-sizes)     run_gate check-sizes     gate_check_sizes ;;
            script-exec-bits) run_gate script-exec-bits gate_script_exec_bits ;;
            port-collision-diagnose) run_gate port-collision-diagnose gate_port_collision_diagnose ;;
            compose-project) run_gate compose-project gate_compose_project ;;
            mirror-sync-contract) run_gate mirror-sync-contract gate_mirror_sync_contract ;;
            deploy-currency-check-contract) run_gate deploy-currency-check-contract gate_deploy_currency_check_contract ;;
            rc-wrapper-contract) run_gate rc-wrapper-contract gate_rc_wrapper_contract ;;
            ses-coverage-a1) run_gate ses-coverage-a1 gate_ses_coverage_a1 ;;
            wave3-phase-receipt) run_gate wave3-phase-receipt gate_wave3_phase_receipt ;;
            launch-closeout) run_gate launch-closeout gate_launch_closeout ;;
            debbie-dry-run) run_gate debbie-dry-run gate_debbie_dry_run ;;
            source-pollution) run_gate source-pollution gate_source_pollution ;;
            stripe-checks)   run_gate stripe-checks   gate_stripe_checks ;;
            status-doc-consistency) run_gate status-doc-consistency gate_status_doc_consistency ;;
            roadmap-v2-shape) run_gate roadmap-v2-shape gate_roadmap_v2_shape ;;
            package-manager-consistency) run_gate package-manager-consistency gate_package_manager_consistency ;;
            dirmap-merge-driver) run_gate dirmap-merge-driver gate_dirmap_merge_driver ;;
            secret-scan)     run_gate secret-scan     gate_secret_scan ;;
            evidence-secret-hygiene) run_gate evidence-secret-hygiene gate_evidence_secret_hygiene ;;
            web-lint)        run_gate web-lint        gate_web_lint ;;
            index-export-clientside-contract) run_gate index-export-clientside-contract gate_index_export_clientside_contract ;;
            rust-lint)       run_gate rust-lint       gate_rust_lint ;;
            migration-test)  run_gate migration-test  gate_migration_test ;;
            validate-bootstrap-parser) run_gate validate-bootstrap-parser gate_validate_bootstrap_parser ;;
            publish-scripts-buildx) run_gate publish-scripts-buildx gate_publish_scripts_buildx ;;
            algolia-safety-probe-contract) run_gate algolia-safety-probe-contract gate_algolia_safety_probe_contract ;;
            flapjack-ami-pointer-contract) run_gate flapjack-ami-pointer-contract gate_flapjack_ami_pointer_contract ;;
            engine-exposure-probe-contract) run_gate engine-exposure-probe-contract gate_engine_exposure_probe_contract ;;
        esac
    done
    # Wait for all backgrounded fast gates to finish before launching
    # the heavy sequential gate.
    wait
fi

# Run web-test after the parallel batch so Vitest does not compete with
# cargo/clippy and other CPU-heavy local-only checks.
if [ "$RUN_WEB_TEST_SEQUENTIAL" -eq 1 ]; then
    run_gate web-test gate_web_test
    wait
fi

# Run the repository-state-mutating bootstrap gate only after every parallel
# gate has released .env.local.
if [ "$RUN_BOOTSTRAP_ENV_LOCAL_SEQUENTIAL" -eq 1 ]; then
    run_gate validate-bootstrap-env-local gate_validate_bootstrap_env_local
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

# ---------------------------------------------------------------------------
# --with-contracts: per-lane contract probes against live external systems
# ---------------------------------------------------------------------------
# Opt-in because the probes (a) hit live Google/GitHub/AWS/Cloudflare APIs
# and (b) require .env.secret to be present. CI may run with --with-contracts
# on a job that has the secrets mounted; dev iteration normally runs without.
# Default to the primary repo's secret file under the operator home directory.
# .env.secret is .gitignored, so worktrees do NOT contain a copy; using
# $REPO_ROOT would resolve to the worktree path and fail to find the file.
# Operators running from a different primary repo override via FJCLOUD_SECRET_FILE.
if [ "$WITH_CONTRACTS" -eq 1 ]; then
    SECRET_FILE="${FJCLOUD_SECRET_FILE:-${HOME:-}/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret}"
    CONTRACT_SECRET_ENV_READY=0
    if [ -f "$SECRET_FILE" ]; then
        if load_contract_secret_env "$SECRET_FILE"; then
            CONTRACT_SECRET_ENV_READY=1
            printf '\n%b==contracts: oauth_redirect_uri ==%b\n' "$C_BOLD" "$C_RESET"
            if bash scripts/canary/contracts/oauth_redirect_uri_contract.sh all; then
                pass_count=$((pass_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
        else
            printf '\n%b==contracts: oauth_redirect_uri ==%b\n' "$C_BOLD" "$C_RESET"
            echo "ERROR: refused to execute malformed secret file $SECRET_FILE" >&2
            fail_count=$((fail_count + 1))
        fi
    else
        printf '\nSKIP: --with-contracts requested but %s missing\n' "$SECRET_FILE"
        skip_count=$((skip_count + 1))
    fi
    # web_api_base_url_contract.sh needs no secrets -- runs outside the
    # SECRET_FILE conditional so it executes even when .env.secret is absent
    # (e.g. on a worktree). Detects Cloudflare Pages API_BASE_URL drift
    # between staging and prod Functions env.
    printf '\n%b==contracts: web_api_base_url ==%b\n' "$C_BOLD" "$C_RESET"
    if bash scripts/canary/contracts/web_api_base_url_contract.sh all; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
    # Server-load contract: HTML-only API-URL probe above does not catch
    # createApiClient() routing bugs — those only manifest from server-side
    # load functions. This probe mints a throwaway staging customer and
    # asserts /console/billing's load reaches the correct API instead of
    # bouncing to session_expired.
    printf '\n%b==contracts: web_server_load_api_url ==%b\n' "$C_BOLD" "$C_RESET"
    if bash scripts/canary/contracts/web_server_load_api_url_contract.sh staging; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
    if [ "$CONTRACT_SECRET_ENV_READY" -eq 1 ]; then
        printf '\n%b==contracts: web_form_login ==%b\n' "$C_BOLD" "$C_RESET"
        if bash scripts/canary/contracts/web_form_login_contract.sh all; then
            pass_count=$((pass_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    else
        printf '\nSKIP: contracts secret env unavailable; skipping web_form_login\n'
        skip_count=$((skip_count + 1))
    fi
    if [ "$CONTRACT_SECRET_ENV_READY" -eq 1 ]; then
        metrics_probe_rc=0
        printf '\n%b==contracts: customer_metrics_authenticated_probe ==%b\n' "$C_BOLD" "$C_RESET"
        if API_URL="https://api.staging.flapjack.foo" \
            WEB_BASE_URL="https://cloud.staging.flapjack.foo" \
            bash scripts/canary/contracts/customer_metrics_endpoint_authenticated_probe.sh --staging-only; then
            pass_count=$((pass_count + 1))
        else
            metrics_probe_rc=$?
            if [ "$metrics_probe_rc" -eq "$SKIP_EXIT_CODE" ]; then
                printf '\nSKIP: customer-metrics-authenticated-probe prerequisites unavailable\n'
                skip_count=$((skip_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
        fi
    else
        printf '\nSKIP: contracts secret env unavailable; skipping customer-metrics-authenticated-probe\n'
        skip_count=$((skip_count + 1))
    fi
    # Mocked-spec drift contract: keep chromium:mocked route.fulfill payload
    # shape keys and the upgrade fixture seam aligned with live staging
    # action/page-load payloads and source-owned fail(...) field names.
    printf '\n%b==contracts: mocked_spec ==%b\n' "$C_BOLD" "$C_RESET"
    if bash scripts/canary/contracts/mocked_spec_contract.sh staging; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
    printf '\n%b==contracts: admin_cleanup_live ==%b\n' "$C_BOLD" "$C_RESET"
    if bash scripts/canary/contracts/customer_loop_admin_cleanup_live_contract.sh; then
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
fi

render_prod_drift

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
