#!/usr/bin/env bash
# bootstrap-env-local.sh — Generate .env.local from .env.local.example and
# the external secret source.
#
# Resolution order for each key:
#   1. External secret source (if the key exists there, use it)
#   2. Random generation (for placeholder values like JWT_SECRET, ADMIN_KEY)
#   3. Template default from .env.local.example
#
# The external secret source is resolved from (in order):
#   - FJCLOUD_SECRET_FILE env var (explicit override)
#   - Default path: $REPO_ROOT/.secret/.env.secret
#
# Exits cleanly when .env.local already exists so reruns never clobber hand
# edits. Keys in the secret source that don't appear in the template are
# appended to .env.local so production secrets (Stripe, etc.) are available.
#
# Exit codes:
#   0 — .env.local created or already exists
#   1 — missing .env.local.example template
#
# Status messages (deterministic, parseable by wrapper scripts):
#   BOOTSTRAP_OK:    file created successfully
#   BOOTSTRAP_SKIP:  file already exists, no changes made
#   BOOTSTRAP_ERROR: unrecoverable error (missing template)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# parse_env_assignment_line is the repo's one owner of "what does a line in an
# env file mean". It handles the `export KEY=value` form that the operator's
# real .secret/.env.secret uses throughout (that file is meant to be sourced),
# plus quoting and CR endings. This script used to carry its own narrower regex
# that accepted only bare KEY=value, so against the real secret file it parsed
# nothing at all and silently fell back to template defaults for every key.
# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

ENV_LOCAL="$REPO_ROOT/.env.local"
ENV_EXAMPLE="$REPO_ROOT/.env.local.example"
DEFAULT_SECRET_PATH="$REPO_ROOT/.secret/.env.secret"
SECRET_FILE="${FJCLOUD_SECRET_FILE:-$DEFAULT_SECRET_PATH}"

# Exit cleanly when .env.local already exists — never overwrite hand edits.
if [ -f "$ENV_LOCAL" ]; then
    echo "BOOTSTRAP_SKIP: .env.local already exists at $ENV_LOCAL"
    exit 0
fi

if [ ! -f "$ENV_EXAMPLE" ]; then
    echo "BOOTSTRAP_ERROR: .env.local.example not found at $ENV_EXAMPLE" >&2
    exit 1
fi

# --- Parse secret source into a temp lookup file ---
# Each line: KEY=value (only active assignments, no comments/blanks).
# Uses grep for O(1)-style lookups instead of bash 4 associative arrays.
SECRETS_PARSED=""
if [ -f "$SECRET_FILE" ]; then
    SECRETS_PARSED=$(mktemp)
    trap 'rm -f "$SECRETS_PARSED"' EXIT
    while IFS= read -r line || [ -n "$line" ]; do
        # Normalise every accepted line to bare KEY=value. Downstream lookups
        # (secret_lookup, the append loop) then only ever see one shape, and the
        # generated .env.local never inherits an `export ` prefix.
        if parse_env_assignment_line "$line"; then
            printf '%s=%s\n' "$ENV_ASSIGNMENT_KEY" "$ENV_ASSIGNMENT_VALUE"
        fi
    done < "$SECRET_FILE" > "$SECRETS_PARSED"
fi

# Local-dev alias suffix.
#
# The operator's secret file holds several environments side by side, labelled
# by suffix: GITHUB_OAUTH_CLIENT_ID_DEV next to GITHUB_OAUTH_CLIENT_ID_STAGING.
# The application only ever reads the BARE name (infra/api/src/config.rs,
# parse_optional_oauth_pair), so local dev needs the _DEV value delivered under
# the bare key or the API starts with that feature silently unconfigured.
#
# ONLY _DEV aliases. _STAGING deliberately does not, because a staging value
# becoming the local default is the same failure as
# bugs/2026_05_22_local_demo_seeds_to_production.md — local tooling quietly
# acting against a deployed environment.
LOCAL_ENV_ALIAS_SUFFIX="_DEV"

