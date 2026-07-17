#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

SET_STATUS_SCRIPT="$REPO_ROOT/scripts/set_status.sh"

make_temp_dir() {
    mktemp -d "${TMPDIR:-/tmp}/fjcloud-set-status-test.XXXXXX"
}

write_fixture() {
    local wrangler_path="$1"
    cat > "$wrangler_path" <<'EOF'
name = "flapjack-cloud"
pages_build_output_dir = ".svelte-kit/cloudflare"

[vars]
API_BASE_URL = "https://api.flapjack.foo"
ENVIRONMENT = "staging"
SERVICE_STATUS = "operational"
SERVICE_STATUS_UPDATED = "2026-05-25T01:31:58Z"
SERVICE_STATUS_MESSAGE = "Old message"
UNRELATED_FLAG = "keep-top"

[env.production.vars]
API_BASE_URL = "https://api.flapjack.foo"
ENVIRONMENT = "production"
SERVICE_STATUS = "operational"
SERVICE_STATUS_UPDATED = "2026-05-25T01:31:58Z"
SERVICE_STATUS_MESSAGE = "Old message"
UNRELATED_FLAG = "keep-prod"

[env.preview.vars]
API_BASE_URL = "https://api.flapjack.foo"
ENVIRONMENT = "staging"
SERVICE_STATUS = "operational"
SERVICE_STATUS_UPDATED = "2026-05-25T01:31:58Z"
SERVICE_STATUS_MESSAGE = "Old message"
UNRELATED_FLAG = "keep-preview"
EOF
}

section_headers() {
    grep '^\[' "$1" | tr '\n' '|'
}

unique_updated_values() {
    awk -F'"' '/^SERVICE_STATUS_UPDATED = / { print $2 }' "$1" | sort -u
}

absolute_path() {
    local file_path="$1"
    printf '%s/%s' "$(cd "$(dirname "$file_path")" && pwd)" "$(basename "$file_path")"
}

assert_line_count() {
    local file_path="$1" pattern="$2" expected_count="$3" msg="$4"
    local actual_count
    actual_count="$(grep -Ec "$pattern" "$file_path" || true)"
    assert_eq "$actual_count" "$expected_count" "$msg"
}

test_rewrites_status_vars_in_all_sections() {
    local tmp_dir wrangler_path before_headers expected actual
    tmp_dir="$(make_temp_dir)"
    wrangler_path="$tmp_dir/wrangler.toml"
    write_fixture "$wrangler_path"
    before_headers="$(section_headers "$wrangler_path")"

    bash "$SET_STATUS_SCRIPT" \
        --wrangler "$wrangler_path" \
        --status degraded \
        --message 'Investigating elevated latency.' \
        --updated 2026-02-21T14:00:00Z >/dev/null 2>"$tmp_dir/stderr"

    actual="$(cat "$wrangler_path")"
    expected='name = "flapjack-cloud"
pages_build_output_dir = ".svelte-kit/cloudflare"

[vars]
API_BASE_URL = "https://api.flapjack.foo"
ENVIRONMENT = "staging"
SERVICE_STATUS = "degraded"
SERVICE_STATUS_UPDATED = "2026-02-21T14:00:00Z"
SERVICE_STATUS_MESSAGE = "Investigating elevated latency."
UNRELATED_FLAG = "keep-top"

[env.production.vars]
API_BASE_URL = "https://api.flapjack.foo"
ENVIRONMENT = "production"
SERVICE_STATUS = "degraded"
SERVICE_STATUS_UPDATED = "2026-02-21T14:00:00Z"
SERVICE_STATUS_MESSAGE = "Investigating elevated latency."
UNRELATED_FLAG = "keep-prod"

[env.preview.vars]
API_BASE_URL = "https://api.flapjack.foo"
ENVIRONMENT = "staging"
SERVICE_STATUS = "degraded"
SERVICE_STATUS_UPDATED = "2026-02-21T14:00:00Z"
SERVICE_STATUS_MESSAGE = "Investigating elevated latency."
UNRELATED_FLAG = "keep-preview"'

    assert_eq "$actual" "$expected" "rewrites only status vars across all Wrangler status sections"
    assert_eq "$(section_headers "$wrangler_path")" "$before_headers" "preserves Wrangler section order"
    assert_line_count "$wrangler_path" '^SERVICE_STATUS = "degraded"$' 3 "rewrites status in all sections"
    assert_line_count "$wrangler_path" '^SERVICE_STATUS_UPDATED = "2026-02-21T14:00:00Z"$' 3 "rewrites updated timestamp in all sections"
    assert_line_count "$wrangler_path" '^SERVICE_STATUS_MESSAGE = "Investigating elevated latency\."$' 3 "rewrites message in all sections"

    rm -rf "$tmp_dir"
}

