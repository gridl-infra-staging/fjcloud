#!/usr/bin/env bash
# Shared helpers for local-dev shell tests that temporarily replace repo-local state.

# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
# TODO: Document backup_repo_path.
backup_repo_path() {
    local original_path="$1"
    local backup_path="$2"

    if [ ! -e "$original_path" ]; then
        # Signal that the original didn't exist so restore_repo_path can
        # clean up whatever the test creates without confusing this with
        # the leaked-RETURN-trap case (empty string after caller clears).
        printf '__NO_ORIGINAL__\n'
        return 0
    fi

    rm -rf "$backup_path"
    mv "$original_path" "$backup_path"
    printf '%s\n' "$backup_path"
}

restore_repo_path() {
    local original_path="$1"
    local backup_path="${2:-}"

    # Only delete the original when the backup exists and can be restored.
    # This guards against leaked RETURN traps (bash macOS behavior) calling
    # restore after the backup temp dir was already cleaned up.
    if [ "$backup_path" = "__NO_ORIGINAL__" ]; then
        # Original didn't exist before the test — remove whatever it created.
        rm -rf "$original_path"
    elif [ -n "$backup_path" ] && [ -e "$backup_path" ]; then
        rm -rf "$original_path"
        mv "$backup_path" "$original_path"
    fi
    # Otherwise (empty or non-empty-but-missing) do nothing:
    # - Empty string means the caller already cleared after a successful
    #   restore and a leaked RETURN trap (macOS bash) is re-firing.
    # - Non-empty but file missing means backup was already consumed.
}

write_local_dev_env_file() {
    local env_file="$1"
    local database_url="$2"

    cat > "$env_file" <<EOF
DATABASE_URL=$database_url
JWT_SECRET=test-jwt-secret
ADMIN_KEY=test-admin-key
LISTEN_ADDR=0.0.0.0:3001
RUST_LOG=info,api=debug
FLAPJACK_URL=http://localhost:7700
EOF
}
