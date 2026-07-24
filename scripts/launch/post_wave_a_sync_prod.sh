#!/usr/bin/env bash
# post_wave_a_sync_prod.sh — Wrap the dev→prod debbie sync + CI wait +
# deploy-verify dance into a single invocation.
#
# Usage:
#   bash scripts/launch/post_wave_a_sync_prod.sh --check-only
#   bash scripts/launch/post_wave_a_sync_prod.sh --execute [--yes] \
#       --expected-dev-sha <40hex> --expected-staging-pages-sha <40hex> \
#       --receipt <absolute-new-json>
#   bash scripts/launch/post_wave_a_sync_prod.sh --help
#
# Modes:
#   --check-only  Read-only drift check: probes prod /version via
#                 deploy_status.sh --json and prints the prod drift
#                 envelope (dev_sha, build_time age, commits_behind_main).
#                 No mutations — safe to call from local-ci.sh.
#
#   --execute     Promote current dev main to prod: verify the staging
#                 mirror has validated exactly this content (staging was
#                 synced from the current dev HEAD SHA per debbie's sync
#                 manifest, AND staging CI is green at the staging mirror
#                 HEAD — including the post-deploy e2e-deployed job prod CI
#                 does not run), then run debbie sync prod, poll mirror CI
#                 until green or timeout, and verify the deploy landed via
#                 the post_wave_sync_to_prod_verify_test. Requires explicit
#                 confirmation: set POST_WAVE_CONFIRM=1 or pass --yes.
#
#                 Also REQUIRES caller-supplied EXACT identities — never
#                 ambient/discovered — plus a fresh receipt path:
#                   --expected-dev-sha <40hex>            dev HEAD being shipped
#                                                         (must equal git HEAD).
#                   --expected-staging-pages-sha <40hex>  staging-owned Cloudflare
#                                                         Pages commit (deploy-
#                                                         staging is sole Pages
#                                                         deployer; must NOT be
#                                                         the prod mirror head).
#                   --receipt <absolute-new-json>         where to write the
#                                                         secret-safe promotion
#                                                         receipt; must not exist.
#
#   --help        Print this usage and exit 0.
#
# Environment:
#   POST_WAVE_CONFIRM   Set to 1 to allow --execute without --yes flag.
#   POST_WAVE_STAGING_MIRROR_REMOTE  Staging mirror git remote used to
#                                    resolve staging HEAD for the promotion
#                                    gate.
#   POST_WAVE_STAGING_MIRROR_HEAD_SHA  Test override for the staging mirror
#                                      HEAD SHA.
#   POST_WAVE_STAGING_GATE_SCRIPT  Test seam replacing the staging-green
#                                  gate command. NOT an operator bypass —
#                                  for an emergency promotion with staging
#                                  red, run `debbie sync prod` directly so
#                                  the bypass stays loud and manual.
#   POST_WAVE_DEPLOY_STATUS_SCRIPT   Override the deploy-status owner path
#                                     (default: scripts/deploy_status.sh).
#   POST_WAVE_VERIFY_SCRIPT   Override the terminal verify script
#                              (default: scripts/tests/post_wave_sync_to_prod_verify_test.sh).
#   CI_POLL_TIMEOUT_SEC   Max seconds to poll mirror CI (default: 1800).
#   CI_POLL_RUN_LIMIT     Number of recent CI runs to search for the
#                         matching headSha (default: 20).
#   POST_WAVE_PROD_MIRROR_REMOTE  Prod mirror git remote used to resolve the
#                                 post-sync GitHub Actions head SHA.
#   POST_WAVE_PROD_MIRROR_HEAD_SHA  Test override for the post-sync mirror SHA.
#   POST_WAVE_PROD_MIRROR_MANIFEST_DEV_SHA  Test override for the dev_sha the
#                                 prod mirror sync manifest records (default:
#                                 read via gh api from the prod mirror).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/debbie_cli.sh"

usage() {
    sed -n '2,/^[^#]/{ /^#/s/^# \{0,1\}//p; }' "$0"
    exit 0
}

