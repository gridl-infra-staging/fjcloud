#!/usr/bin/env bash
# Shared environment file loading — single source of truth for local env parsing.
#
# Exports:
#   DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY  — shared local wrapper default.
#   load_env_file <path>              — parse KEY=value lines, reject executable shell syntax.
#   load_layered_env_files <path...>  — load env files in order while allowing later files to override earlier non-explicit keys.
#   parse_env_assignment_line <line>  — parse one env assignment into ENV_ASSIGNMENT_* globals.

# shellcheck disable=SC2034
DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY="fj_local_dev_admin_key_000000000000"
DEFAULT_INBOUND_ROUNDTRIP_S3_URI="s3://flapjack-cloud-releases/e2e-emails/"
DEFAULT_STAGING_SES_REGION="us-east-1"

# Strip leading/trailing whitespace and matching outer quotes from a raw env value.
trim_env_assignment_value() {
    local value="$1"
    local quote_char

    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    if [ -n "$value" ]; then
        quote_char="${value:0:1}"
        if { [ "$quote_char" = "'" ] || [ "$quote_char" = '"' ]; } && [ "${value: -1}" = "$quote_char" ]; then
            value="${value:1:${#value}-2}"
        fi
    fi

    printf '%s\n' "$value"
}

# Parse a single KEY=value line into ENV_ASSIGNMENT_KEY and ENV_ASSIGNMENT_VALUE globals.
# Returns 0 on success, 1 on invalid syntax, 2 for blank/comment lines.
parse_env_assignment_line() {
    local line="$1"

    ENV_ASSIGNMENT_KEY=""
    ENV_ASSIGNMENT_VALUE=""
    line="${line%$'\r'}"

    if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
        return 2
    fi

    if ! [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
        return 1
    fi

    ENV_ASSIGNMENT_KEY="${BASH_REMATCH[2]}"
    ENV_ASSIGNMENT_VALUE="$(trim_env_assignment_value "${BASH_REMATCH[3]}")"
}

env_snapshot_has_exported_var() {
    local exported_env_snapshot="$1"
    local var_name="$2"

    printf '%s\n' "$exported_env_snapshot" | grep -Eq "^declare -x ${var_name}(=|$)"
}

# Iterate valid KEY=value assignments in an env file, calling action_fn for each.
# action_fn receives no arguments; it reads ENV_ASSIGNMENT_KEY and ENV_ASSIGNMENT_VALUE
# from the caller's scope (bash dynamic scoping). Returns 1 on syntax error.
_for_each_env_assignment() {
    local env_file="$1"
    local action_fn="$2"
    local line line_number=0 parse_status

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -eq 0 ]; then
            "$action_fn"
            continue
        fi
        if [ "$parse_status" -eq 2 ]; then
            continue
        fi
        echo "ERROR: Unsupported syntax in ${env_file} at line ${line_number}; only KEY=value assignments are allowed" >&2
        return 1
    done < "$env_file"
}

# Load KEY=value pairs from a file into the environment, skipping keys already exported.
# Rejects any line that isn't a valid assignment, blank, or comment.
load_env_file() {
    local env_file="$1"
    local exported_env_snapshot

    [ -f "$env_file" ] || return 0
    exported_env_snapshot="$(export -p)"

    _load_env_file_action() {
        if env_snapshot_has_exported_var "$exported_env_snapshot" "$ENV_ASSIGNMENT_KEY"; then
            return
        fi
        printf -v "$ENV_ASSIGNMENT_KEY" '%s' "$ENV_ASSIGNMENT_VALUE"
        export "${ENV_ASSIGNMENT_KEY?}"
    }

    _for_each_env_assignment "$env_file" _load_env_file_action || exit 1
}

# Un-export keys set by a previous load_env_file call so a later file can override them.
# Keys explicitly exported before any file loading are preserved.
clear_env_file_exports_for_layering() {
    local env_file="$1"
    local explicit_exported_env_snapshot="$2"

    [ -f "$env_file" ] || return 0

    _clear_layering_action() {
        if ! env_snapshot_has_exported_var "$explicit_exported_env_snapshot" "$ENV_ASSIGNMENT_KEY" && [ "${!ENV_ASSIGNMENT_KEY+x}" = "x" ]; then
            export -n "${ENV_ASSIGNMENT_KEY?}"
        fi
    }

    _for_each_env_assignment "$env_file" _clear_layering_action || exit 1
}