# Look up a key in the parsed secrets file. Prints the value if found.
# Returns 0 if found, 1 if not found or no secret file.
#
# Falls back to <key>_DEV so a suffix-labelled local secret satisfies a bare
# lookup. The explicit bare key is tried first: a derived value must never
# shadow one the operator stated outright.
secret_lookup() {
    local key="$1"
    [ -n "$SECRETS_PARSED" ] || return 1
    local match
    if match=$(grep "^${key}=" "$SECRETS_PARSED" | head -1) && [ -n "$match" ]; then
        printf '%s' "${match#*=}"
        return 0
    fi
    match=$(grep "^${key}${LOCAL_ENV_ALIAS_SUFFIX}=" "$SECRETS_PARSED" | head -1) || return 1
    [ -n "$match" ] || return 1
    printf '%s' "${match#*=}"
}

# Keys that name an environment TARGET or IDENTITY rather than a secret value.
# These must NEVER be sourced from .secret/.env.secret into a local dev .env.local
# — if they leak in, local tooling silently writes to whatever environment the
# operator's secret file was last pointed at (typically prod). This is what
# caused bugs/2026_05_22_local_demo_seeds_to_production.md: API_URL and ADMIN_KEY
# leaked from .secret/.env.secret into .env.local, so seed_local.sh hit
# https://api.flapjack.foo with prod admin creds and created live Stripe customers.
# The deny-list applies to BOTH the "override template value" path and the
# "append secret-only keys" path below.
LOCAL_ENV_DENY_LIST=(
    API_URL                     # who do I call? (must default to localhost)
    ADMIN_KEY                   # admin auth for the API I call (must be local-random)
    DATABASE_URL                # which DB do I write to? (must default to local docker pg)
    DATABASE_URL_SSM_PARAM      # where do I look up a remote DB URL? (must not be set locally)

    # Live infrastructure credentials. The two groups above answer "which
    # environment am I acting on"; these answer "what am I authorised to do to
    # it", and locally the answer must be nothing. The local app talks only to
    # docker-compose services, and the scripts that genuinely need these source
    # .secret/.env.secret directly (the documented pattern in CLAUDE.md), so
    # nothing loses access by keeping them out of the generated file.
    #
    # This became load-bearing when the export-prefix parse bug was fixed: the
    # secret file's keys started flowing for the first time, and it holds far
    # more than app config.
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN
    CLOUDFLARE_GLOBAL_API_KEY
    CLOUDFLARE_EMAIL
    CLOUDFLARE_X_Auth_Email
    GITHUB_PAT
    PRIVACY_PRODUCTION_API_KEY
    ALGOLIA_ADMIN_KEY
)

is_denied_for_local_env() {
    local key="$1"
    local denied
    for denied in "${LOCAL_ENV_DENY_LIST[@]}"; do
        if [ "$key" = "$denied" ]; then
            return 0
        fi
    done
    # Deny by shape as well as by name: a key the operator has explicitly
    # labelled LIVE is never local config, and this way a _LIVE key added to
    # the secret file in future is denied without anyone remembering to edit
    # the list above.
    case "$key" in
        *_LIVE) return 0 ;;
    esac
    return 1
}

# Pre-generate random fallbacks for placeholder fields
random_jwt_secret="$(openssl rand -hex 32)"
random_admin_key="$(openssl rand -hex 16)"

# --- Transform template, overlaying secret source values ---
# Track which keys appear in the template (one key per line in a temp file)
# so we can append secret-only keys afterward.
TEMPLATE_KEYS=$(mktemp)
if [ -z "$SECRETS_PARSED" ]; then
    trap 'rm -f "$TEMPLATE_KEYS"' EXIT
else
    trap 'rm -f "$SECRETS_PARSED" "$TEMPLATE_KEYS"' EXIT
