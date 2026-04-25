#!/usr/bin/env bash
# Shared explicit-account secret-key resolver for Stripe shell scripts.
#
# Contract:
#   - --account <name> resolves STRIPE_SECRET_KEY_<name>.
#   - Resolved key is exported to canonical STRIPE_SECRET_KEY only for the
#     current script invocation.
#   - Without --account, canonical STRIPE_SECRET_KEY must already be present.

set -euo pipefail

# Keep flag-value validation in the shared seam so each Stripe script does not
# need its own copy of the same bash 3.2-safe guard.
stripe_account_require_flag_value() {
    local flag_name="$1"
    local arg_count="$2"
    local flag_value="${3:-}"

    if [ "$arg_count" -lt 2 ] || [ -z "$flag_value" ]; then
        echo "ERROR: ${flag_name} requires a value" >&2
        return 2
    fi

    printf '%s\n' "$flag_value"
}

stripe_account_resolve_secret_key() {
    local account_name="${1:-}"
    local suffixed_var=""
    local resolved_value=""

    if [ -n "$account_name" ]; then
        suffixed_var="STRIPE_SECRET_KEY_${account_name}"
        # Use eval for bash 3.2 compatibility when resolving dynamic env names.
        eval "resolved_value=\"\${${suffixed_var}:-}\""
        if [ -z "${resolved_value}" ]; then
            echo "ERROR: --account ${account_name} passed, but env var ${suffixed_var} is not set in .secret/.env.secret" >&2
            return 2
        fi
        export STRIPE_SECRET_KEY="${resolved_value}"
        export STRIPE_TARGET_ACCOUNT_NAME="${account_name}"
    else
        export STRIPE_TARGET_ACCOUNT_NAME="canonical"
    fi

    if [ -z "${STRIPE_SECRET_KEY:-}" ]; then
        echo "ERROR: STRIPE_SECRET_KEY must be set — pass --account <name> or export canonical STRIPE_SECRET_KEY" >&2
        return 1
    fi
}
