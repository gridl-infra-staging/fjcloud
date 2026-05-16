#!/usr/bin/env bash
# OAuth redirect_uri contract probe. Verifies that Google and GitHub OAuth
# providers accept the redirect_uri the fjcloud API will actually send during
# a real signup flow.
#
# Technique: POST each provider's TOKEN endpoint with a deliberately-bogus
# authorization code plus the redirect_uri we want to validate. Both providers
# validate redirect_uri BEFORE attempting to redeem the code (RFC 6749 § 5.2),
# so the JSON error discriminates:
#   - unregistered URI -> error=redirect_uri_mismatch (the regression signal).
#   - registered URI   -> error=invalid_grant (Google) or bad_verification_code
#                        (GitHub) -- both expected for the bogus code we sent.
#
# Why NOT the authorize endpoint (/o/oauth2/v2/auth, /login/oauth/authorize):
# both providers redirect unauthenticated callers to a login page BEFORE
# evaluating redirect_uri, so curl always sees a 302 regardless of registration
# state. Live test confirmed Google redirects to .../signin/oauth/error with
# a base64 authError param (no "redirect_uri_mismatch" string); GitHub bounces
# to /login?return_to=.... The token endpoint has no login wall.
#
# Required env (sourced from .env.secret before invocation):
#   GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET
#   GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET
# Optional env (skipped if absent):
#   GITHUB_OAUTH_CLIENT_ID_STAGING, GITHUB_OAUTH_CLIENT_SECRET_STAGING
#   APP_BASE_URL_STAGING -- staging signup URL; no source-of-truth default exists
#
# Usage: oauth_redirect_uri_contract.sh [prod|staging|all]
set -euo pipefail

env_arg="${1:-all}"
[[ "$env_arg" == "prod" || "$env_arg" == "staging" || "$env_arg" == "all" ]] \
  || { echo "usage: $0 [prod|staging|all]" >&2; exit 2; }

# Per-env APP_BASE_URL. prod default matches infra/api/src/services/email.rs
# DEFAULT_APP_BASE_URL. Staging has no compiled-in default; the probe SKIPs
# staging rather than guessing if APP_BASE_URL_STAGING is unset.
#
# Implemented as a function (not associative array) for bash-3.2 portability --
# macOS ships bash 3.2 by default; `declare -A` would fail there. The
# APP_BASE_OVERRIDE variable lets the self-test inject a known-bad URL
# without rebuilding the function.
APP_BASE_OVERRIDE=""
app_base_for() {
  if [[ -n "$APP_BASE_OVERRIDE" ]]; then printf '%s' "$APP_BASE_OVERRIDE"; return; fi
  case "$1" in
    prod)    printf '%s' "${APP_BASE_URL_PROD:-https://cloud.flapjack.foo}" ;;
    staging) printf '%s' "${APP_BASE_URL_STAGING:-}" ;;
  esac
}

fail=0

