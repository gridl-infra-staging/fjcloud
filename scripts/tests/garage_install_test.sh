#!/usr/bin/env bash
# Tests for ops/garage/scripts/install-garage.sh helper functions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

# shellcheck source=../../ops/garage/scripts/install-garage.sh
source "$REPO_ROOT/ops/garage/scripts/install-garage.sh"

test_ensure_garage_account_creates_group_and_user() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    cat > "$tmp_dir/getent" <<'MOCK'
#!/usr/bin/env bash
exit 2
MOCK

    cat > "$tmp_dir/id" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK

    cat > "$tmp_dir/groupadd" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$MOCK_LOG"
exit 0
MOCK

    cat > "$tmp_dir/useradd" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$MOCK_LOG"
exit 0
MOCK

    cat > "$tmp_dir/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x "$tmp_dir/getent" "$tmp_dir/id" "$tmp_dir/groupadd" "$tmp_dir/useradd" "$tmp_dir/logger"

    : > "$tmp_dir/group-file"
    : > "$tmp_dir/mock.log"

    GARAGE_USER="garage"
    GARAGE_GROUP="garage"
    GROUP_FILE="$tmp_dir/group-file"
    PATH="$tmp_dir:$PATH" MOCK_LOG="$tmp_dir/mock.log" ensure_garage_account

    local log_output
    log_output="$(cat "$tmp_dir/mock.log")"
    assert_contains "$log_output" "--system garage" "ensure_garage_account should create the garage group"
    assert_contains "$log_output" "--gid garage --shell /usr/sbin/nologin --home-dir /var/lib/garage garage" \
        "ensure_garage_account should create the garage user in the garage group"
}

test_ensure_garage_account_rejects_wrong_primary_group() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    cat > "$tmp_dir/getent" <<'MOCK'
#!/usr/bin/env bash
echo 'garage:x:999:'
exit 0
MOCK

    cat > "$tmp_dir/id" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "-gn" ]]; then
  echo "wronggroup"
  exit 0
fi
exit 0
MOCK

    cat > "$tmp_dir/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x "$tmp_dir/getent" "$tmp_dir/id" "$tmp_dir/logger"

    GARAGE_USER="garage"
    GARAGE_GROUP="garage"
    GROUP_FILE="$tmp_dir/group-file"

    local output exit_code=0
    output="$(PATH="$tmp_dir:$PATH" ensure_garage_account 2>&1)" || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        pass "ensure_garage_account returns non-zero when an existing user has the wrong group"
    else
        fail "ensure_garage_account should fail when the existing user's primary group is wrong"
    fi

    assert_contains "$output" "expected garage" "ensure_garage_account should explain the expected primary group"
}

test_install_config_template_keeps_final_path_unwritten_until_permissions_are_applied() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    mkdir -p "$tmp_dir/ops" "$tmp_dir/conf"
    cat > "$tmp_dir/ops/garage.toml.template" <<'EOF'
metadata_dir = "%%GARAGE_META_DIR%%"
data_dir = "%%GARAGE_DATA_DIR%%"
rpc_secret = "%%GARAGE_RPC_SECRET%%"

[admin]
admin_token = "%%GARAGE_ADMIN_TOKEN%%"
EOF

    cat > "$tmp_dir/openssl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$2" == "32" && "$1" == "rand" && "$3" == "" ]]; then
  :
fi
if [[ "$1" == "rand" && "$2" == "-hex" ]]; then
  printf 'rpc-secret'
  exit 0
fi
if [[ "$1" == "rand" && "$2" == "-base64" ]]; then
  printf 'admin-token'
  exit 0
fi
exit 1
MOCK

    cat > "$tmp_dir/sed" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "-e" ]]; then
  exec /usr/bin/sed "$@"
fi

expr="$1"
target="$2"
if [[ -z "${OBS_FILE:-}" ]]; then
  echo "OBS_FILE not set" >&2
  exit 1
fi
if [[ -z "${FINAL_TOML:-}" ]]; then
  echo "FINAL_TOML not set" >&2
  exit 1
fi
if [[ "$target" == "$FINAL_TOML" && -e "$FINAL_TOML" ]]; then
  printf 'present' > "$OBS_FILE"
else
  printf 'missing' > "$OBS_FILE"
fi
IFS='|' read -r _ pattern replacement _ <<< "$expr"
content="$(cat "$target")"
content="${content//"$pattern"/$replacement}"
printf '%s' "$content" > "$target"
MOCK

    cat > "$tmp_dir/chown" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "$tmp_dir/chmod" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "$tmp_dir/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x "$tmp_dir/openssl" "$tmp_dir/sed" "$tmp_dir/chown" "$tmp_dir/chmod" "$tmp_dir/logger"

    OPS_DIR="$tmp_dir/ops"
    CONF_DIR="$tmp_dir/conf"
    META_DIR="/srv/garage/meta"
    DATA_DIR="/srv/garage/data"
    GARAGE_GROUP="garage"

    PATH="$tmp_dir:$PATH" OBS_FILE="$tmp_dir/observation" FINAL_TOML="$tmp_dir/conf/garage.toml" install_config_template >/dev/null

    local observation
    observation="$(cat "$tmp_dir/observation")"
    assert_eq "$observation" "missing" "install_config_template should keep garage.toml off the final path until restrictive permissions are ready"
}

main() {
    echo "=== garage install tests ==="
    echo ""

    test_ensure_garage_account_creates_group_and_user
    test_ensure_garage_account_rejects_wrong_primary_group
    test_install_config_template_keeps_final_path_unwritten_until_permissions_are_applied

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
