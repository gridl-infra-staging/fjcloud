#!/usr/bin/env bash
# Functions/globals below are invoked/read indirectly by sourced sweeper code.
# shellcheck disable=SC1091,SC2034,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=privacy_card_sweeper.sh
source "$SCRIPT_DIR/privacy_card_sweeper.sh"

# Shared stub response body for privacy_com_close_card stubs. Matches the
# Privacy.com close-card response shape captured in the Stage 1 contract probe.
STUB_CLOSE_CARD_BODY='{"token":"closed","state":"CLOSED","type":"MERCHANT_LOCKED","spend_limit":1000,"spend_limit_duration":"TRANSACTION","created":"2026-01-01T00:00:00Z","funding":{"token":"funding","state":"ENABLED","type":"DEPOSITORY_CHECKING","created":"2026-01-01T00:00:00Z"},"exp_month":"01","exp_year":"2030"}'

assert_equals() {
    local actual="$1"
    local expected="$2"
    local context="$3"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: ${context} expected=${expected} actual=${actual}" >&2
        exit 1
    fi
}

assert_json_value() {
    local json_body="$1"
    local key="$2"
    local expected="$3"
    local context="$4"

    local actual
    actual="$(python3 - "$json_body" "$key" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
key = sys.argv[2]
value = obj.get(key)
if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, list):
    print(json.dumps(value, separators=(",", ":")))
elif value is None:
    print("null")
else:
    print(value)
PY
)"
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: ${context} key=${key} expected=${expected} actual=${actual}" >&2
        exit 1
    fi
}

