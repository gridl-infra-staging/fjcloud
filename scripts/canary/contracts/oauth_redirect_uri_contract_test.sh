#!/usr/bin/env bash
# Unit test for oauth_redirect_uri_contract.sh self-test isolation.
#
# Regression guard for the bug where run_self_test() could false-PASS when the
# provider token endpoint *accepted* the known-bad redirect URI (semantics
# drift) but the follow-on callback-reachability curl failed with HTTP 000 on
# the unresolvable .invalid host. In that case fail=1 came from the reachability
# curl, not the provider, so the self-test wrongly concluded the probe could
# still distinguish registered from unregistered URIs.
#
# Strategy: source the contract script (it must not run live probes on source),
# stub `curl` to simulate provider/web responses deterministically, and assert
# run_self_test()'s verdict reflects ONLY the provider token-endpoint outcome.
# shellcheck disable=SC1091,SC2329
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=oauth_redirect_uri_contract.sh
source "$SCRIPT_DIR/oauth_redirect_uri_contract.sh"

failures=0
fail_test() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
pass_test() { echo "PASS: $1"; }

# --- curl stub -------------------------------------------------------------
# The contract script calls curl in two distinct shapes:
#   1. Provider token endpoint: POST to oauth2.googleapis.com / github.com.
#   2. Callback reachability:   GET with -w "%{http_code}" against the web host.
# We discriminate on the presence of the "-w" flag (only reachability uses it)
# and emit STUB_TOKEN_BODY / STUB_CALLBACK_STATUS accordingly.
STUB_TOKEN_BODY=""
STUB_CALLBACK_STATUS="000"
STUB_CALLBACK_CURL_RC=0
curl() {
  local is_reachability=0
  for arg in "$@"; do
    if [[ "$arg" == "-w" ]]; then is_reachability=1; break; fi
  done
  if [[ "$is_reachability" -eq 1 ]]; then
    printf '%s' "$STUB_CALLBACK_STATUS"
    return "$STUB_CALLBACK_CURL_RC"
  fi
  printf '%s' "$STUB_TOKEN_BODY"
  return 0
}

# Google "accepts" the bad URI: invalid_grant means redirect_uri was NOT flagged.
GOOGLE_ACCEPT_BODY='{"error":"invalid_grant","error_description":"Malformed auth code."}'
# Google rejects the bad URI per its real wire format.
GOOGLE_REJECT_BODY='{"error":"invalid_request","error_description":"... does not comply with Google'\''s OAuth 2.0 policy ..."}'
# GitHub "accepts" the bad URI: bogus code reached verification and was rejected.
GITHUB_ACCEPT_BODY='{"error":"bad_verification_code","error_description":"The code passed is incorrect or expired."}'
# GitHub rejects an unregistered redirect_uri with its documented mismatch error.
GITHUB_REJECT_BODY='{"error":"redirect_uri_mismatch","error_description":"The redirect_uri MUST match the registered callback URL for this application."}'

# --- Test 1: provider drift must surface as PROBE-BROKEN -------------------
# Provider accepts the known-bad URI (drift) AND the callback host is
# unreachable (HTTP 000, as .invalid always is). The self-test must FAIL
# because the provider stopped distinguishing bad URIs -- it must NOT be
# rescued to a pass by the reachability curl failing.
STUB_TOKEN_BODY="$GOOGLE_ACCEPT_BODY"
STUB_CALLBACK_STATUS="000"
if run_self_test google fake_id fake_secret >/dev/null 2>&1; then
  fail_test "drift scenario: run_self_test PASSED when provider accepted the bad URI (reachability 000 masked the regression)"
else
  pass_test "drift scenario: run_self_test correctly reported PROBE-BROKEN despite reachability failure"
fi

STUB_TOKEN_BODY="$GITHUB_ACCEPT_BODY"
STUB_CALLBACK_STATUS="000"
if run_self_test github fake_id fake_secret >/dev/null 2>&1; then
  fail_test "GitHub drift scenario: run_self_test PASSED when provider accepted the bad URI (reachability 000 masked the regression)"
else
  pass_test "GitHub drift scenario: run_self_test correctly reported PROBE-BROKEN despite reachability failure"
fi

# --- Test 2: genuine provider rejection still passes the self-test ---------
# Provider rejects the bad URI. Self-test must pass (the probe works).
STUB_TOKEN_BODY="$GOOGLE_REJECT_BODY"
STUB_CALLBACK_STATUS="000"
if run_self_test google fake_id fake_secret >/dev/null 2>&1; then
  pass_test "rejection scenario: run_self_test passed when provider rejected the bad URI"
else
  fail_test "rejection scenario: run_self_test failed even though provider rejected the bad URI"
fi

STUB_TOKEN_BODY="$GITHUB_REJECT_BODY"
STUB_CALLBACK_STATUS="000"
if run_self_test github fake_id fake_secret >/dev/null 2>&1; then
  pass_test "GitHub rejection scenario: run_self_test passed when provider rejected the bad URI"
else
  fail_test "GitHub rejection scenario: run_self_test failed even though provider rejected the bad URI"
fi

# --- Test 3: real-run reachability 404 detection is preserved --------------
# On a real run (APP_BASE_OVERRIDE empty), provider accepts a registered URI
# but the web host returns 404 -> reachability must still set fail=1. This
# guards against the isolation fix accidentally disabling reachability
# detection outside the self-test.
fail=0
APP_BASE_OVERRIDE=""
STUB_TOKEN_BODY="$GOOGLE_ACCEPT_BODY"
STUB_CALLBACK_STATUS="404"
probe_google prod fake_id fake_secret >/dev/null 2>&1
if [[ "$fail" -eq 1 ]]; then
  pass_test "real-run scenario: reachability still flags HTTP 404 callback regression"
else
  fail_test "real-run scenario: reachability did NOT flag HTTP 404 (got fail=$fail)"
fi

fail=0
APP_BASE_OVERRIDE=""
STUB_TOKEN_BODY="$GITHUB_ACCEPT_BODY"
STUB_CALLBACK_STATUS="404"
probe_github prod fake_id fake_secret >/dev/null 2>&1
if [[ "$fail" -eq 1 ]]; then
  pass_test "GitHub real-run scenario: reachability still flags HTTP 404 callback regression"
else
  fail_test "GitHub real-run scenario: reachability did NOT flag HTTP 404 (got fail=$fail)"
fi

if [[ "$failures" -ne 0 ]]; then
  echo "oauth_redirect_uri_contract self-test isolation: $failures assertion(s) failed" >&2
  exit 1
fi
echo "oauth_redirect_uri_contract self-test isolation: all assertions passed"