check_only() {
    local deploy_status_script="${POST_WAVE_DEPLOY_STATUS_SCRIPT:-$REPO_ROOT/scripts/deploy_status.sh}"
    local deploy_json
    if ! deploy_json=$(bash "$deploy_status_script" --json --env prod 2>&1); then
        echo "ERROR: deploy_status.sh --json --env prod failed: $deploy_json" >&2
        return 1
    fi

    local prod_dev_sha prod_build_time prod_commits_behind dev_main_sha
    prod_dev_sha=$(echo "$deploy_json" | jq -r '.envs.prod.dev_sha')
    prod_build_time=$(echo "$deploy_json" | jq -r '.envs.prod.build_time')
    prod_commits_behind=$(echo "$deploy_json" | jq -r '.envs.prod.commits_behind_main')
    dev_main_sha=$(echo "$deploy_json" | jq -r '.dev_main_sha')

    # c734c: the stale-signal owner used to be raw `commits_behind_main`, which
    # floats ahead on non-deployable commits (`chats/**`, `matt:`/`wip:`
    # bookkeeping, `DIRMAP.md`). That false "behind" signal made batman c734c
    # skip a whole staging billing rehearsal it should have run
    # (`chats/icg/jul10_pm_4_deployable_service_currency_diff.md`). The classifier
    # in scripts/lib/deployable_currency.sh now separates deployable drift from a
    # doc-only lead, so this consumer treats a doc-only-ahead prod as converged
    # rather than behind. `commits_behind_main` is still printed as a secondary
    # signal. `// empty` keeps legacy JSON (no booleans) from crashing -> unknown.
    local deployable_drift doc_only_ahead currency_status
    deployable_drift=$(echo "$deploy_json" | jq -r '.envs.prod.deployable_drift // empty')
    doc_only_ahead=$(echo "$deploy_json" | jq -r '.envs.prod.doc_only_ahead // empty')
    if [ -z "$deployable_drift" ] || [ -z "$doc_only_ahead" ] || \
       [ "$deployable_drift" = "unknown" ] || [ "$doc_only_ahead" = "unknown" ]; then
        currency_status="unknown"
    elif [ "$deployable_drift" = "true" ]; then
        currency_status="behind"
    elif [ "$doc_only_ahead" = "true" ]; then
        currency_status="converged (doc-only ahead)"
    else
        currency_status="current"
    fi

    local age_display="unknown"
    if [ "$prod_build_time" != "unknown" ] && [ "$prod_build_time" != "null" ]; then
        local now_epoch build_epoch age_seconds
        now_epoch=$(date +%s)
        if [[ "$OSTYPE" == darwin* ]]; then
            build_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$prod_build_time" +%s 2>/dev/null || echo 0)
        else
            build_epoch=$(date -d "$prod_build_time" +%s 2>/dev/null || echo 0)
        fi
        if [ "$build_epoch" -gt 0 ]; then
            age_seconds=$((now_epoch - build_epoch))
            local hours=$((age_seconds / 3600))
            local mins=$(( (age_seconds % 3600) / 60 ))
            age_display="${hours}h ${mins}m ago"
        fi
    fi

    printf 'Prod deploy drift:\n'
    printf '  dev_sha:            %s\n' "$prod_dev_sha"
    printf '  build_time:         %s (%s)\n' "$prod_build_time" "$age_display"
    printf '  commits_behind:     %s\n' "$prod_commits_behind"
    printf '  deployable_drift:   %s (%s)\n' "${deployable_drift:-unknown}" "$currency_status"
    printf '  doc_only_ahead:     %s\n' "${doc_only_ahead:-unknown}"
    printf '  dev_main_sha:       %s\n' "${dev_main_sha:0:12}"
}

resolve_prod_mirror_head_sha() {
    if [ -n "${POST_WAVE_PROD_MIRROR_HEAD_SHA:-}" ]; then
        printf '%s\n' "$POST_WAVE_PROD_MIRROR_HEAD_SHA"
        return 0
    fi

    local mirror_remote="${POST_WAVE_PROD_MIRROR_REMOTE:-git@github.com:gridl-infra-prod/fjcloud.git}"
    local ls_remote_output
    if ! ls_remote_output="$(git ls-remote "$mirror_remote" refs/heads/main 2>/dev/null)"; then
        return 1
    fi
    printf '%s\n' "$ls_remote_output" | awk 'NR == 1 {print $1}'
}

