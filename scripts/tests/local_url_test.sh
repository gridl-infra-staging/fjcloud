#!/usr/bin/env bash
# local_url_test.sh — Branch coverage for scripts/lib/local_url.sh.
#
# loopback_http_url_is_valid is the single owner of the loopback-HTTP guard
# that scripts/api-dev.sh and scripts/playwright_local_stack.sh both apply
# before a verification email can be sent. It is a closed rule set: a URL is
# valid only when it clears ALL THREE rejection rules —
#   1. scheme must be exactly "http" (not https/other),
#   2. host must be loopback (localhost, 127.0.0.0/8, or ::1),
#   3. no embedded userinfo (username/password).
# Every rule must be able to fail for a real defect, so each rejection branch
# has its own case here. Prove fail-capability by deleting the scheme and
# credential checks in local_url.sh and re-running: the scheme and userinfo
# cases below turn red.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=../lib/local_url.sh
source "$REPO_ROOT/scripts/lib/local_url.sh"

assert_url_accepted() {
	local url="$1"
	if loopback_http_url_is_valid "$url"; then
		pass "accepts loopback HTTP URL: $url"
	else
		fail "should accept loopback HTTP URL: $url"
	fi
}

assert_url_rejected() {
	local url="$1" reason="$2"
	if loopback_http_url_is_valid "$url"; then
		fail "should reject $reason: $url"
	else
		pass "rejects $reason: $url"
	fi
}

test_accepts_loopback_http_urls() {
	assert_url_accepted "http://127.0.0.1:8025"
	assert_url_accepted "http://localhost:8025"
	assert_url_accepted "http://[::1]:8025"
}

# Rule 1: non-http scheme. An https or ws endpoint could route a verification
# email off-host even when the host is loopback.
test_rejects_non_http_scheme() {
	assert_url_rejected "https://127.0.0.1:8025" "https scheme"
	assert_url_rejected "ws://127.0.0.1:8025" "non-http scheme"
}

# Rule 2: non-loopback host. This is the rule the api-dev regression already
# exercises; covered here too so the closed set is complete in one place.
test_rejects_non_loopback_host() {
	assert_url_rejected "http://mail.example.test:8025" "non-loopback host"
	assert_url_rejected "http://10.0.0.5:8025" "non-loopback private host"
}

# Rule 3: embedded userinfo. Credentials in the URL are a smell that the
# endpoint is not the local Mailpit and must be rejected before use.
test_rejects_embedded_userinfo() {
	assert_url_rejected "http://user:pass@127.0.0.1:8025" "embedded username and password"
	assert_url_rejected "http://user@127.0.0.1:8025" "embedded username"
}

# A syntactically broken host must fail closed rather than raising uncaught.
test_rejects_malformed_url() {
	assert_url_rejected "not-a-url" "malformed URL"
	assert_url_rejected "" "empty URL"
}

main() {
	echo "=== local_url_test.sh ==="
	echo ""

	test_accepts_loopback_http_urls
	test_rejects_non_http_scheme
	test_rejects_non_loopback_host
	test_rejects_embedded_userinfo
	test_rejects_malformed_url

	run_test_summary
}

main "$@"
