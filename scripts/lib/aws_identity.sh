#!/usr/bin/env bash
# The AWS_IDENTITY_* globals below are this library's caller-facing output
# contract (read by scripts that source it), so shellcheck's "appears unused"
# does not apply to them.
# shellcheck disable=SC2034
#
# Shared AWS caller-identity triage — single source of truth for the question
# "is a valid AWS identity available right now, and if not, WHY?".
#
# WHY THIS EXISTS (root-caused 2026-07-08)
# ----------------------------------------
# For ~5 weeks the support-inbox synthetic canary, the SES clickthrough/dunning
# probes, and the paid-beta RC all classified every `aws sts get-caller-identity`
# failure as a dead-credential environment gap and SKIPPED — without ever trying
# the repo's canonical secret file. The real cause was almost always stale
# ambient `AWS_*` environment variables inherited by lane worktrees (a revoked
# key twin, an expired session token) shadowing a VALID long-lived key sitting
# in `.secret/.env.secret`.
#
# The trap is subtle and worth spelling out: `scripts/lib/env.sh::load_env_file`
# deliberately SKIPS keys that are already exported ("explicit shell exports win"
# is a documented, load-bearing precedence used by the layered-env and CI
# injection paths). So the intuitive fix — "just source .env.secret" — does NOT
# recover, because the bad inherited `AWS_ACCESS_KEY_ID` is already exported and
# the file's value is skipped. The bad key keeps winning, STS keeps failing, and
# the diagnostic keeps reading "credentials present but rejected → dead cred".
#
# This helper encodes the missing triage: probe; if the failure looks like
# *invalid* (present-but-rejected) rather than *absent* credentials, clear the
# ambient `AWS_*` values and retry against the secret file; then report a single
# canonical diagnosis so no future reader mistakes environment pollution for a
# dead credential again.
#
# CONTRACT: this is a DIAGNOSIS QUERY, not a policy. It never exits or skips on
# the caller's behalf. Callers branch on `AWS_IDENTITY_STATUS` and keep their own
# reaction (hard-fail / skip / graceful-degrade). On a `recovered` result the
# working credentials have been exported into the caller's shell, so subsequent
# AWS calls in the same process use them.
#
# CURRENT INTEGRATIONS: scripts/lib/test_inbox_helpers.sh::test_inbox_require_aws_inbox_prereqs
# (the canary / SES-clickthrough / paid-beta-RC inbox path where the misdiagnosis
# lived). REMAINING SSOT MIGRATION TARGETS (each has its own, currently-working,
# graceful failure contract, so they were left for a follow-up to avoid churn —
# converging them onto this helper would also give them pollution recovery):
#   - scripts/probe_live_state.sh (AWS_OK gate; degrades to SKIP_NO_CREDS)
#   - scripts/probe_canary_live_state.sh (hard-fail exit-2 preflight)
#   - scripts/canary/contracts/customer_loop_admin_cleanup_live_contract.sh (skip_with_hint)
#   - scripts/launch/ses_deliverability_evidence.sh (evidence capture)
#
# Output globals (always set before any return):
#   AWS_IDENTITY_STATUS      valid | recovered | no_credentials |
#                            invalid_credentials | cli_missing
#   AWS_IDENTITY_ACCOUNT     12-digit account id (valid/recovered only)
#   AWS_IDENTITY_ARN         caller ARN (valid/recovered only)
#   AWS_IDENTITY_SOURCE      ambient | <secret-file path>
#   AWS_IDENTITY_DIAGNOSTIC  one canonical human-readable line
#   AWS_IDENTITY_RAW_ERROR   last raw STS error text (for detail/logging)

# Resolve this library's directory once so we can locate sibling libs and the
# default secret file without depending on the caller's cwd.
AWS_IDENTITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AWS_IDENTITY_REPO_ROOT="$(cd "$AWS_IDENTITY_LIB_DIR/../.." && pwd)"

# env.sh owns `load_env_file` (KEY=value parsing, single source of truth). Only
# source it if the caller has not already — sourcing is idempotent but this
# avoids clobbering an already-configured environment loader.
if ! declare -f load_env_file >/dev/null 2>&1; then
    # shellcheck source=scripts/lib/env.sh
    source "$AWS_IDENTITY_LIB_DIR/env.sh"