# Staging-green promotion gate: prod may only receive what staging has already
# validated. Two checks, both hard:
#   1. The staging mirror's CI run at its HEAD is completed/success. One run
#      conclusion covers every job — including deploy-staging and the
#      post-deploy e2e-deployed verification that prod CI does not run.
#   2. The staging HEAD commit is at-or-after the dev HEAD commit being
#      shipped. debbie sync prod ships the dev tree, not the staging tree —
#      without this check a green-but-stale staging would wave through
#      content it never validated.
# There is deliberately NO bypass flag: bypass flags are how gates rot. For a
# genuine emergency, run `debbie sync prod` directly — loud and manual.
staging_green_gate() {
    local staging_repo="gridl-infra-staging/fjcloud"

    # (1) Identity — EXACT, via debbie's own provenance manifest. debbie writes
    # .debbie/sync_manifest.json on every sync (unconditionally, last step),
    # recording the dev-repo HEAD SHA that produced the current mirror state.
    # Its docstring names it "the cross-repo mapping artifact ... contracts
    # used by deploy/provenance gates" — this gate is exactly that. If staging
    # was synced from a different dev SHA than we're about to promote, staging
    # has not validated this content. Read raw (no base64) for portability;
    # empty on any failure -> fail loud below.
    local synced_dev_sha dev_head_sha
    synced_dev_sha=$(gh api "repos/$staging_repo/contents/.debbie/sync_manifest.json" \
        -H "Accept: application/vnd.github.raw" 2>/dev/null | jq -r '.dev_sha // empty' 2>/dev/null || true)
    if [ -z "$synced_dev_sha" ]; then
        echo "ERROR: staging gate: could not read staging sync manifest (.debbie/sync_manifest.json)." >&2
        return 1
    fi
    dev_head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    if [ "$synced_dev_sha" != "$dev_head_sha" ]; then
        echo "ERROR: staging gate: staging mirrors dev ${synced_dev_sha:0:12}, but this promotion would ship dev HEAD ${dev_head_sha:0:12}." >&2
        echo "       Staging has not validated current dev main. Run 'debbie sync staging', wait for staging CI green, then retry." >&2
        return 1
    fi

    # (2) CI verdict at staging mirror HEAD. One run conclusion covers every
    # job — including the post-deploy e2e-deployed job prod CI does not run.
    # status AND conclusion are both checked so in_progress runs block too.
    # (The mirror commit SHA differs from the dev SHA above because debbie
    # strips files; GitHub Actions keys CI on the mirror SHA, so we resolve it
    # separately for the run lookup.)
    local staging_sha
    if [ -n "${POST_WAVE_STAGING_MIRROR_HEAD_SHA:-}" ]; then
        staging_sha="$POST_WAVE_STAGING_MIRROR_HEAD_SHA"
    else
        local staging_remote="${POST_WAVE_STAGING_MIRROR_REMOTE:-git@github.com:gridl-infra-staging/fjcloud.git}"
        staging_sha="$(git ls-remote "$staging_remote" refs/heads/main 2>/dev/null | awk 'NR == 1 {print $1}')"
    fi
    if [ -z "$staging_sha" ]; then
        echo "ERROR: staging gate: could not resolve staging mirror HEAD SHA." >&2
        return 1
    fi
    local runs run_status conclusion
    runs=$(gh run list -R "$staging_repo" --workflow=CI \
        --limit "${CI_POLL_RUN_LIMIT:-20}" \
        --json status,conclusion,headSha 2>/dev/null) || runs=""
    run_status=$(echo "$runs" | jq -r --arg sha "$staging_sha" \
        'map(select(.headSha == $sha))[0].status // empty' 2>/dev/null || true)
    conclusion=$(echo "$runs" | jq -r --arg sha "$staging_sha" \
        'map(select(.headSha == $sha))[0].conclusion // empty' 2>/dev/null || true)
    if [ "$run_status" != "completed" ] || [ "$conclusion" != "success" ]; then
        echo "ERROR: staging gate: staging CI is not green at ${staging_sha:0:12} (status=${run_status:-none}, conclusion=${conclusion:-none})." >&2
        echo "       Fix or wait for staging CI, then retry. Emergency-only bypass: run 'debbie sync prod' directly." >&2
        return 1
    fi

    echo "Staging gate passed: staging mirrors dev HEAD ${dev_head_sha:0:12}, staging CI green at mirror ${staging_sha:0:12}."
}

