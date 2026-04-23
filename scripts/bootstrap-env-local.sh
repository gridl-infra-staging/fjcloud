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
#   - Default path: ~/repos/gridl/fjcloud/.secret/.env.secret
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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_LOCAL="$REPO_ROOT/.env.local"
ENV_EXAMPLE="$REPO_ROOT/.env.local.example"
DEFAULT_SECRET_PATH="$HOME/repos/gridl/fjcloud/.secret/.env.secret"
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
        case "$line" in
            '#'*|'') continue ;;
        esac
        # Only keep lines that look like KEY=value
        if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            printf '%s\n' "$line"
        fi
    done < "$SECRET_FILE" > "$SECRETS_PARSED"
fi

# Look up a key in the parsed secrets file. Prints the value if found.
# Returns 0 if found, 1 if not found or no secret file.
secret_lookup() {
    local key="$1"
    [ -n "$SECRETS_PARSED" ] || return 1
    local match
    match=$(grep "^${key}=" "$SECRETS_PARSED" | head -1) || return 1
    printf '%s' "${match#*=}"
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

        # Priority 1: secret source has this key
        local_secret_val=""
        if local_secret_val=$(secret_lookup "$tpl_key"); then
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
if [ -n "$SECRETS_PARSED" ]; then
    appended=0
    while IFS= read -r secret_line || [ -n "$secret_line" ]; do
        skey="${secret_line%%=*}"
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
