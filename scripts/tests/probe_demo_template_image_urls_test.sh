#!/usr/bin/env bash
# Hermetic tests for scripts/probe_demo_template_image_urls.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/probe_demo_template_image_urls.sh"

source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

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

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0

write_fixture_pair() {
    local tmp_dir="$1"
    local movies_payload="$2"
    local products_payload="$3"
    printf '%s\n' "$movies_payload" > "$tmp_dir/movies.json"
    printf '%s\n' "$products_payload" > "$tmp_dir/products.json"
}

write_curl_stub() {
    local tmp_dir="$1"
    mkdir -p "$tmp_dir/bin"
    cat > "$tmp_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_CALL_LOG:?missing CURL_CALL_LOG}"
exit 0
MOCK
    chmod +x "$tmp_dir/bin/curl"
}

run_probe() {
    local tmp_dir="$1"
    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        FJCLOUD_DEMO_MOVIES_JSON="$tmp_dir/movies.json" \
        FJCLOUD_DEMO_PRODUCTS_JSON="$tmp_dir/products.json" \
        CURL_CALL_LOG="$tmp_dir/curl_calls.log" \
        bash "$TARGET_SCRIPT" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

test_deduplicates_and_uses_exact_curl_flags() {
    local tmp_dir calls
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    write_curl_stub "$tmp_dir"
    : > "$tmp_dir/curl_calls.log"
    write_fixture_pair "$tmp_dir" \
        '[{"objectID":"m1","image":"https://cdn.example.test/shared.jpg"},{"objectID":"m2","image":"https://cdn.example.test/shared.jpg"}]' \
        '[{"objectID":"p1","image":"https://cdn.example.test/product.jpg"},{"objectID":"p2","image":""}]'

    run_probe "$tmp_dir"
    calls="$(cat "$tmp_dir/curl_calls.log")"

    assert_eq "$RUN_EXIT_CODE" "0" "valid fixture should pass"
    assert_eq "$(wc -l < "$tmp_dir/curl_calls.log" | tr -d ' ')" "2" "duplicate URLs should be fetched once"
    assert_contains "$calls" "-fsSL --retry 2 --max-time 20 --range 0-0 https://cdn.example.test/shared.jpg" "shared URL should use exact GET curl flags"
    assert_contains "$calls" "-fsSL --retry 2 --max-time 20 --range 0-0 https://cdn.example.test/product.jpg" "product URL should use exact GET curl flags"
    assert_contains "$RUN_STDOUT" "Checked 2 unique demo template image URLs." "success output should report unique count"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_rejects_non_https_before_curl() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    write_curl_stub "$tmp_dir"
    : > "$tmp_dir/curl_calls.log"
    write_fixture_pair "$tmp_dir" \
        '[{"objectID":"m1","image":"http://cdn.example.test/movie.jpg"}]' \
        '[]'

    run_probe "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "non-HTTPS URL should fail"
    assert_contains "$RUN_STDERR" "image must be an absolute HTTPS URL" "non-HTTPS failure should name URL contract"
    assert_eq "$(wc -l < "$tmp_dir/curl_calls.log" | tr -d ' ')" "0" "non-HTTPS rejection should happen before curl"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_rejects_placeholder_before_curl() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    write_curl_stub "$tmp_dir"
    : > "$tmp_dir/curl_calls.log"
    write_fixture_pair "$tmp_dir" \
        '[{"objectID":"m1","image":"https://image.tmdb.org/placeholder/movie.jpg"}]' \
        '[{"objectID":"p1","image":"https://cdn.example.test/product.jpg"}]'

    run_probe "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "placeholder URL should fail"
    assert_contains "$RUN_STDERR" "image uses placeholder/example URL" "placeholder failure should name placeholder contract"
    assert_eq "$(wc -l < "$tmp_dir/curl_calls.log" | tr -d ' ')" "0" "placeholder rejection should happen before curl"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_rejects_example_owner_before_curl() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    write_curl_stub "$tmp_dir"
    : > "$tmp_dir/curl_calls.log"
    write_fixture_pair "$tmp_dir" \
        '[{"objectID":"m1","image":"https://images.example.com/movie.jpg"}]' \
        '[]'

    run_probe "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "example owner URL should fail"
    assert_contains "$RUN_STDERR" "image uses placeholder/example URL" "example owner failure should name URL contract"
    assert_eq "$(wc -l < "$tmp_dir/curl_calls.log" | tr -d ' ')" "0" "example owner rejection should happen before curl"

    trap - RETURN
    rm -rf "$tmp_dir"
}

test_deduplicates_and_uses_exact_curl_flags
test_rejects_non_https_before_curl
test_rejects_placeholder_before_curl
test_rejects_example_owner_before_curl

if [ "$FAIL_COUNT" -ne 0 ]; then
    echo "FAIL: $FAIL_COUNT assertions failed; $PASS_COUNT passed" >&2
    exit 1
fi

echo "PASS: probe_demo_template_image_urls_test.sh ($PASS_COUNT assertions)"