is_40hex() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

# Derive the dev SHA the prod mirror records it was synced from, straight from
# debbie's own provenance manifest in the prod mirror. This is the byte-equivalence
# proxy: same recorded dev_sha => the mirror carries the same generated payload.
# Compared against (never substituted for) the caller's --expected-dev-sha.
resolve_prod_mirror_manifest_dev_sha() {
    if [ -n "${POST_WAVE_PROD_MIRROR_MANIFEST_DEV_SHA:-}" ]; then
        printf '%s\n' "$POST_WAVE_PROD_MIRROR_MANIFEST_DEV_SHA"
        return 0
    fi
    local prod_repo="gridl-infra-prod/fjcloud"
    gh api "repos/$prod_repo/contents/.debbie/sync_manifest.json" \
        -H "Accept: application/vnd.github.raw" 2>/dev/null | jq -r '.dev_sha // empty' 2>/dev/null || true
}

# Atomically write a secret-safe promotion receipt binding every input,
# derived identity, and CI verdict. Writes to a temp sibling then renames so a
# reader never sees a half-written file. Deliberately records ONLY SHAs, run
# ids, and command names — never tokens/credentials (asserted by the test).
write_sync_receipt() {
    local receipt_path="$1" expected_dev_sha="$2" expected_pages_sha="$3"
    local source_dev_head="$4" prod_mirror_head="$5" manifest_dev_sha="$6"
    local ci_run_id="$7" ci_conclusion="$8"

    local tmp="${receipt_path}.tmp.$$"
    jq -n \
        --arg expected_dev_sha "$expected_dev_sha" \
        --arg expected_pages_sha "$expected_pages_sha" \
        --arg source_dev_head "$source_dev_head" \
        --arg prod_mirror_head "$prod_mirror_head" \
        --arg manifest_dev_sha "$manifest_dev_sha" \
        --arg ci_run_id "$ci_run_id" \
        --arg ci_conclusion "$ci_conclusion" \
        '{
          schema_version: 1,
          inputs: {
            expected_dev_sha: $expected_dev_sha,
            expected_staging_pages_sha: $expected_pages_sha
          },
          derived: {
            source_dev_head: $source_dev_head,
            prod_mirror_head: $prod_mirror_head,
            manifest_dev_sha: $manifest_dev_sha
          },
          commands: [
            "debbie sync prod",
            "gh run list -R gridl-infra-prod/fjcloud --workflow=CI",
            "scripts/tests/post_wave_sync_to_prod_verify_test.sh"
          ],
          ci: {
            green_run_id: $ci_run_id,
            conclusion: $ci_conclusion
          }
        }' > "$tmp"
    mv -f "$tmp" "$receipt_path"
}