test_rejects_unknown_status_without_mutating_fixture() {
    local tmp_dir wrangler_path before output exit_code
    tmp_dir="$(make_temp_dir)"
    wrangler_path="$tmp_dir/wrangler.toml"
    write_fixture "$wrangler_path"
    before="$(cat "$wrangler_path")"

    output="$(bash "$SET_STATUS_SCRIPT" --wrangler "$wrangler_path" --status paused 2>&1)"
    exit_code=$?

    assert_eq "$exit_code" "2" "rejects unknown status values"
    assert_contains "$output" "unknown status: paused" "reports rejected status value"
    assert_eq "$(cat "$wrangler_path")" "$before" "does not mutate fixture after status validation failure"

    rm -rf "$tmp_dir"
}

test_escapes_quoted_and_backslashed_messages() {
    local tmp_dir wrangler_path message_lines expected_lines
    tmp_dir="$(make_temp_dir)"
    wrangler_path="$tmp_dir/wrangler.toml"
    write_fixture "$wrangler_path"

    bash "$SET_STATUS_SCRIPT" \
        --wrangler "$wrangler_path" \
        --status degraded \
        --message $'Quote: "hi" and slash \\ end' \
        --updated 2026-02-21T14:00:00Z >/dev/null

    message_lines="$(grep '^SERVICE_STATUS_MESSAGE = ' "$wrangler_path")"
    expected_lines=$'SERVICE_STATUS_MESSAGE = "Quote: \\"hi\\" and slash \\\\ end"\nSERVICE_STATUS_MESSAGE = "Quote: \\"hi\\" and slash \\\\ end"\nSERVICE_STATUS_MESSAGE = "Quote: \\"hi\\" and slash \\\\ end"'

    assert_eq "$message_lines" "$expected_lines" "escapes quotes and backslashes in status messages"

    rm -rf "$tmp_dir"
}

test_rejects_invalid_updated_timestamp_without_mutating_fixture() {
    local tmp_dir wrangler_path before output exit_code
    tmp_dir="$(make_temp_dir)"
    wrangler_path="$tmp_dir/wrangler.toml"
    write_fixture "$wrangler_path"
    before="$(cat "$wrangler_path")"

    output="$(bash "$SET_STATUS_SCRIPT" --wrangler "$wrangler_path" --status degraded --updated not-a-timestamp 2>&1)"
    exit_code=$?

    assert_eq "$exit_code" "2" "rejects malformed --updated timestamps"
    assert_contains "$output" "invalid --updated timestamp: not-a-timestamp" "reports malformed timestamp clearly"
    assert_eq "$(cat "$wrangler_path")" "$before" "does not mutate fixture after malformed timestamp rejection"

    rm -rf "$tmp_dir"
}

test_rejects_nonexistent_updated_timestamp_without_mutating_fixture() {
    local tmp_dir wrangler_path before output exit_code
    tmp_dir="$(make_temp_dir)"
    wrangler_path="$tmp_dir/wrangler.toml"
    write_fixture "$wrangler_path"
    before="$(cat "$wrangler_path")"

    output="$(bash "$SET_STATUS_SCRIPT" --wrangler "$wrangler_path" --status degraded --updated 2026-02-30T14:00:00Z 2>&1)"
    exit_code=$?

    assert_eq "$exit_code" "2" "rejects nonexistent calendar timestamps"
    assert_contains "$output" "invalid --updated timestamp: 2026-02-30T14:00:00Z" "reports nonexistent timestamp clearly"
    assert_eq "$(cat "$wrangler_path")" "$before" "does not mutate fixture after nonexistent timestamp rejection"

    rm -rf "$tmp_dir"
}