fi

# Run a single STS caller-identity probe against whatever credentials are
# currently in the environment. Sets AWS_IDENTITY_ACCOUNT/ARN on success and
# AWS_IDENTITY_RAW_ERROR on failure. Returns 0 iff a parseable identity came
# back. Never mutates credentials — it only observes.
_aws_identity_probe() {
    AWS_IDENTITY_ACCOUNT=""
    AWS_IDENTITY_ARN=""
    AWS_IDENTITY_RAW_ERROR=""

    local out rc=0
    # 2>&1 mirrors the existing call sites: STS prints JSON to stdout on success
    # and an error line to stderr on failure; we want whichever we got.
    # Force JSON via AWS_DEFAULT_OUTPUT (env), NOT a positional `--output json`
    # flag, so the invocation args stay byte-identical to every other call site
    # (`aws sts get-caller-identity`). Call sites and their tests count preflight
    # calls by matching that exact arg string; an extra flag would silently break
    # those counters. The env var guarantees parseable JSON regardless of the
    # operator's configured default output format.
    out="$(AWS_PAGER="" AWS_DEFAULT_OUTPUT=json aws sts get-caller-identity 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        AWS_IDENTITY_RAW_ERROR="$out"
        return 1
    fi

    # Parse without jq/python (not guaranteed on probe hosts). The STS JSON shape
    # is fixed and flat, so a targeted sed is sufficient and dependency-free.
    AWS_IDENTITY_ACCOUNT="$(printf '%s' "$out" | sed -n 's/.*"Account"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    AWS_IDENTITY_ARN="$(printf '%s' "$out" | sed -n 's/.*"Arn"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

    if [ -z "$AWS_IDENTITY_ACCOUNT" ]; then
        # Exit 0 but unparseable output — treat as a failure rather than
        # constructing bogus ARNs downstream (the historical footgun this whole
        # library exists to kill).
        AWS_IDENTITY_RAW_ERROR="sts get-caller-identity returned unparseable output: $out"
        return 1
    fi
    return 0
}

# Classify a raw STS error into "no_credentials" (chain empty — nothing to
# recover) vs "invalid_credentials" (something was present but AWS rejected it —
# the recoverable, pollution-shaped case). Kept as its own function so the
# pattern list is a single source of truth used for both the first probe and the
# post-recovery probe.
_aws_identity_classify_error() {
    local raw="$1"
    case "$raw" in
        *NoCredentials*|*"Unable to locate credentials"*|*NoCredentialProviders*|*"credentials could not be"*)
            printf 'no_credentials\n'
            ;;
        *)
            # InvalidClientTokenId, SignatureDoesNotMatch, ExpiredToken,
            # AuthFailure, AccessDenied, etc. — creds present, AWS said no.
            printf 'invalid_credentials\n'
            ;;
    esac
}

# Resolve the secret file to attempt recovery from: explicit arg > operator
# override env > repo default. Mirrors the FJCLOUD_SECRET_FILE convention used by
# probe_live_state.sh and the canary so there is one resolution rule.
_aws_identity_resolve_secret_file() {
    local explicit="$1"
    if [ -n "$explicit" ]; then
        printf '%s\n' "$explicit"
    elif [ -n "${FJCLOUD_SECRET_FILE:-}" ]; then
        printf '%s\n' "$FJCLOUD_SECRET_FILE"
    else
        printf '%s\n' "$AWS_IDENTITY_REPO_ROOT/.secret/.env.secret"
    fi
}

