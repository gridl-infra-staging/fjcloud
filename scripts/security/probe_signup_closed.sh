#!/usr/bin/env bash

# Read-only probe: assert that customer self-registration is REFUSED on a host.
#
# WHY THIS EXISTS. Production serves the engine data plane as plaintext HTTP on
# 0.0.0.0/0 tcp/7700 (`sg-0ab78cabd1b997099`, rule "public flapjack data plane"),
# and `POST /auth/register` has no invite, waitlist or allowlist gate
# (`infra/api/src/routes/auth.rs::register` validates the payload and creates the
# customer). Until the TLS fleet rebuild closes 7700, anyone who registers on
# production lands on a plaintext data plane. Registration is therefore held shut
# at the prod ALB, and this probe is what makes that block *visible to the repo*
# instead of being an undocumented console patch -- the exact failure mode the
# 2026-07 postmortem recorded when public data-plane access depended on a manual
# security-group patch (see ops/terraform/networking/main.tf above
# `flapjack_public_data_plane`).
#
# WHY IT ASSERTS A MARKER AND NOT MERELY "NOT 2xx". A bare 503 is also what a
# genuine ALB or target-group outage returns. Treating that as "registration is
# safely closed" would let an outage masquerade as a security control and would
# go green for the wrong reason. The block's fixed response therefore carries a
# marker string, and only marker-bearing refusals count as CLOSED.
#
# The probe never defaults to healthy: a transport failure, an unexpected status,
# or an unparseable response is INDETERMINATE and exits non-zero, because "we
# could not tell" and "it is closed" are different facts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The block's shape (marker, path, refusal status) has a single owner that the
# applier reads too, so the control and its proof cannot drift apart silently.
# shellcheck source=signup_block_contract.sh disable=SC1091
source "$SCRIPT_DIR/signup_block_contract.sh"

# Statuses that prove the endpoint is LIVE and processing registrations. A 400 or
# 422 is a *validation* refusal, which means the handler ran -- that is an open
# endpoint, not a closed one, and is the single most likely wrong-green here.
OPEN_STATUSES="200 201 400 409 422"

HOST=""
FIXTURE_STATUS=""
FIXTURE_BODY=""
FIXTURE_MODE=0

usage() {
    cat <<'EOF'
Usage: scripts/security/probe_signup_closed.sh --host HOST
       scripts/security/probe_signup_closed.sh --fixture-status CODE [--fixture-body TEXT]

  --host HOST         Public API host to probe, e.g. api.flapjack.foo
  --fixture-status    Hermetic mode: classify this status without any network I/O
  --fixture-body      Hermetic mode: the response body paired with --fixture-status

Verdicts (printed as `verdict=<V>`):
  CLOSED         registration is refused by the marker-bearing block   -> exit 0
  OPEN           registration endpoint is live and processing          -> exit 1
  INDETERMINATE  could not establish either fact                       -> exit 1
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            [ "$#" -ge 2 ] || die "--host requires a value"
            HOST="$2"
            shift 2
            ;;
        --fixture-status)
            [ "$#" -ge 2 ] || die "--fixture-status requires a value"
            FIXTURE_STATUS="$2"
            FIXTURE_MODE=1
            shift 2
            ;;
        --fixture-body)
            [ "$#" -ge 2 ] || die "--fixture-body requires a value"
            FIXTURE_BODY="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

if [ "$FIXTURE_MODE" -eq 0 ] && [ -z "$HOST" ]; then
    usage >&2
    die "--host is required outside fixture mode"
fi

status=""
body=""

if [ "$FIXTURE_MODE" -eq 1 ]; then
    status="$FIXTURE_STATUS"
    body="$FIXTURE_BODY"
else
    # Deliberately send a payload that cannot create an account even if the
    # endpoint is wide open: `{}` fails deserialization on the required `name`
    # field before any repository write. The probe must never be capable of
    # provisioning a real customer on production as a side effect of measuring.
    response="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' \
        -X POST "https://${HOST}${SIGNUP_BLOCK_PATH}" \
        -H 'content-type: application/json' \
        -d '{}' 2>/dev/null)"
    curl_rc=$?
    if [ "$curl_rc" -ne 0 ]; then
        status=""
    else
        status="$response"
    fi
    # Fetch the body separately so a marker check is possible. A failed body read
    # leaves `body` empty, which cannot satisfy the marker test and so degrades to
    # INDETERMINATE rather than to a false CLOSED.
    body="$(curl -sS -m 20 \
        -X POST "https://${HOST}${SIGNUP_BLOCK_PATH}" \
        -H 'content-type: application/json' \
        -d '{}' 2>/dev/null || true)"
fi

printf 'host=%s\n' "${HOST:-<fixture>}"
printf 'status=%s\n' "${status:-<none>}"

# Classification. Order matters: prove CLOSED positively before anything else, so
# no later branch can widen it.
case "$status" in
    ''|*[!0-9]*)
        # No status, or a non-numeric one: transport failure or garbage. Not a
        # statement about registration either way.
        printf 'verdict=INDETERMINATE\n'
        printf 'reason=no usable HTTP status from %s (transport failure or unparseable response)\n' "${HOST:-<fixture>}"
        exit 1
        ;;
esac

if [ "$status" = "$SIGNUP_BLOCK_STATUS" ]; then
    case "$body" in
        *"$SIGNUP_BLOCK_MARKER"*)
            printf 'verdict=CLOSED\n'
            printf 'reason=registration refused by the marker-bearing block (%s)\n' "$SIGNUP_BLOCK_MARKER"
            exit 0
            ;;
        *)
            # 503 without the marker is an outage, not a control. Refusing to call
            # this CLOSED is the whole point: an outage must not read as a
            # security guarantee.
            printf 'verdict=INDETERMINATE\n'
            printf 'reason=%s without the %s marker; this is an outage shape, not the registration block\n' \
                "$SIGNUP_BLOCK_STATUS" "$SIGNUP_BLOCK_MARKER"
            exit 1
            ;;
    esac
fi

for open_status in $OPEN_STATUSES; do
    if [ "$status" = "$open_status" ]; then
        printf 'verdict=OPEN\n'
        printf 'reason=registration endpoint is live and processing (status %s)\n' "$status"
        exit 1
    fi
done

printf 'verdict=INDETERMINATE\n'
printf 'reason=unexpected status %s; cannot prove registration is refused\n' "$status"
exit 1
