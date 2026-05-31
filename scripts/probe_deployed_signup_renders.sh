#!/usr/bin/env bash
# probe_deployed_signup_renders.sh — assert deployed /signup actually renders the form.
#
# Purpose: detect the architectural failure where the public web host
# (cloud.flapjack.foo) is served by a static-only deployment that has no
# `signup.html` artifact, so requests for `/signup` fall back to `index.html`
# (the landing page). Browsers receive HTTP 200 with a body that hydrates as
# the marketing root route, not the signup component — which is exactly the
# class of bug that silently broke LB-2 Phase B for ~6 weeks.
#
# Why a 200/status check is NOT enough: CF Pages with `strict: false` and
# `handleUnseenRoutes: 'ignore'` returns 200 for any path by serving
# `index.html` as a fallback. The discriminator is server-rendered content:
# only an SSR-capable deployment (adapter-cloudflare / adapter-node) will emit
# the signup form's HTML in the initial response. adapter-static cannot.
#
# This probe is the canonical regression test for the signup-rendering
# contract and MUST stay green for any deploy that claims paid-customer
# launch readiness. It pairs with the LB-2 Playwright spec; this is the
# cheap, fast, dependency-free version that will catch the same defect in
# under a second per probe.
#
# Scope (IS): one HTTP GET against the configured signup URL, asserting
# status 200 AND body contains discriminating signup-form markers that only
# appear in server-rendered output of the signup route.
#
# Scope (IS NOT): does NOT submit the form, does NOT exercise the API, does
# NOT verify cookie behavior end-to-end. Those are LB-2 Playwright's job.
#
# Usage:
#   bash scripts/probe_deployed_signup_renders.sh
#   SIGNUP_URL=https://example.com/signup bash scripts/probe_deployed_signup_renders.sh
#
# Exit codes:
#   0  /signup rendered the signup form (server-rendered HTML observed).
#   2  /signup did not render the form (likely SPA-fallback to index.html).
#   3  Transport error (DNS, TLS, timeout).

set -euo pipefail

SIGNUP_URL="${SIGNUP_URL:-https://cloud.flapjack.foo/signup}"
CURL_MAX_TIME_SECONDS=15
EXIT_RENDER_FAILURE=2
EXIT_TRANSPORT_FAILURE=3

log() {
    echo "[probe-signup] $*"
}

# tmp is global so the EXIT trap (which fires after `main` returns and the
# function-local scope is gone) can still see it under `set -u`.
TMP_BODY=""
cleanup() { [[ -n "${TMP_BODY:-}" ]] && rm -f "$TMP_BODY"; }
trap cleanup EXIT

main() {
    local body http_code
    TMP_BODY="$(mktemp)"

    # Capture body and status separately so we can fail-distinguish transport
    # vs. content-mismatch. -fsS would swallow non-2xx without giving us the
    # body to inspect, which we want for diagnostics on render failure.
    if ! http_code="$(curl -sS --max-time "$CURL_MAX_TIME_SECONDS" -o "$TMP_BODY" -w '%{http_code}' "$SIGNUP_URL")"; then
        log "FAIL transport_error url=${SIGNUP_URL}"
        return "$EXIT_TRANSPORT_FAILURE"
    fi

    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log "FAIL http_status=${http_code} url=${SIGNUP_URL}"
        return "$EXIT_RENDER_FAILURE"
    fi

    body="$(cat "$TMP_BODY")"

    # Discriminating markers: these strings appear ONLY when the signup
    # component is server-rendered. The marketing landing page (which
    # adapter-static serves as fallback for /signup) does NOT contain
    # the confirm_password field name or the "Create your account" h1.
    # Both must be present — if just one matches, something else is off.
    local missing=()
    grep -q 'name="confirm_password"' <<<"$body" || missing+=("name=\"confirm_password\"")
    grep -q 'Create your account' <<<"$body" || missing+=("Create your account")
    grep -qE '<form[^>]*method="POST"' <<<"$body" || missing+=("<form method=\"POST\">")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "FAIL render_mismatch url=${SIGNUP_URL} missing_markers=${missing[*]}"
        log "    likely cause: deployment is static-only and /signup falls back"
        log "    to index.html. Verify adapter is adapter-cloudflare (or other"
        log "    SSR adapter) and CF Pages serves SvelteKit Functions output."
        return "$EXIT_RENDER_FAILURE"
    fi

    log "OK url=${SIGNUP_URL} status=${http_code} markers=all-present"
    return 0
}

main "$@"
