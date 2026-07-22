#!/usr/bin/env bash
# RED guard for the local-ci rust-lint preflight shared-state race.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"
# shellcheck source=lib/local_dev_test_state.sh
source "$SCRIPT_DIR/lib/local_dev_test_state.sh"

REPO_ENV_PATH="$REPO_ROOT/.env.local"
WEB_ENV_PATH="$REPO_ROOT/web/.env.local"
VITE_PATH="$REPO_ROOT/web/node_modules/.bin/vite"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fjcloud-local-ci-env-local-isolation.XXXXXX")"
REPO_ENV_BACKUP_TOKEN=""
WEB_ENV_BACKUP_TOKEN=""
VITE_BACKUP_TOKEN=""
READER_PID=""
STOP_READER_FILE="$TMP_DIR/stop-reader"
BAD_READS_FILE="$TMP_DIR/bad-reads.log"
OFFENDER_OUTPUT="$TMP_DIR/e2e-preflight.out"
EXPECTED_REPO_ENV="$TMP_DIR/expected-repo.env.local"
EXPECTED_WEB_ENV="$TMP_DIR/expected-web.env.local"
EXPECTED_VITE="$TMP_DIR/expected-vite"

cleanup() {
    local rc=$?
    if [ -n "${READER_PID:-}" ]; then
        touch "$STOP_READER_FILE"
        wait "$READER_PID" 2>/dev/null || true
        READER_PID=""
    fi
    restore_repo_path "$REPO_ENV_PATH" "${REPO_ENV_BACKUP_TOKEN:-}"
    restore_repo_path "$WEB_ENV_PATH" "${WEB_ENV_BACKUP_TOKEN:-}"
    restore_repo_path "$VITE_PATH" "${VITE_BACKUP_TOKEN:-}"
    rm -rf "$TMP_DIR"
    exit "$rc"
}
trap cleanup EXIT

checksum_file() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        shasum -a 256 "$path" 2>/dev/null | awk '{print $1}'
    else
        printf '<missing>'
    fi
}

snapshot_path() {
    local label="$1"
    local path="$2"

    printf 'label=%s\n' "$label"
    printf 'path=%s\n' "$path"
    if [ -e "$path" ] || [ -L "$path" ]; then
        printf 'exists=1\n'
        printf 'inode=%s\n' "$(ls -id "$path" | awk '{print $1}')"
        python3 - "$path" <<'PY'
import os
import sys

st = os.lstat(sys.argv[1])
print(f"mtime_ns={st.st_mtime_ns}")
print(f"size={st.st_size}")
print(f"mode={st.st_mode:o}")
PY
        printf 'checksum=%s\n' "$(checksum_file "$path")"
        if [ -L "$path" ]; then
            printf 'symlink_target=%s\n' "$(readlink "$path")"
        else
            printf 'symlink_target=\n'
        fi
        if [ -x "$path" ]; then
            printf 'executable=1\n'
        else
            printf 'executable=0\n'
        fi
    else
        printf 'exists=0\n'
        printf 'inode=<missing>\n'
        printf 'mtime_ns=<missing>\n'
        printf 'size=<missing>\n'
        printf 'mode=<missing>\n'
        printf 'checksum=<missing>\n'
        printf 'symlink_target=<missing>\n'
        printf 'executable=0\n'
    fi
}

snapshot_field() {
    local snapshot_file="$1"
    local field="$2"
    awk -F= -v field="$field" '$1 == field { print substr($0, index($0, "=") + 1); exit }' "$snapshot_file"
}

print_snapshot_changes() {
    local label="$1"
    local before_file="$2"
    local after_file="$3"
    local field before after

    for field in exists inode mtime_ns checksum symlink_target executable; do
        before="$(snapshot_field "$before_file" "$field")"
        after="$(snapshot_field "$after_file" "$field")"
        if [ "$before" != "$after" ]; then
            printf '%s changed %s: before=%s after=%s\n' "$label" "$field" "$before" "$after"
        fi
    done
}

