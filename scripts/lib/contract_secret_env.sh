#!/usr/bin/env bash

# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
# TODO: Document load_contract_secret_env.
load_contract_secret_env() {
    local secret_file="$1"
    local line_number=0 line parse_status
    local exported_env_snapshot

    [ -f "$secret_file" ] || return 0

    # Preserve explicit shell exports as highest precedence, matching
    # scripts/lib/env.sh::load_env_file behavior used elsewhere.
    exported_env_snapshot="$(export -p)"

    # shellcheck source=./env.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

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

        echo "ERROR: Unsupported syntax in ${secret_file} at line ${line_number}; only KEY=value assignments are allowed" >&2
        return 1
    done < "$secret_file"
}