fi

while IFS= read -r line || [ -n "$line" ]; do
    # Comments and blank lines pass through unchanged
    if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// /}" ]]; then
        printf '%s\n' "$line"
        continue
    fi

    # Extract key from assignment lines
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
        tpl_key="${BASH_REMATCH[1]}"
        echo "$tpl_key" >> "$TEMPLATE_KEYS"

        # Priority 1: secret source has this key.
        # Exception: keys on the local-env deny-list (targets/identity, not secrets)
        # must NOT be overridden by the secret source — they must keep the
        # template's local default. See LOCAL_ENV_DENY_LIST comment above.
        local_secret_val=""
        if ! is_denied_for_local_env "$tpl_key" && local_secret_val=$(secret_lookup "$tpl_key"); then
            printf '%s\n' "$tpl_key=$local_secret_val"
            continue
        fi

        # Priority 2: placeholder values get random generation
        case "$line" in
            JWT_SECRET=replace-with-32-plus-random-characters)
                printf '%s\n' "JWT_SECRET=$random_jwt_secret"
                continue ;;
            ADMIN_KEY=replace-with-random-admin-key)
                printf '%s\n' "ADMIN_KEY=$random_admin_key"
                continue ;;
        esac
    fi

    # Priority 3: pass through template default
    printf '%s\n' "$line"
done < "$ENV_EXAMPLE" > "$ENV_LOCAL"

# --- Append secret-source keys not present in the template ---
# Skip any key on the local-env deny-list: those are targets/identity, not secrets,
# and silently appending a prod target into a "local" env is how the seed script
# wrote to prod in bugs/2026_05_22_local_demo_seeds_to_production.md.
if [ -n "$SECRETS_PARSED" ]; then
    appended=0
    while IFS= read -r secret_line || [ -n "$secret_line" ]; do
        skey="${secret_line%%=*}"
        [ "$skey" = "STRIPE_PUBLISHABLE_KEY" ] && [[ "${secret_line#*=}" != pk_test_* ]] && continue
        if is_denied_for_local_env "$skey"; then
            continue
        fi

        # A _DEV-suffixed secret is emitted under its BARE name, which is the
        # only name the application reads. See LOCAL_ENV_ALIAS_SUFFIX above.
        if [[ "$skey" == *"$LOCAL_ENV_ALIAS_SUFFIX" ]]; then
            bare_key="${skey%"$LOCAL_ENV_ALIAS_SUFFIX"}"
            # The deny-list must be checked against the BARE name too. Without
            # this, API_URL_DEV would sail past a deny-list that only ever sees
            # the suffixed key and would then land as API_URL — reopening
            # exactly the hole LOCAL_ENV_DENY_LIST exists to close.
            if is_denied_for_local_env "$bare_key"; then
                continue
            fi
            # An explicit bare entry elsewhere in the file wins; it gets emitted
            # by its own loop iteration, so drop the alias rather than racing it.
            if grep -q "^${bare_key}=" "$SECRETS_PARSED"; then
                continue
            fi
            if ! grep -qx "$bare_key" "$TEMPLATE_KEYS"; then
                if [ "$appended" -eq 0 ]; then
                    printf '\n# --- Injected from external secret source ---\n' >> "$ENV_LOCAL"
                    appended=1
                fi
                printf '%s=%s\n' "$bare_key" "${secret_line#*=}" >> "$ENV_LOCAL"
            fi
            continue
        fi
        if ! grep -qx "$skey" "$TEMPLATE_KEYS"; then
            if [ "$appended" -eq 0 ]; then
                printf '\n# --- Injected from external secret source ---\n' >> "$ENV_LOCAL"
                appended=1
            fi
            printf '%s\n' "$secret_line" >> "$ENV_LOCAL"
        fi
    done < "$SECRETS_PARSED"
fi

echo "BOOTSTRAP_OK: .env.local created at $ENV_LOCAL"