write_expected_surfaces() {
    cat > "$EXPECTED_REPO_ENV" <<'EOF'
FJCLOUD_LOCAL_CI_ISOLATION_SENTINEL=repo-env
ADMIN_KEY=repo-env-sentinel-admin-key
SEED_USER_EMAIL=repo-env-sentinel@example.com
SEED_USER_PASSWORD=repo-env-sentinel-password
EOF

    cat > "$EXPECTED_WEB_ENV" <<'EOF'
FJCLOUD_LOCAL_CI_ISOLATION_SENTINEL=web-env
PUBLIC_FJCLOUD_ISOLATION_SENTINEL=web-env-sentinel
EOF

    cat > "$EXPECTED_VITE" <<'EOF'
#!/usr/bin/env bash
printf 'fjcloud-local-ci-isolation-vite-sentinel\n'
EOF
    chmod +x "$EXPECTED_VITE"

    cp "$EXPECTED_REPO_ENV" "$REPO_ENV_PATH"
    mkdir -p "$(dirname "$WEB_ENV_PATH")" "$(dirname "$VITE_PATH")"
    cp "$EXPECTED_WEB_ENV" "$WEB_ENV_PATH"
    cp "$EXPECTED_VITE" "$VITE_PATH"
    chmod +x "$VITE_PATH"
}

append_bad_read() {
    local label="$1"
    local reason="$2"
    printf '%s %s %s\n' "$(date +%s)" "$label" "$reason" >> "$BAD_READS_FILE"
}

check_expected_path() {
    local label="$1"
    local path="$2"
    local expected_file="$3"
    local require_executable="${4:-0}"

    if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        append_bad_read "$label" "missing"
        return
    fi
    if ! cmp -s "$expected_file" "$path"; then
        append_bad_read "$label" "foreign checksum=$(checksum_file "$path") expected=$(checksum_file "$expected_file")"
    fi
    if [ "$require_executable" -eq 1 ] && [ ! -x "$path" ]; then
        append_bad_read "$label" "not-executable"
    fi
    if [ "$label" = "vite_shim" ] && [ -L "$path" ]; then
        append_bad_read "$label" "foreign-symlink-target=$(readlink "$path")"
    fi
}

reader_loop() {
    while [ ! -e "$STOP_READER_FILE" ]; do
        check_expected_path "repo_env" "$REPO_ENV_PATH" "$EXPECTED_REPO_ENV" 0
        check_expected_path "web_env" "$WEB_ENV_PATH" "$EXPECTED_WEB_ENV" 0
        check_expected_path "vite_shim" "$VITE_PATH" "$EXPECTED_VITE" 1
        sleep 0.01
    done
}