test_omitted_updated_stamps_one_utc_value() {
    local tmp_dir wrangler_path unique_values timestamp exit_code
    tmp_dir="$(make_temp_dir)"
    wrangler_path="$tmp_dir/wrangler.toml"
    write_fixture "$wrangler_path"

    bash "$SET_STATUS_SCRIPT" --wrangler "$wrangler_path" --status outage --message "Investigating." >/dev/null
    exit_code=$?

    unique_values="$(unique_updated_values "$wrangler_path")"
    timestamp="$unique_values"

    assert_eq "$exit_code" "0" "auto-stamp status update command succeeds"
    assert_eq "$(echo "$unique_values" | wc -l | tr -d ' ')" "1" "auto-stamps one shared timestamp"
    assert_ne "$timestamp" "2026-05-25T01:31:58Z" "auto-stamp replaces the prior fixture timestamp"
    assert_line_count "$wrangler_path" '^SERVICE_STATUS = "outage"$' 3 "auto-stamp path still rewrites status in all sections"
    if [[ "$timestamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        pass "auto-stamped timestamp is UTC ISO-8601 seconds"
    else
        fail "auto-stamped timestamp is UTC ISO-8601 seconds (actual='$timestamp')"
    fi
    assert_line_count "$wrangler_path" "^SERVICE_STATUS_UPDATED = \"$timestamp\"$" 3 "writes same auto-stamped timestamp into all sections"

    rm -rf "$tmp_dir"
}

test_omitted_or_empty_message_clears_status_message() {
    local tmp_dir wrangler_path
    tmp_dir="$(make_temp_dir)"
    wrangler_path="$tmp_dir/wrangler.toml"
    write_fixture "$wrangler_path"

    bash "$SET_STATUS_SCRIPT" --wrangler "$wrangler_path" --status operational --updated 2026-02-21T14:00:00Z >/dev/null
    assert_line_count "$wrangler_path" '^SERVICE_STATUS_MESSAGE = ""$' 3 "omitted message clears status message"

    write_fixture "$wrangler_path"
    bash "$SET_STATUS_SCRIPT" --wrangler "$wrangler_path" --status operational --message "" --updated 2026-02-21T14:00:00Z >/dev/null
    assert_line_count "$wrangler_path" '^SERVICE_STATUS_MESSAGE = ""$' 3 "empty message clears status message"

    rm -rf "$tmp_dir"
}

test_fails_when_required_section_or_status_var_is_absent() {
    local tmp_dir missing_section missing_var section_output var_output
    tmp_dir="$(make_temp_dir)"
    missing_section="$tmp_dir/missing-section.toml"
    missing_var="$tmp_dir/missing-var.toml"
    write_fixture "$missing_section"
    write_fixture "$missing_var"
    awk '$0 != "[env.preview.vars]" { print }' "$missing_section" > "$tmp_dir/no-preview.toml"
    mv "$tmp_dir/no-preview.toml" "$missing_section"
    awk '$0 != "SERVICE_STATUS_MESSAGE = \"Old message\"" || seen++ > 0 { print }' "$missing_var" > "$tmp_dir/no-message.toml"
    mv "$tmp_dir/no-message.toml" "$missing_var"

    section_output="$(bash "$SET_STATUS_SCRIPT" --wrangler "$missing_section" --status degraded --updated 2026-02-21T14:00:00Z 2>&1)"
    assert_ne "$?" "0" "fails when a required Wrangler section is absent"
    assert_contains "$section_output" "missing required section: [env.preview.vars]" "reports missing section clearly"

    var_output="$(bash "$SET_STATUS_SCRIPT" --wrangler "$missing_var" --status degraded --updated 2026-02-21T14:00:00Z 2>&1)"
    assert_ne "$?" "0" "fails when a required status var is absent"
    assert_contains "$var_output" "missing required key in [vars]: SERVICE_STATUS_MESSAGE" "reports missing status var clearly"

    rm -rf "$tmp_dir"
}

test_publish_rewrites_fixture_before_deployment_handoff() {
    local tmp_dir wrangler_path expected_wrangler_path mock_dir publish_log
    tmp_dir="$(make_temp_dir)"
    wrangler_path="$tmp_dir/wrangler.toml"
    expected_wrangler_path="$(absolute_path "$wrangler_path")"
    mock_dir="$tmp_dir/bin"
    publish_log="$tmp_dir/publish.log"
    mkdir -p "$mock_dir"
    write_fixture "$wrangler_path"

    cat > "$mock_dir/mock_status_publish" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
wrangler_path="$1"
{
    echo "publish:$wrangler_path"
    grep '^SERVICE_STATUS = ' "$wrangler_path"
    grep '^SERVICE_STATUS_UPDATED = ' "$wrangler_path"
    grep '^SERVICE_STATUS_MESSAGE = ' "$wrangler_path"
} > "$FJCLOUD_SET_STATUS_PUBLISH_LOG"
EOF
    chmod +x "$mock_dir/mock_status_publish"

    PATH="$mock_dir:$PATH" FJCLOUD_SET_STATUS_PUBLISH_LOG="$publish_log" \
        bash "$SET_STATUS_SCRIPT" \
        --wrangler "$wrangler_path" \
        --status outage \
        --message 'Public update.' \
        --updated 2026-02-21T14:00:00Z \
        --publish \
        --publish-command mock_status_publish >/dev/null

    assert_contains "$(cat "$publish_log")" "publish:$expected_wrangler_path" "publish handoff receives the fixture path"
    assert_line_count "$publish_log" '^SERVICE_STATUS = "outage"$' 3 "publish handoff runs after status rewrite"
    assert_line_count "$publish_log" '^SERVICE_STATUS_UPDATED = "2026-02-21T14:00:00Z"$' 3 "publish handoff sees rewritten updated timestamp"
    assert_line_count "$publish_log" '^SERVICE_STATUS_MESSAGE = "Public update\."$' 3 "publish handoff sees rewritten message"

    rm -rf "$tmp_dir"
}

test_default_publish_rejects_custom_wrangler_without_publish_command() {
    local tmp_dir wrangler_path mock_dir publish_log output status
    tmp_dir="$(make_temp_dir)"
    wrangler_path="$tmp_dir/wrangler.toml"
    mock_dir="$tmp_dir/bin"
    publish_log="$tmp_dir/publish.log"
    mkdir -p "$mock_dir"
    write_fixture "$wrangler_path"

    cat > "$mock_dir/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'npm:%s\n' "$*" >> "$FJCLOUD_SET_STATUS_PUBLISH_LOG"
EOF
    chmod +x "$mock_dir/npm"

    cat > "$mock_dir/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'npx:%s\n' "$*" >> "$FJCLOUD_SET_STATUS_PUBLISH_LOG"
EOF
    chmod +x "$mock_dir/npx"

    output="$(PATH="$mock_dir:$PATH" FJCLOUD_SET_STATUS_PUBLISH_LOG="$publish_log" \
        bash "$SET_STATUS_SCRIPT" \
        --wrangler "$wrangler_path" \
        --status degraded \
        --message 'Publishing from fixture.' \
        --updated 2026-02-21T14:00:00Z \
        --publish 2>&1 >/dev/null)"
    status="$?"

    assert_eq "$status" "2" "default publish rejects custom Wrangler config paths"
    assert_contains "$output" "use --publish-command for custom Wrangler config paths" "default publish explains custom config handoff"

    rm -rf "$tmp_dir"
}

test_default_publish_uses_implicit_web_wrangler_config() {
    local tmp_dir wrangler_path backup_path mock_dir publish_log status command_log rewritten_status_count
    tmp_dir="$(make_temp_dir)"
    wrangler_path="$REPO_ROOT/web/wrangler.toml"
    backup_path="$tmp_dir/wrangler.toml.backup"
    mock_dir="$tmp_dir/bin"
    publish_log="$tmp_dir/publish.log"
    cp "$wrangler_path" "$backup_path"
    mkdir -p "$mock_dir"

    cat > "$mock_dir/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'npm:%s\n' "$*" >> "$FJCLOUD_SET_STATUS_PUBLISH_LOG"
EOF
    chmod +x "$mock_dir/npm"

    cat > "$mock_dir/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'npx:%s\n' "$*" >> "$FJCLOUD_SET_STATUS_PUBLISH_LOG"
EOF
    chmod +x "$mock_dir/npx"

    PATH="$mock_dir:$PATH" FJCLOUD_SET_STATUS_PUBLISH_LOG="$publish_log" \
        bash "$SET_STATUS_SCRIPT" \
        --status degraded \
        --message 'Publishing from fixture.' \
        --updated 2026-02-21T14:00:00Z \
        --publish >/dev/null
    status="$?"
    command_log="$(cat "$publish_log" 2>/dev/null || true)"
    rewritten_status_count="$(grep -Ec '^SERVICE_STATUS = "degraded"$' "$wrangler_path" || true)"
    cp "$backup_path" "$wrangler_path"

    assert_eq "$status" "0" "default publish succeeds with repository Wrangler config"
    assert_contains "$command_log" "npm:run build" "default publish builds the web bundle"
    assert_contains "$command_log" "npx:wrangler pages deploy .svelte-kit/cloudflare" "default publish delegates to Wrangler Pages"
    assert_not_contains "$command_log" "--config" "default publish relies on implicit web/wrangler.toml discovery"
    assert_eq "$rewritten_status_count" "3" "default publish rewrites repository Wrangler config before deployment handoff"

    rm -rf "$tmp_dir"
}

main() {
    echo "=== set_status_test.sh ==="
    echo ""

    test_rewrites_status_vars_in_all_sections
    test_rejects_unknown_status_without_mutating_fixture
    test_escapes_quoted_and_backslashed_messages
    test_rejects_invalid_updated_timestamp_without_mutating_fixture
    test_rejects_nonexistent_updated_timestamp_without_mutating_fixture
    test_omitted_updated_stamps_one_utc_value
    test_omitted_or_empty_message_clears_status_message
    test_fails_when_required_section_or_status_var_is_absent
    test_publish_rewrites_fixture_before_deployment_handoff
    test_default_publish_rejects_custom_wrangler_without_publish_command
    test_default_publish_uses_implicit_web_wrangler_config

    run_test_summary
}

main "$@"
