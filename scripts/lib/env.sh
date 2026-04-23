#!/usr/bin/env bash
# Shared environment file loading — single source of truth for local env parsing.
#
# Exports:
#   DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY  — shared local wrapper default.
#   load_env_file <path>              — parse KEY=value lines, reject executable shell syntax.
#   load_layered_env_files <path...>  — load env files in order while allowing later files to override earlier non-explicit keys.
#   parse_env_assignment_line <line>  — parse one env assignment into ENV_ASSIGNMENT_* globals.

DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY="fj_local_dev_admin_key_000000000000"

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

# Load KEY=value pairs from a file into the environment, skipping keys already exported.
# Rejects any line that isn't a valid assignment, blank, or comment.
load_env_file() {
    local env_file="$1"
    local line line_number=0 parse_status
    local exported_env_snapshot

    [ -f "$env_file" ] || return 0
    exported_env_snapshot="$(export -p)"

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -eq 0 ]; then
            if printf '%s\n' "$exported_env_snapshot" | grep -Eq "^declare -x ${ENV_ASSIGNMENT_KEY}(=|$)"; then
                continue
            fi
            printf -v "$ENV_ASSIGNMENT_KEY" '%s' "$ENV_ASSIGNMENT_VALUE"
            export "$ENV_ASSIGNMENT_KEY"
            continue
        fi

        if [ "$parse_status" -eq 2 ]; then
            continue
        fi

        echo "ERROR: Unsupported syntax in ${env_file} at line ${line_number}; only KEY=value assignments are allowed" >&2
        exit 1
    done < "$env_file"
}

env_snapshot_has_exported_var() {
    local exported_env_snapshot="$1"
    local var_name="$2"

    printf '%s\n' "$exported_env_snapshot" | grep -Eq "^declare -x ${var_name}(=|$)"
}

# Un-export keys set by a previous load_env_file call so a later file can override them.
# Keys explicitly exported before any file loading are preserved.
clear_env_file_exports_for_layering() {
    local env_file="$1"
    local explicit_exported_env_snapshot="$2"
    local line line_number=0 parse_status

    [ -f "$env_file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -eq 0 ]; then
            if ! env_snapshot_has_exported_var "$explicit_exported_env_snapshot" "$ENV_ASSIGNMENT_KEY" && [ "${!ENV_ASSIGNMENT_KEY+x}" = "x" ]; then
                export -n "$ENV_ASSIGNMENT_KEY"
            fi
            continue
        fi

        if [ "$parse_status" -eq 2 ]; then
            continue
        fi

        echo "ERROR: Unsupported syntax in ${env_file} at line ${line_number}; only KEY=value assignments are allowed" >&2
        exit 1
    done < "$env_file"
}

# Re-export all keys defined in the given env file that are currently set in the shell.
# Used as the final step of load_layered_env_files to ensure all loaded keys are exported.
export_env_file_keys() {
    local env_file="$1"
    local line line_number=0 parse_status

    [ -f "$env_file" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -eq 0 ]; then
            if [ "${!ENV_ASSIGNMENT_KEY+x}" = "x" ]; then
                export "$ENV_ASSIGNMENT_KEY"
            fi
            continue
        fi

        if [ "$parse_status" -eq 2 ]; then
            continue
        fi

        echo "ERROR: Unsupported syntax in ${env_file} at line ${line_number}; only KEY=value assignments are allowed" >&2
        exit 1
    done < "$env_file"
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
