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

# Build a deterministic command PATH that keeps the host's ordinary utilities
# while excluding commands whose absence a test is exercising.  Appending
# /bin or /usr/bin is not sufficient on Linux because those directories often
# contain the very optional tools (for example psql or docker) under test.
make_command_path_without() {
    local destination="$1"
    shift
    local candidate command_name excluded_name excluded
    local command_names=(
        awk basename bash cat chmod cmp cp curl cut date dirname docker env
        git grep head jq kill ln lsof mkdir mktemp mv nohup od openssl pgrep
        ps psql python3 readlink realpath rg rm sed sh sha256sum shasum sleep
        sort stat tail tee timeout tr uname wc xargs cargo rustc sqlx k6
    )

    mkdir -p "$destination"
    for command_name in "${command_names[@]}"; do
        excluded=0
        for excluded_name in "$@"; do
            if [ "$command_name" = "$excluded_name" ]; then
                excluded=1
                break
            fi
        done
        [ "$excluded" -eq 0 ] || continue
        if [ ! -e "$destination/$command_name" ] && [ ! -L "$destination/$command_name" ]; then
            candidate="$(command -v "$command_name" 2>/dev/null || true)"
            if [ -n "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ]; then
                ln -s "$candidate" "$destination/$command_name"
            fi
        fi
    done
}

backup_repo_env_file() {
    local backup_path="$1"
    local repo_root="${FJCLOUD_TEST_REPO_ROOT:-$REPO_ROOT}"
    if [ -f "$repo_root/.env.local" ]; then
        cp "$repo_root/.env.local" "$backup_path"
        return 0
    fi
    return 1
}

restore_repo_env_file() {
    local backup_path="$1"
    local repo_root="${FJCLOUD_TEST_REPO_ROOT:-$REPO_ROOT}"
    if [ -f "$backup_path" ]; then
        cp "$backup_path" "$repo_root/.env.local"
    else
        rm -f "$repo_root/.env.local"
    fi
}

final_stdout_json_line() {
    local payload="$1"
    python3 - "$payload" <<'PY'
import json
import sys

lines = [
    raw_line.strip()
    for raw_line in sys.argv[1].splitlines()
    if raw_line.strip()
]
if not lines:
    raise SystemExit(1)

try:
    json.loads(lines[-1])
except json.JSONDecodeError:
    raise SystemExit(1)

json_line_count = 0
for line in lines:
    try:
        json.loads(line)
    except json.JSONDecodeError:
        continue
    json_line_count += 1

if json_line_count != 1:
    raise SystemExit(1)
print(lines[-1])
PY
}
