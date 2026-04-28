#!/usr/bin/env bash
# Shared test helpers used across multiple test files.
#
# Callers must define REPO_ROOT before sourcing.

write_mock_script() {
    local path="$1" body="$2"
    cat > "$path" <<MOCK
#!/usr/bin/env bash
$body
MOCK
    chmod +x "$path"
}

new_mock_command_dir() {
    local command_name="$1" script_body="$2"
    local mock_dir
    mock_dir="$(mktemp -d)"
    write_mock_script "$mock_dir/$command_name" "$script_body"
    echo "$mock_dir"
}

backup_repo_env_file() {
    local backup_path="$1"
    if [ -f "$REPO_ROOT/.env.local" ]; then
        cp "$REPO_ROOT/.env.local" "$backup_path"
        return 0
    fi
    return 1
}

restore_repo_env_file() {
    local backup_path="$1"
    if [ -f "$backup_path" ]; then
        cp "$backup_path" "$REPO_ROOT/.env.local"
    else
        rm -f "$REPO_ROOT/.env.local"
    fi
}
