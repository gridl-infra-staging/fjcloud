#!/usr/bin/env bash
# Tests for scripts/local_play.sh: one-command launcher contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

LOCAL_PLAY_SCRIPT="$REPO_ROOT/scripts/local_play.sh"

script_line_number() {
    local pattern="$1"
    awk -v pattern="$pattern" 'index($0, pattern) { print NR; exit }' "$LOCAL_PLAY_SCRIPT"
}

test_help_mentions_one_command_and_reset_modes() {
    local output
    output="$(bash "$LOCAL_PLAY_SCRIPT" --help)"

    assert_contains "$output" "scripts/local_play.sh" "help should name the one-command launcher"
    assert_contains "$output" "--clean" "help should document the default clean reset option"
    assert_contains "$output" "--keep-data" "help should expose the keep-data option"
}

test_default_clean_resets_tracked_stack_before_starting_demo() {
    local down_line demo_line
    down_line="$(script_line_number '"$SCRIPT_DIR/local-dev-down.sh" --clean')"
    demo_line="$(script_line_number '"$SCRIPT_DIR/local_demo.sh"')"

    if [ -n "$down_line" ] && [ -n "$demo_line" ] && [ "$down_line" -lt "$demo_line" ]; then
        pass "default launch clean-resets this repo's tracked local stack before starting the demo"
    else
        fail "default launch order is wrong (down=${down_line:-missing} demo=${demo_line:-missing})"
    fi
}

test_clean_and_keep_data_modes_call_expected_teardown() {
    local script_text
    script_text="$(cat "$LOCAL_PLAY_SCRIPT")"

    assert_contains "$script_text" '"$SCRIPT_DIR/local-dev-down.sh" --clean' \
        "--clean should reset this repo's local Docker volumes before launch"
    assert_contains "$script_text" "--keep-data)" \
        "--keep-data should be an explicit opt-in mode"
    assert_contains "$script_text" '"$SCRIPT_DIR/local_demo.sh"' \
        "reset modes should still start the normal local demo after teardown"
}

test_wrapper_chooses_mailpit_ports_before_launch() {
    local script_text
    script_text="$(cat "$LOCAL_PLAY_SCRIPT")"

    assert_contains "$script_text" "choose_available_port 1025 100 20" \
        "wrapper should avoid occupied default SMTP ports"
    assert_contains "$script_text" "choose_available_port 8025 100 20" \
        "wrapper should avoid occupied default Mailpit UI ports"
    assert_contains "$script_text" 'MAILPIT_API_URL="http://localhost:${LOCAL_MAILPIT_UI_PORT}"' \
        "wrapper should export the Mailpit API URL that matches the chosen UI port"
}

test_wrapper_chooses_database_port_before_launch() {
    local script_text
    script_text="$(cat "$LOCAL_PLAY_SCRIPT")"

    assert_contains "$script_text" "choose_available_port 5432 100 20" \
        "wrapper should avoid occupied default Postgres ports"
    assert_contains "$script_text" 'DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:${LOCAL_DB_PORT}/fjcloud_dev"' \
        "wrapper should export a DATABASE_URL that matches the chosen local DB port"
    assert_contains "$script_text" "export LOCAL_DB_PORT" \
        "wrapper should pass the chosen DB port to docker compose"
}

test_wrapper_does_not_use_broad_process_kills() {
    local script_text
    script_text="$(cat "$LOCAL_PLAY_SCRIPT")"

    assert_not_contains "$script_text" "killall" "wrapper should not use killall"
    assert_not_contains "$script_text" "pkill" "wrapper should not use pkill"
    assert_not_contains "$script_text" "xargs kill" "wrapper should not use grep-derived bulk kill"
}

test_unknown_argument_exits_two() {
    local exit_code=0
    bash "$LOCAL_PLAY_SCRIPT" --nope >/dev/null 2>&1 || exit_code=$?

    assert_eq "$exit_code" "2" "unknown argument should exit with usage error"
}

test_help_mentions_one_command_and_reset_modes
test_default_clean_resets_tracked_stack_before_starting_demo
test_clean_and_keep_data_modes_call_expected_teardown
test_wrapper_chooses_mailpit_ports_before_launch
test_wrapper_chooses_database_port_before_launch
test_wrapper_does_not_use_broad_process_kills
test_unknown_argument_exits_two

run_test_summary
