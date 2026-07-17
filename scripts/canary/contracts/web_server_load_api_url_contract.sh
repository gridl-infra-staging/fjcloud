#!/usr/bin/env bash
# Web frontend SERVER-LOAD API URL contract probe. Verifies that
# server-side load functions on the deployed SvelteKit frontend hit the
# correct API origin for the env, by checking that a known-good staging
# JWT cookie sent to /console/api-keys returns load data instead of
# bouncing to /login?reason=session_expired.
#
# Why this exists separately from web_api_base_url_contract.sh:
#
#   web_api_base_url_contract.sh covers OAuth-start HTML hrefs, which are
#   rendered via locals.apiBaseUrl set in hooks.server.ts (hostname-aware).
#   That contract passes even when server-side load functions are calling
#   the WRONG API, because the load-function path went through
#   createApiClient() (web/src/lib/server/api.ts) which previously had an
#   env-var fallback that returned the prod API URL when CF Pages staging
#   env vars weren't perfect.
#
#   Anchored: 2026-05-22 fjcloud Stage 4 LB-2/LB-3 — staging dashboard
#   pages silently called prod API; tokens signed with staging JWT_SECRET
#   were rejected by prod with 401; web caught 401 as "session expired"
#   and redirected to /login?reason=session_expired. The OAuth contract
#   passed the entire time. Fix: removed env-var fallback in
#   web/src/lib/server/api.ts::createApiClient; now derives URL from
#   getRequestEvent().locals.apiBaseUrl (set by hooks from request
#   hostname) with hostname-derive fallback. This probe asserts the fix
#   stays in place.
#
# Technique:
#   1. Register a throwaway customer via direct staging API call.
#   2. POST the auth cookie back as auth_token to the WEB origin.
#   3. GET /console/api-keys/__data.json (load function path that uses
#      createApiClient). Assert response is NOT a session_expired
#      redirect.
#
#   The probe customer is left in staging (email_verified=false, free
#   plan, no payment methods). Staging customer cleanup runs hourly.
#
# Usage:
#   web_server_load_api_url_contract.sh [staging]
#
# Exit: 0 on pass, 1 on FAIL, 2 on usage/setup error. (No prod probe -
# we never want to mint throwaway accounts on prod.)
set -euo pipefail

env_arg="${1:-staging}"
[[ "$env_arg" == "staging" ]] \
  || { echo "usage: $0 [staging]" >&2; exit 2; }

api_origin="https://api.staging.flapjack.foo"
web_origin="https://cloud.staging.flapjack.foo"

# Mint a throwaway probe customer. The address pattern matches existing
# e2e seed conventions so the staging cleanup job sweeps it.
seed="$(date -u +%s)-$RANDOM"
probe_email="probe-contract-${seed}@e2e.griddle.test"
probe_password="ContractProbe123!"

register_body="$(printf '{"name":"contract probe %s","email":"%s","password":"%s"}' \
  "$seed" "$probe_email" "$probe_password")"

register_response="$(curl -sS --max-time 15 \
  -H 'Content-Type: application/json' \
  -d "$register_body" \
  "${api_origin}/auth/register" || true)"

if [[ -z "$register_response" ]]; then
  echo "ERROR: env=$env_arg staging API /auth/register returned empty body"
  exit 2
fi

token="$(printf '%s' "$register_response" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' \
  2>/dev/null || true)"

if [[ -z "$token" ]]; then
  echo "ERROR: env=$env_arg could not extract token from /auth/register response:"
  echo "       $register_response"
  exit 2
fi

# Sanity: the token works against the direct staging API. If THIS fails,
# the bug is in the API, not the web. Don't blame the web for an upstream
# regression.
sanity_status="$(curl -sS --max-time 15 \
  -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${token}" \
  "${api_origin}/account" || true)"

if [[ "$sanity_status" != "200" ]]; then
  echo "ERROR: env=$env_arg staging API /account rejected its own freshly-minted token (HTTP ${sanity_status})"
  echo "       Probe customer: ${probe_email}"
  echo "       This is an API regression, not a web bug. Skipping web probe."
  exit 2
fi

# The actual contract: send the cookie to the web origin and see if the
# load function bounces. Use /console/billing because its load function
# EXPLICITLY redirects on 401/403 (via isDashboardSessionExpiredError),
# which makes the failure mode unambiguous. Routes that .catch() errors
# silently (like /console/api-keys) cannot tell us whether the load
# succeeded or silently failed - both return the same empty-fixture shape.
probe_url="${web_origin}/console/billing/__data.json"
probe_body="$(curl -sS --max-time 30 \
  -b "auth_token=${token}" \
  "${probe_url}" || true)"

if [[ -z "$probe_body" ]]; then
  echo "ERROR: env=$env_arg GET ${probe_url} returned empty body"
  exit 2
fi

# Look for the failure pattern. The body is SvelteKit __data.json shape.
# Success returns {"type":"data",...}. Session expired returns
# {"type":"redirect","location":"/login?reason=session_expired"}.
if printf '%s' "$probe_body" | grep -q '"location":"/login?reason=session_expired"'; then
  echo "FAIL: env=$env_arg ${probe_url} bounced to session_expired"
  echo "       Probe customer: ${probe_email} (token works against staging API directly)"
  echo "       Bounce body:"
  printf '       %s\n' "$probe_body"
  echo
  echo "       This means a server-side load function called the wrong API."
  echo "       Likely cause: web/src/lib/server/api.ts::createApiClient lost"
  echo "       its locals.apiBaseUrl wiring and fell back to an env-var-based"
  echo "       URL that points at the wrong environment's API."
  exit 1
fi

if ! printf '%s' "$probe_body" | grep -q '"type":"data"'; then
  echo "FAIL: env=$env_arg ${probe_url} returned unexpected shape"
  echo "       Probe customer: ${probe_email}"
  echo "       Body:"
  printf '       %s\n' "$probe_body"
  exit 1
fi

echo "PASS: env=$env_arg ${probe_url} server-side load reached correct API"
exit 0