# Main entry point. Optional arg: path to a secret file to recover from.
# Returns 0 for valid|recovered, 1 otherwise. Always sets the output globals.
aws_identity_ensure() {
    local secret_file="${1:-}"

    AWS_IDENTITY_STATUS=""
    AWS_IDENTITY_ACCOUNT=""
    AWS_IDENTITY_ARN=""
    AWS_IDENTITY_SOURCE=""
    AWS_IDENTITY_DIAGNOSTIC=""
    AWS_IDENTITY_RAW_ERROR=""

    if ! command -v aws >/dev/null 2>&1; then
        AWS_IDENTITY_STATUS="cli_missing"
        AWS_IDENTITY_DIAGNOSTIC="aws CLI not found on PATH"
        return 1
    fi

    # Attempt 1: whatever the ambient environment / default credential chain
    # provides. If that already works we must NOT touch it — clearing valid
    # ambient creds (e.g. legitimate CI-injected or SSO creds) would be the
    # opposite bug. We only ever disturb ambient creds that just failed.
    local rc=0
    _aws_identity_probe || rc=$?
    if [ "$rc" -eq 0 ]; then
        AWS_IDENTITY_STATUS="valid"
        AWS_IDENTITY_SOURCE="ambient"
        AWS_IDENTITY_DIAGNOSTIC="aws identity valid (account=${AWS_IDENTITY_ACCOUNT}) via ambient credential chain"
        return 0
    fi

    local first_error="$AWS_IDENTITY_RAW_ERROR"
    local first_class
    first_class="$(_aws_identity_classify_error "$first_error")"

    secret_file="$(_aws_identity_resolve_secret_file "$secret_file")"

    # Recovery is only attempted when the secret file exists AND actually defines
    # a long-lived key that ambient pollution could have been shadowing. The grep
    # guard keeps us from pointlessly clearing the environment when there is
    # nothing better to fall back to.
    if [ -f "$secret_file" ] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?AWS_ACCESS_KEY_ID=' "$secret_file"; then
        # THE FIX: clear ambient AWS_* before loading the file. env.sh skips
        # already-exported keys, so without this unset the bad inherited key
        # would win again and recovery would be a no-op. This is the single
        # deliberate exception to env.sh's "explicit exports win" precedence,
        # and it is safe precisely because these ambient values just failed STS.
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
        load_env_file "$secret_file"

        rc=0
        _aws_identity_probe || rc=$?
        if [ "$rc" -eq 0 ]; then
            AWS_IDENTITY_STATUS="recovered"
            AWS_IDENTITY_SOURCE="$secret_file"
            AWS_IDENTITY_DIAGNOSTIC="aws identity RECOVERED via ${secret_file} (account=${AWS_IDENTITY_ACCOUNT}); ambient AWS_* were rejected by STS — environment pollution, not a dead credential"
            return 0
        fi

        # Recovery ran but the file's key was also rejected/absent. Report the
        # post-recovery classification so the diagnostic reflects the real state.
        local second_class
        second_class="$(_aws_identity_classify_error "$AWS_IDENTITY_RAW_ERROR")"
        if [ "$second_class" = "no_credentials" ]; then
            AWS_IDENTITY_STATUS="no_credentials"
            AWS_IDENTITY_DIAGNOSTIC="aws sts get-caller-identity could not locate credentials (tried ambient chain and ${secret_file})"
        else
            AWS_IDENTITY_STATUS="invalid_credentials"
            AWS_IDENTITY_DIAGNOSTIC="aws credentials rejected by STS after trying ambient and ${secret_file}: ${AWS_IDENTITY_RAW_ERROR}"
        fi
        return 1
    fi

    # No secret-file recovery path available — report the first-attempt class.
    if [ "$first_class" = "no_credentials" ]; then
        AWS_IDENTITY_STATUS="no_credentials"
        AWS_IDENTITY_DIAGNOSTIC="aws sts get-caller-identity could not locate credentials (no ambient chain and no secret-file key to recover from)"
    else
        AWS_IDENTITY_STATUS="invalid_credentials"
        AWS_IDENTITY_DIAGNOSTIC="aws credentials rejected by STS and no secret-file key available to recover: ${first_error}"
    fi
    return 1
}

# Convenience boolean wrapper for call sites that only need "usable identity?"
# but still want the pollution-recovery behavior. Returns 0 for valid|recovered.
# Safe under `set -e`: swallows the non-zero return and re-derives from status.
aws_identity_is_valid() {
    aws_identity_ensure "${1:-}" || true
    case "$AWS_IDENTITY_STATUS" in
        valid|recovered) return 0 ;;
        *) return 1 ;;
    esac
}
