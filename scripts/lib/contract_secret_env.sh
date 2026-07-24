#!/usr/bin/env bash

# Secret env files are data inputs, not shell/runtime configuration. Reject
# control variables that can change command resolution or inject code into
# downstream subprocesses in the current shell.
contract_secret_env_key_allowed() {
    local key="$1"

    case "$key" in
        PATH|IFS|ENV|BASH_ENV|SHELLOPTS|BASHOPTS|CDPATH|GLOBIGNORE|PS4|PROMPT_COMMAND|ZDOTDIR|FPATH|MANPATH|INFOPATH|TERMINFO|TERMINFO_DIRS|LD_*|DYLD_*|PYTHONPATH|PYTHONHOME|PYTHONSTARTUP|RUBYLIB|RUBYOPT|PERL5LIB|PERL5OPT|NODE_OPTIONS|GIT_CONFIG_*|GIT_SSH|GIT_SSH_COMMAND)
            return 1
            ;;
    esac

    return 0
}

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
            if ! contract_secret_env_key_allowed "$ENV_ASSIGNMENT_KEY"; then
                echo "ERROR: Unsupported key ${ENV_ASSIGNMENT_KEY} in ${secret_file} at line ${line_number}; secret env files may not override shell/runtime control variables" >&2
                return 1
            fi
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