# Probe Google's token endpoint. Sets global $fail=1 on rejection.
# Sentinel "fjcloud_probe_invalid_code" is sent as the auth code so any
# future log inspection on the Google side can identify these probe calls.
#
# Empirical 2026-05-14 (verified via direct curl, not docs):
#  - Unregistered redirect_uri -> {"error":"invalid_request","error_description":
#    "...doesn't comply with Google's OAuth 2.0 policy..."} (NOT redirect_uri_mismatch
#    despite what the OAuth spec might suggest -- Google's wire format differs from
#    the RFC 6749 § 5.2 default error codes for the token endpoint).
#  - Registered redirect_uri + bogus code -> {"error":"invalid_grant",
#    "error_description":"Malformed auth code."} -> the success path for our probe.
# We discriminate by both error code AND error_description content because
# `invalid_request` is also the generic OAuth error for missing params -- we
# need to confirm it specifically means "redirect_uri policy violation".
probe_google() {
  local env="$1" client_id="$2" client_secret="$3"
  local redirect_uri="$(app_base_for "$env")/auth/oauth/google/callback"
  local body err desc
  body=$(curl -s --max-time 10 -X POST 'https://oauth2.googleapis.com/token' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "code=fjcloud_probe_invalid_code" \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode "client_secret=${client_secret}" \
    --data-urlencode "redirect_uri=${redirect_uri}" \
    --data-urlencode "grant_type=authorization_code" \
    || true)
  err=$(printf '%s' "$body" | jq -r '.error // empty' 2>/dev/null || echo "")
  desc=$(printf '%s' "$body" | jq -r '.error_description // empty' 2>/dev/null || echo "")
  case "$err" in
    invalid_request)
      # Confirm the invalid_request specifically means redirect_uri rejection
      # (vs a generic missing-param error). The description includes
      # "OAuth 2.0 policy" wording for the redirect_uri rejection case.
      if echo "$desc" | grep -qi "OAuth 2.0 policy\|redirect"; then
        echo "FAIL: Google OAuth env=$env rejected redirect_uri=$redirect_uri (error=invalid_request)"
        echo "      Add this URL to https://console.cloud.google.com/apis/credentials -> OAuth 2.0 Client -> Authorized redirect URIs"
        fail=1
      else
        echo "WARN: Google OAuth env=$env returned invalid_request with unexpected description: $desc"
        fail=1
      fi
      ;;
    redirect_uri_mismatch)
      # Preserved for safety in case Google ever aligns with the RFC label.
      echo "FAIL: Google OAuth env=$env rejected redirect_uri=$redirect_uri (error=redirect_uri_mismatch)"
      echo "      Add this URL to https://console.cloud.google.com/apis/credentials -> OAuth 2.0 Client -> Authorized redirect URIs"
      fail=1
      ;;
    invalid_grant)
      # redirect_uri accepted, bogus code rejected -> the success path.
      echo "PASS: Google OAuth env=$env accepted $redirect_uri (token endpoint error=invalid_grant -- expected for bogus code)"
      ;;
    "")
      echo "WARN: Google OAuth env=$env returned no .error field. Body: ${body:0:300}"
      fail=1
      ;;
    *)
      echo "WARN: Google OAuth env=$env returned unexpected error=$err. Body: ${body:0:300}"
      fail=1
      ;;
  esac
}

# Probe GitHub's token endpoint. Same shape as probe_google but GitHub returns
# 200 OK with errors in the JSON body (per their OAuth docs). Accept:
# application/json forces JSON instead of the default URL-encoded form.
probe_github() {
  local env="$1" client_id="$2" client_secret="$3"
  local redirect_uri="$(app_base_for "$env")/auth/oauth/github/callback"
  local body err
  body=$(curl -s --max-time 10 -X POST 'https://github.com/login/oauth/access_token' \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode "client_secret=${client_secret}" \
    --data-urlencode "code=fjcloud_probe_invalid_code" \
    --data-urlencode "redirect_uri=${redirect_uri}" \
    || true)
  err=$(printf '%s' "$body" | jq -r '.error // empty' 2>/dev/null || echo "")
  case "$err" in
    redirect_uri_mismatch)
      echo "FAIL: GitHub OAuth env=$env rejected redirect_uri=$redirect_uri"
      echo "      GitHub OAuth Apps allow only ONE callback URL -- update at https://github.com/settings/developers"
      echo "      (or use a separate OAuth App for staging via GITHUB_OAUTH_CLIENT_ID_STAGING)"
      fail=1
      ;;
    bad_verification_code|incorrect_client_credentials)
      # bad_verification_code = redirect_uri accepted, bogus code rejected -> success.
      # incorrect_client_credentials would surface a different misconfig but still
      # means redirect_uri itself was not flagged -- pass with a note.
      echo "PASS: GitHub OAuth env=$env accepted $redirect_uri (token endpoint error=$err -- expected for bogus code)"
      ;;
    "")
      echo "WARN: GitHub OAuth env=$env returned no .error field. Body: ${body:0:300}"
      fail=1
      ;;
    *)
      echo "WARN: GitHub OAuth env=$env returned unexpected error=$err. Body: ${body:0:300}"
      fail=1
      ;;
  esac
}

# Self-test: feed each probe a definitely-unregistered URL and assert it FAILs.
# If a probe returns PASS for a bad URL, it cannot distinguish rejection from
# acceptance, so any subsequent PASS against the real URL would be meaningless.
# Hard-exit rather than fabricate green. The bad URL uses .invalid TLD per
# RFC 6761 -- guaranteed never resolvable.
SELF_TEST_BAD_URI="https://NEVER-REGISTERED-WITH-PROVIDER.example.invalid/oauth-probe-self-test"