# Promote dev main to prod: staging-green gate, debbie sync prod, prod mirror
# CI poll, then the terminal deploy-verify script. Requires caller-supplied
# exact identities (--expected-dev-sha, --expected-staging-pages-sha) and a
# fresh --receipt path — no ambient/discovered expectations.
execute_sync() {
    local confirmed="${POST_WAVE_CONFIRM:-0}"
    local yes_flag=0
    local expected_dev_sha="" expected_pages_sha="" receipt_path=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --yes) yes_flag=1; shift ;;
            --expected-dev-sha) expected_dev_sha="${2:-}"; shift 2 ;;
            --expected-staging-pages-sha) expected_pages_sha="${2:-}"; shift 2 ;;
            --receipt) receipt_path="${2:-}"; shift 2 ;;
            *) echo "ERROR: unknown --execute arg: $1" >&2; return 2 ;;
        esac
    done

    if [ "$confirmed" != "1" ] && [ "$yes_flag" -ne 1 ]; then
        echo "ERROR: --execute requires confirm: set POST_WAVE_CONFIRM=1 or pass --yes." >&2
        return 1
    fi

    # Caller-supplied EXACT identities are mandatory. An ambient/discovered
    # expectation is exactly the failure this gate exists to prevent.
    if [ -z "$expected_dev_sha" ] || [ -z "$expected_pages_sha" ] || [ -z "$receipt_path" ]; then
        echo "ERROR: --execute requires --expected-dev-sha <40hex>, --expected-staging-pages-sha <40hex>, and --receipt <absolute-new-json>." >&2
        return 1
    fi
    if ! is_40hex "$expected_dev_sha"; then
        echo "ERROR: --expected-dev-sha must be exactly 40 hex chars (got '$expected_dev_sha')." >&2
        return 1
    fi
    if ! is_40hex "$expected_pages_sha"; then
        echo "ERROR: --expected-staging-pages-sha must be exactly 40 hex chars (got '$expected_pages_sha')." >&2
        return 1
    fi
    case "$receipt_path" in
        /*) ;;
        *) echo "ERROR: --receipt must be an absolute path (got '$receipt_path')." >&2; return 1 ;;
    esac
    if [ -e "$receipt_path" ]; then
        echo "ERROR: --receipt path already exists (refusing to clobber): $receipt_path" >&2
        return 1
    fi

    local debbie_cli
    if ! debbie_cli="$(resolve_debbie_cli)"; then
        echo "ERROR: debbie CLI not found. Install debbie or set DEBBIE_BIN." >&2
        return 1
    fi

    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: gh CLI not found on PATH. Install gh (https://cli.github.com) to poll mirror CI." >&2
        return 1
    fi

    # The expected dev SHA must be the promotion we are actually shipping. Reject
    # a mismatch rather than trusting a discovered HEAD. (After the debbie/gh
    # prerequisite checks so a missing prerequisite reports its own clear error.)
    local dev_head_sha
    dev_head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    if [ "$expected_dev_sha" != "$dev_head_sha" ]; then
        echo "ERROR: --expected-dev-sha ${expected_dev_sha:0:12} does not match dev HEAD ${dev_head_sha:0:12}; refusing mismatched promotion." >&2
        return 1
    fi

    # Promotion gate — see staging_green_gate above. The env override is a
    # test seam only (same idiom as POST_WAVE_VERIFY_SCRIPT).
    if [ -n "${POST_WAVE_STAGING_GATE_SCRIPT:-}" ]; then
        "$POST_WAVE_STAGING_GATE_SCRIPT" || return 1
    else
        staging_green_gate || return 1
    fi

    echo "Running debbie sync prod..."
    "$debbie_cli" sync prod || {
        echo "ERROR: debbie sync prod failed" >&2
        return 1
    }

    local source_sha expected_sha
    source_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    if ! expected_sha="$(resolve_prod_mirror_head_sha)" || [ -z "$expected_sha" ]; then
        echo "ERROR: could not resolve prod mirror headSha after debbie sync." >&2
        return 1
    fi
    echo "Expected prod source SHA: ${source_sha:0:12}"
    echo "Expected prod mirror headSha: ${expected_sha:0:12}"

    local timeout_sec="${CI_POLL_TIMEOUT_SEC:-1800}"
    local ci_poll_run_limit="${CI_POLL_RUN_LIMIT:-20}"
    local poll_interval=30
    local elapsed=0
    local ci_result
    local run_sha conclusion ci_run_id=""

    echo "Polling prod mirror CI (timeout: ${timeout_sec}s)..."
    while [ "$elapsed" -lt "$timeout_sec" ]; do
        ci_result=$(gh run list -R gridl-infra-prod/fjcloud \
            --workflow=CI --limit "$ci_poll_run_limit" \
            --json conclusion,headSha,createdAt,databaseId 2>/dev/null) || true

        run_sha=$(echo "$ci_result" | jq -r --arg expected_sha "$expected_sha" \
            'map(select(.headSha == $expected_sha))[0].headSha // empty' 2>/dev/null || true)
        conclusion=$(echo "$ci_result" | jq -r --arg expected_sha "$expected_sha" \
            'map(select(.headSha == $expected_sha))[0].conclusion // empty' 2>/dev/null || true)
        ci_run_id=$(echo "$ci_result" | jq -r --arg expected_sha "$expected_sha" \
            'map(select(.headSha == $expected_sha))[0].databaseId // empty' 2>/dev/null || true)

        if [ -z "$run_sha" ]; then
            sleep "$poll_interval"
            elapsed=$((elapsed + poll_interval))
            echo "  ... waiting for CI run matching ${expected_sha:0:12} (${elapsed}s / ${timeout_sec}s)"
            continue
        fi

        if [ "$conclusion" = "success" ]; then
            echo "Prod mirror CI passed (headSha: ${run_sha:0:12})."
            break
        elif [ "$conclusion" = "failure" ]; then
            echo "ERROR: Prod mirror CI failed for ${run_sha:0:12}." >&2
            return 1
        fi

        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
        echo "  ... CI run found but pending (${elapsed}s / ${timeout_sec}s)"
    done

    if [ "$elapsed" -ge "$timeout_sec" ]; then
        echo "ERROR: Timed out waiting for prod mirror CI (expected headSha: ${expected_sha:0:12})." >&2
        return 1
    fi

    # Byte-equivalence proxy: the prod mirror's own sync manifest must record the
    # dev SHA we promised to ship. If debbie synced (or a no-diff retry landed on)
    # a different dev SHA, the mirror does not carry this content — fail loud
    # before verifying served identities. Compared against, never substituted for,
    # the caller expectation.
    local manifest_dev_sha
    manifest_dev_sha="$(resolve_prod_mirror_manifest_dev_sha)"
    if [ -z "$manifest_dev_sha" ]; then
        echo "ERROR: could not read prod mirror sync manifest dev_sha." >&2
        return 1
    fi
    if [ "$manifest_dev_sha" != "$expected_dev_sha" ]; then
        echo "ERROR: prod mirror manifest records dev ${manifest_dev_sha:0:12}, expected ${expected_dev_sha:0:12}." >&2
        return 1
    fi

    # Verifier owns the served-vs-expected identity comparison. execute_sync only
    # produces the expected identities (caller inputs + derived prod mirror head)
    # and propagates the verifier verdict.
    local verify_script="${POST_WAVE_VERIFY_SCRIPT:-$REPO_ROOT/scripts/tests/post_wave_sync_to_prod_verify_test.sh}"
    echo "Running post-sync verification..."
    local verify_rc=0
    POST_WAVE_EXPECTED_DEV_SHA="$expected_dev_sha" \
    POST_WAVE_EXPECTED_MIRROR_SHA="$expected_sha" \
    POST_WAVE_EXPECTED_PAGES_SHA="$expected_pages_sha" \
    "$verify_script" || verify_rc=$?
    if [ "$verify_rc" -ne 0 ]; then
        echo "ERROR: post-sync verification failed (rc=$verify_rc); no receipt written." >&2
        return "$verify_rc"
    fi

    write_sync_receipt "$receipt_path" \
        "$expected_dev_sha" "$expected_pages_sha" \
        "$source_sha" "$expected_sha" "$manifest_dev_sha" \
        "$ci_run_id" "$conclusion"
    echo "Wrote promotion receipt: $receipt_path"
}

MODE=""
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --check-only) MODE="check-only"; shift ;;
        --execute)    MODE="execute"; shift ;;
        --yes)        EXTRA_ARGS+=("--yes"); shift ;;
        --expected-dev-sha|--expected-staging-pages-sha|--receipt)
            if [ $# -lt 2 ]; then echo "ERROR: $1 requires a value" >&2; exit 2; fi
            EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
        --help|-h)    usage ;;
        *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "ERROR: specify --check-only or --execute" >&2
    exit 2
fi

case "$MODE" in
    check-only) check_only ;;
    execute)    execute_sync "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" ;;
esac