iso_from_epoch() {
    python3 - "$1" <<'PY'
from datetime import datetime, timezone
import sys
print(datetime.fromtimestamp(int(sys.argv[1]), tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

build_mixed_cards_fixture() {
    local now_epoch="$1"
    local stale_epoch=$((now_epoch - 7200))
    local fresh_epoch=$((now_epoch - 300))
    local stale_created
    local fresh_created
    stale_created="$(iso_from_epoch "$stale_epoch")"
    fresh_created="$(iso_from_epoch "$fresh_epoch")"

    cat <<JSON
{"data":[{"token":"stale-lane-token","state":"OPEN","memo":"${PRIVACY_LANE_MEMO_PREFIXES[0]} first","created":"${stale_created}"},{"token":"fresh-lane-token","state":"OPEN","memo":"${PRIVACY_LANE_MEMO_PREFIXES[1]} second","created":"${fresh_created}"},{"token":"operator-old-token","state":"OPEN","memo":"manual operator card","created":"${stale_created}"},{"token":"null-memo-token","state":"OPEN","memo":null,"created":"${stale_created}"},{"token":"closed-lane-token","state":"CLOSED","memo":"${PRIVACY_LANE_MEMO_PREFIXES[0]} closed","created":"${stale_created}"}],"page":1,"total_entries":5,"total_pages":1}
JSON
}

build_multi_page_fixture_one() {
    local now_epoch="$1"
    local stale_epoch=$((now_epoch - 8000))
    local stale_created
    stale_created="$(iso_from_epoch "$stale_epoch")"

    cat <<JSON
{"data":[{"token":"page1-stale","state":"OPEN","memo":"${PRIVACY_LANE_MEMO_PREFIXES[0]} one","created":"${stale_created}"}],"page":1,"total_entries":2,"total_pages":2}
JSON
}

build_multi_page_fixture_two() {
    local now_epoch="$1"
    local stale_epoch=$((now_epoch - 9000))
    local stale_created
    stale_created="$(iso_from_epoch "$stale_epoch")"

    cat <<JSON
{"data":[{"token":"page2-stale","state":"OPEN","memo":"${PRIVACY_LANE_MEMO_PREFIXES[1]} two","created":"${stale_created}"}],"page":2,"total_entries":2,"total_pages":2}
JSON
}

build_cutoff_page_fixture() {
    local created_epoch="$1"
    local created_iso
    created_iso="$(iso_from_epoch "$created_epoch")"

    cat <<JSON
{"data":[{"token":"cutoff-token","state":"OPEN","memo":"${PRIVACY_LANE_MEMO_PREFIXES[0]} cutoff","created":"${created_iso}"}],"page":1,"total_entries":1,"total_pages":1}
JSON
}

run_single_page_safety_scope_test() {
    local now_epoch
    now_epoch="$(date +%s)"
    local fixture_json
    fixture_json="$(build_mixed_cards_fixture "$now_epoch")"

    local close_calls=()

    privacy_com_require_env() {
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_ERROR_MESSAGE=""
        return 0
    }

    privacy_com_list_cards_raw_auth() {
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY="$fixture_json"
        return 0
    }

    privacy_com_close_card() {
        close_calls+=("$1")
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY="$STUB_CLOSE_CARD_BODY"
        return 0
    }

    local summary_file
    summary_file="$(mktemp)"
    PRIVACY_SWEEPER_MIN_AGE_SECONDS=3600 privacy_card_sweeper_main >"$summary_file"
    local summary
    summary="$(cat "$summary_file")"
    rm -f "$summary_file"

    assert_equals "${#close_calls[@]}" "1" "safety_close_count"
    assert_equals "${close_calls[0]}" "stale-lane-token" "safety_close_token"

    assert_json_value "$summary" "closed_tokens" '["stale-lane-token"]' "summary_closed_tokens"
    assert_json_value "$summary" "skipped_non_lane" "2" "summary_skipped_non_lane"
    assert_json_value "$summary" "skipped_fresh" "1" "summary_skipped_fresh"
    assert_json_value "$summary" "total_scanned" "5" "summary_total_scanned"
    assert_json_value "$summary" "pages_scanned" "1" "summary_pages_scanned"
}

run_multi_page_scan_test() {
    local now_epoch
    now_epoch="$(date +%s)"
    local page1_json
    local page2_json
    page1_json="$(build_multi_page_fixture_one "$now_epoch")"
    page2_json="$(build_multi_page_fixture_two "$now_epoch")"

    local close_calls=()
    local list_pages=()

    privacy_com_require_env() {
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_ERROR_MESSAGE=""
        return 0
    }

    privacy_com_list_cards_raw_auth() {
        local page="$1"
        list_pages+=("$page")
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        if [ "$page" = "1" ]; then
            PRIVACY_CLIENT_BODY="$page1_json"
        elif [ "$page" = "2" ]; then
            PRIVACY_CLIENT_BODY="$page2_json"
        else
            echo "unexpected page=$page" >&2
            return 1
        fi
        return 0
    }

    privacy_com_close_card() {
        close_calls+=("$1")
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY="$STUB_CLOSE_CARD_BODY"
        return 0
    }

    local summary_file
    summary_file="$(mktemp)"
    PRIVACY_SWEEPER_MIN_AGE_SECONDS=3600 privacy_card_sweeper_main >"$summary_file"
    local summary
    summary="$(cat "$summary_file")"
    rm -f "$summary_file"

    assert_equals "${list_pages[*]}" "1 2" "pagination_scans_all_pages"
    assert_equals "${#close_calls[@]}" "2" "pagination_close_count"
    assert_equals "${close_calls[0]}" "page1-stale" "pagination_close_token_one"
    assert_equals "${close_calls[1]}" "page2-stale" "pagination_close_token_two"

    assert_json_value "$summary" "pages_scanned" "2" "pagination_summary_pages"
    assert_json_value "$summary" "total_scanned" "2" "pagination_summary_total_scanned"
    assert_json_value "$summary" "closed_tokens" '["page1-stale","page2-stale"]' "pagination_summary_closed_tokens"
}

run_dry_run_test() {
    local now_epoch
    now_epoch="$(date +%s)"
    local fixture_json
    fixture_json="$(build_mixed_cards_fixture "$now_epoch")"

    local close_calls=()

    privacy_com_require_env() {
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_ERROR_MESSAGE=""
        return 0
    }

    privacy_com_list_cards_raw_auth() {
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY="$fixture_json"
        return 0
    }

    privacy_com_close_card() {
        close_calls+=("$1")
        return 0
    }

    local summary_file
    summary_file="$(mktemp)"
    PRIVACY_SWEEPER_MIN_AGE_SECONDS=3600 privacy_card_sweeper_main --dry-run >"$summary_file"
    local summary
    summary="$(cat "$summary_file")"
    rm -f "$summary_file"

    assert_equals "${#close_calls[@]}" "0" "dry_run_skips_close_calls"
    assert_json_value "$summary" "dry_run" "true" "dry_run_flag_true"
    assert_json_value "$summary" "candidate_tokens" '["stale-lane-token"]' "dry_run_candidate_tokens"
    assert_json_value "$summary" "closed_tokens" '[]' "dry_run_closed_tokens"
}

run_fixed_cutoff_test() {
    local sweep_start_epoch=0
    local now_epoch
    now_epoch="$(date +%s)"
    local cutoff_created_epoch=$((now_epoch - 7200))
    local fixture_json
    fixture_json="$(build_cutoff_page_fixture "$cutoff_created_epoch")"

    local summary
    summary="$(privacy_card_sweeper_evaluate_page "$fixture_json" "3600" "$sweep_start_epoch" "${PRIVACY_LANE_MEMO_PREFIXES[@]}")"

    assert_json_value "$summary" "candidate_tokens" '[]' "fixed_cutoff_excludes_not_yet_stale"
    assert_json_value "$summary" "skipped_fresh" "1" "fixed_cutoff_counts_fresh"
}

run_cross_page_cutoff_stability_test() {
    local fixed_epoch=1000000
    local min_age=3600
    local stale_created_epoch=$((fixed_epoch - min_age - 1))
    local stale_created_iso
    stale_created_iso="$(iso_from_epoch "$stale_created_epoch")"

    local page1_json page2_json
    page1_json='{"data":[{"token":"p1-boundary","state":"OPEN","memo":"'"${PRIVACY_LANE_MEMO_PREFIXES[0]}"' p1","created":"'"${stale_created_iso}"'"}],"page":1,"total_entries":2,"total_pages":2}'
    page2_json='{"data":[{"token":"p2-boundary","state":"OPEN","memo":"'"${PRIVACY_LANE_MEMO_PREFIXES[1]}"' p2","created":"'"${stale_created_iso}"'"}],"page":2,"total_entries":2,"total_pages":2}'

    local date_counter_file
    date_counter_file="$(mktemp)"
    echo "0" > "$date_counter_file"

    # First date +%s returns fixed_epoch; subsequent calls return 0.
    # Correct code (one capture) → both pages use fixed_epoch → both cards stale.
    # Buggy code (date per page) → page 2 gets epoch 0 → card age negative → skipped.
    date() {
        if [[ "${1:-}" == "+%s" ]]; then
            local count
            count="$(cat "$date_counter_file")"
            echo "$((count + 1))" > "$date_counter_file"
            if [ "$count" -eq 0 ]; then
                echo "$fixed_epoch"
            else
                echo "0"
            fi
        else
            command date "$@"
        fi
    }

    privacy_com_require_env() {
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_ERROR_MESSAGE=""
        return 0
    }

    privacy_com_list_cards_raw_auth() {
        local page="$1"
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        if [ "$page" = "1" ]; then
            PRIVACY_CLIENT_BODY="$page1_json"
        elif [ "$page" = "2" ]; then
            PRIVACY_CLIENT_BODY="$page2_json"
        fi
        return 0
    }

    local close_calls=()
    privacy_com_close_card() {
        close_calls+=("$1")
        PRIVACY_CLIENT_EXIT_CLASS="ok"
        PRIVACY_CLIENT_HTTP_CODE="200"
        PRIVACY_CLIENT_BODY="$STUB_CLOSE_CARD_BODY"
        return 0
    }

    local summary_file
    summary_file="$(mktemp)"
    PRIVACY_SWEEPER_MIN_AGE_SECONDS=$min_age privacy_card_sweeper_main >"$summary_file"
    local summary
    summary="$(cat "$summary_file")"
    rm -f "$summary_file"

    unset -f date
    rm -f "$date_counter_file"

    assert_equals "${#close_calls[@]}" "2" "cross_page_cutoff_close_count"
    assert_equals "${close_calls[0]}" "p1-boundary" "cross_page_cutoff_token_1"
    assert_equals "${close_calls[1]}" "p2-boundary" "cross_page_cutoff_token_2"
    assert_json_value "$summary" "closed_tokens" '["p1-boundary","p2-boundary"]' "cross_page_cutoff_closed"
    assert_json_value "$summary" "pages_scanned" "2" "cross_page_cutoff_pages"
}

run_single_page_safety_scope_test
run_multi_page_scan_test
run_dry_run_test
run_fixed_cutoff_test
run_cross_page_cutoff_stability_test

echo "PASS: privacy_card_sweeper unit tests succeeded"