test_e2e_preflight_mutates_real_checkout_env_state() {
    REPO_ENV_BACKUP_TOKEN="$(backup_repo_path "$REPO_ENV_PATH" "$TMP_DIR/repo.env.local.backup")"
    WEB_ENV_BACKUP_TOKEN="$(backup_repo_path "$WEB_ENV_PATH" "$TMP_DIR/web.env.local.backup")"
    VITE_BACKUP_TOKEN="$(backup_repo_path "$VITE_PATH" "$TMP_DIR/vite.backup")"

    write_expected_surfaces

    snapshot_path "repo_env" "$REPO_ENV_PATH" > "$TMP_DIR/repo-env.before"
    snapshot_path "web_env" "$WEB_ENV_PATH" > "$TMP_DIR/web-env.before"
    snapshot_path "vite_shim" "$VITE_PATH" > "$TMP_DIR/vite.before"

    : > "$BAD_READS_FILE"
    reader_loop &
    READER_PID=$!

    local offender_status=0
    bash "$REPO_ROOT/scripts/tests/e2e_preflight_test.sh" > "$OFFENDER_OUTPUT" 2>&1 || offender_status=$?

    touch "$STOP_READER_FILE"
    wait "$READER_PID" 2>/dev/null || true
    READER_PID=""

    snapshot_path "repo_env" "$REPO_ENV_PATH" > "$TMP_DIR/repo-env.after"
    snapshot_path "web_env" "$WEB_ENV_PATH" > "$TMP_DIR/web-env.after"
    snapshot_path "vite_shim" "$VITE_PATH" > "$TMP_DIR/vite.after"

    local bad_reads
    bad_reads="$(wc -l < "$BAD_READS_FILE" | tr -d ' ')"

    local mutation_count=0
    local changed_labels=""
    if ! cmp -s "$TMP_DIR/repo-env.before" "$TMP_DIR/repo-env.after"; then
        mutation_count=$((mutation_count + 1))
        changed_labels="${changed_labels} repo_env"
    fi
    if ! cmp -s "$TMP_DIR/web-env.before" "$TMP_DIR/web-env.after"; then
        mutation_count=$((mutation_count + 1))
        changed_labels="${changed_labels} web_env"
    fi
    if ! cmp -s "$TMP_DIR/vite.before" "$TMP_DIR/vite.after"; then
        mutation_count=$((mutation_count + 1))
        changed_labels="${changed_labels} vite_shim"
    fi

    if [ "$mutation_count" -gt 0 ] || [ "$bad_reads" -gt 0 ]; then
        {
            printf 'local_ci_env_local_isolation_test observed shared-state mutation\n'
            printf 'offender_exit_status=%s\n' "$offender_status"
            printf 'bad_reads=%s\n' "$bad_reads"
            printf 'changed_paths=%s\n' "${changed_labels# }"
            printf '\n-- changed fields --\n'
            print_snapshot_changes "repo_env" "$TMP_DIR/repo-env.before" "$TMP_DIR/repo-env.after"
            print_snapshot_changes "web_env" "$TMP_DIR/web-env.before" "$TMP_DIR/web-env.after"
            print_snapshot_changes "vite_shim changed Vite shim identity" "$TMP_DIR/vite.before" "$TMP_DIR/vite.after"
            printf '\n-- repo_env before --\n'
            cat "$TMP_DIR/repo-env.before"
            printf '\n-- repo_env after --\n'
            cat "$TMP_DIR/repo-env.after"
            printf '\n-- web_env before --\n'
            cat "$TMP_DIR/web-env.before"
            printf '\n-- web_env after --\n'
            cat "$TMP_DIR/web-env.after"
            printf '\n-- vite_shim before --\n'
            cat "$TMP_DIR/vite.before"
            printf '\n-- vite_shim after --\n'
            cat "$TMP_DIR/vite.after"
            printf '\n-- first bad read evidence --\n'
            sed -n '1,40p' "$BAD_READS_FILE"
            if [ "$offender_status" -ne 0 ]; then
                printf '\n-- offender output tail --\n'
                tail -40 "$OFFENDER_OUTPUT"
            fi
        } >&2
        fail "e2e_preflight_test.sh mutates checkout env/Vite shared state (bad_reads=$bad_reads changed_paths=${changed_labels# })"
        return
    fi

    if [ "$offender_status" -ne 0 ]; then
        {
            printf 'local_ci_env_local_isolation_test offender failed before completing cleanly\n'
            printf 'offender_exit_status=%s\n' "$offender_status"
            printf '\n-- offender output tail --\n'
            tail -40 "$OFFENDER_OUTPUT"
        } >&2
        fail "e2e_preflight_test.sh exited $offender_status while env-local isolation guard was exercising it"
        return
    fi

    pass "e2e_preflight_test.sh preserved checkout env/Vite shared state (offender_exit_status=$offender_status)"
}

echo "=== local-ci env local isolation tests ==="
test_e2e_preflight_mutates_real_checkout_env_state
run_test_summary