run_self_test() {
  local kind="$1" client_id="$2" client_secret="$3"
  local saved_fail=$fail
  fail=0
  # Inject the known-bad URL via the global override; app_base_for() returns
  # APP_BASE_OVERRIDE when set regardless of env arg.
  APP_BASE_OVERRIDE="$SELF_TEST_BAD_URI"
  if [[ "$kind" == "google" ]]; then
    probe_google prod "$client_id" "$client_secret" >/dev/null 2>&1
  else
    probe_github prod "$client_id" "$client_secret" >/dev/null 2>&1
  fi
  APP_BASE_OVERRIDE=""
  local caught=$fail
  fail=$saved_fail
  if [[ "$caught" -eq 0 ]]; then
    echo "PROBE-BROKEN: $kind probe accepted a definitely-unregistered URL ($SELF_TEST_BAD_URI)."
    echo "  Probe cannot distinguish rejection from acceptance. Refusing to claim PASS on real URLs."
    echo "  Investigate: did the provider change its token-endpoint error semantics?"
    return 1
  fi
  echo "self-test PASS: $kind probe correctly rejected $SELF_TEST_BAD_URI"
  return 0
}

# Run self-tests before touching real URLs. Hard exit if any is broken.
self_test_failed=0
if [[ -n "${GOOGLE_CLIENT_ID:-}" && -n "${GOOGLE_CLIENT_SECRET:-}" ]]; then
  run_self_test google "$GOOGLE_CLIENT_ID" "$GOOGLE_CLIENT_SECRET" || self_test_failed=1
fi
if [[ -n "${GITHUB_CLIENT_ID:-}" && -n "${GITHUB_CLIENT_SECRET:-}" ]]; then
  run_self_test github "$GITHUB_CLIENT_ID" "$GITHUB_CLIENT_SECRET" || self_test_failed=1
fi
if [[ "$self_test_failed" -ne 0 ]]; then
  exit 1
fi

# Skip an env when its base URL resolves empty rather than fabricating a
# probe against a guessed URL.
require_app_base() {
  local env="$1"
  if [[ -z "$(app_base_for "$env")" ]]; then
    # ${var^^} is bash-4 syntax; spell out the upper-cased var name explicitly
    # for bash-3.2 portability on stock macOS.
    local up
    case "$env" in prod) up=PROD ;; staging) up=STAGING ;; esac
    echo "SKIP: APP_BASE_URL_${up} not set; $env probes skipped (set in .env.secret)"
    return 1
  fi
  return 0
}

for env in prod staging; do
  if [[ "$env_arg" != "all" && "$env_arg" != "$env" ]]; then continue; fi
  require_app_base "$env" || continue
  case "$env" in
    prod)
      if [[ -n "${GOOGLE_CLIENT_ID:-}" && -n "${GOOGLE_CLIENT_SECRET:-}" ]]; then
        probe_google prod "$GOOGLE_CLIENT_ID" "$GOOGLE_CLIENT_SECRET"
      else
        echo "SKIP: GOOGLE_CLIENT_ID/SECRET not set, prod Google probe skipped"
      fi
      if [[ -n "${GITHUB_CLIENT_ID:-}" && -n "${GITHUB_CLIENT_SECRET:-}" ]]; then
        probe_github prod "$GITHUB_CLIENT_ID" "$GITHUB_CLIENT_SECRET"
      else
        echo "SKIP: GITHUB_CLIENT_ID/SECRET not set, prod GitHub probe skipped"
      fi
      ;;
    staging)
      # Staging Google reuses the prod client -- Google allows multiple URIs in
      # the allow-list, so one client covers both envs.
      if [[ -n "${GOOGLE_CLIENT_ID:-}" && -n "${GOOGLE_CLIENT_SECRET:-}" ]]; then
        probe_google staging "$GOOGLE_CLIENT_ID" "$GOOGLE_CLIENT_SECRET"
      else
        echo "SKIP: GOOGLE_CLIENT_ID/SECRET not set, staging Google probe skipped"
      fi
      # Staging GitHub uses a SEPARATE OAuth App (single-callback constraint).
      if [[ -n "${GITHUB_OAUTH_CLIENT_ID_STAGING:-}" && -n "${GITHUB_OAUTH_CLIENT_SECRET_STAGING:-}" ]]; then
        probe_github staging "$GITHUB_OAUTH_CLIENT_ID_STAGING" "$GITHUB_OAUTH_CLIENT_SECRET_STAGING"
      else
        echo "SKIP: GITHUB_OAUTH_CLIENT_ID_STAGING/SECRET not set, staging GitHub probe skipped"
      fi
      ;;
  esac
done

exit $fail