# Re-export all keys defined in the given env file that are currently set in the shell.
# Used as the final step of load_layered_env_files to ensure all loaded keys are exported.
export_env_file_keys() {
    local env_file="$1"

    [ -f "$env_file" ] || return 0

    _export_keys_action() {
        if [ "${!ENV_ASSIGNMENT_KEY+x}" = "x" ]; then
            export "${ENV_ASSIGNMENT_KEY?}"
        fi
    }

    _for_each_env_assignment "$env_file" _export_keys_action || exit 1
}

# Derive staging contract env aliases from operator-curated equivalents.
#
# scripts/launch/hydrate_seeder_env_from_ssm.sh defines the canonical contract
# `STAGING_API_URL="${API_URL}"` when hydrating from SSM. Curated `.env.secret`
# files set only `API_URL`; without this derivation, downstream staging owners
# (validator, rehearsal, dry-run) would reject the prescribed env file as
# `non_staging_api_hostname` / `staging_api_url_missing`. Honoring the same
# contract here keeps the source of truth in one place.
derive_staging_contract_env_aliases() {
    if [ -z "${STAGING_API_URL:-}" ] && [ -n "${API_URL:-}" ]; then
        export STAGING_API_URL="$API_URL"
    fi
    if [ -z "${STAGING_STRIPE_WEBHOOK_URL:-}" ] && [ -n "${API_URL:-}" ]; then
        export STAGING_STRIPE_WEBHOOK_URL="${API_URL%/}/webhooks/stripe"
    fi
}

# Stage dunning clickthrough probes use the same inbound test inbox contract as
# validate_inbound_email_roundtrip.sh. Operator secret files are allowed to omit
# the optional S3 URI; staging's SES region is fixed by the deployed SES setup.
derive_staging_dunning_inbox_env_defaults() {
    if [ -z "${INBOUND_ROUNDTRIP_S3_URI:-}" ]; then
        export INBOUND_ROUNDTRIP_S3_URI="$DEFAULT_INBOUND_ROUNDTRIP_S3_URI"
    fi
    if [ -z "${SES_REGION:-}" ]; then
        export SES_REGION="${AWS_DEFAULT_REGION:-$DEFAULT_STAGING_SES_REGION}"
    fi
}

hydrate_staging_tool_env_from_ssm() {
    local environment="${1:-staging}"
    local hydrator_dir hydrator output filtered_output line

    hydrator_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    hydrator="${STAGING_TOOL_ENV_HYDRATOR_SCRIPT:-$hydrator_dir/launch/hydrate_seeder_env_from_ssm.sh}"
    [ -x "$hydrator" ] || return 1

    if ! output="$(bash "$hydrator" "$environment")"; then
        return 1
    fi

    filtered_output=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            export\ DATABASE_URL=*)
                # Preserve the existing rehearsal DB-evidence contract: when
                # the operator env omits a local DB URL, reads are delegated to
                # the staging DB query owner instead of assuming direct DB
                # network access from the caller's host.
                continue
                ;;
        esac
        filtered_output="${filtered_output}${line}"$'\n'
    done <<< "$output"

    # The hydrator prints shell-quoted export statements with printf %q and is
    # the canonical staging credential owner used by launch tooling. Evaluate
    # that export stream here so stale operator env-file values cannot
    # authenticate against deployed staging.
    eval "$filtered_output"
}

# Load env files in order while keeping explicit shell exports highest
# precedence and allowing later files to override earlier file-provided values.
load_layered_env_files() {
    local explicit_exported_env_snapshot
    local env_files=("$@")
    local env_file
    local index
    local last_index

    [ "${#env_files[@]}" -gt 0 ] || return 0
    explicit_exported_env_snapshot="$(export -p)"
    last_index=$((${#env_files[@]} - 1))

    for index in "${!env_files[@]}"; do
        env_file="${env_files[$index]}"
        load_env_file "$env_file"
        if [ "$index" -lt "$last_index" ]; then
            clear_env_file_exports_for_layering "$env_file" "$explicit_exported_env_snapshot"
        fi
    done

    for env_file in "${env_files[@]}"; do
        export_env_file_keys "$env_file"
    done
}
