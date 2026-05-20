#!/usr/bin/env bash
# staging_browser_host_probe_test.sh — strict TLS + HTML-signature contract
# for the canonical staging browser host.
#
# Asserts:
#   (a) TLS SAN includes the target host
#   (b) Issuer is Google Trust Services (Cloudflare Pages) — rejects the
#       Amazon-issued staging.flapjack.foo ALB surface
#   (c) HTML body contains _app/immutable (SvelteKit marker)
#
# Usage:
#   bash scripts/tests/staging_browser_host_probe_test.sh [host]
#
# Default host: cloud.staging.flapjack.foo
# To verify red-state (must FAIL): pass staging.flapjack.foo

set -euo pipefail

HOST="${1:-cloud.staging.flapjack.foo}"
FAILURES=0

echo "=== Staging browser host probe: $HOST ==="
echo ""

# (a) TLS SAN includes the target host
echo "--- Check (a): TLS SAN includes $HOST ---"
SAN_OUTPUT="$(echo | openssl s_client -connect "$HOST":443 -servername "$HOST" 2>/dev/null \
  | openssl x509 -noout -text 2>/dev/null \
  | grep -oE 'DNS:[^,]+' || true)"
echo "SANs found: $SAN_OUTPUT"
if echo "$SAN_OUTPUT" | grep -qF "DNS:$HOST"; then
  echo "PASS: SAN includes $HOST"
else
  echo "FAIL: SAN does not include $HOST"
  FAILURES=$((FAILURES + 1))
fi
echo ""

# (b) Issuer is Google Trust Services (Cloudflare Pages cert)
echo "--- Check (b): TLS issuer is Google Trust Services ---"
ISSUER="$(echo | openssl s_client -connect "$HOST":443 -servername "$HOST" 2>/dev/null \
  | openssl x509 -noout -issuer 2>/dev/null || true)"
echo "Issuer: $ISSUER"
if echo "$ISSUER" | grep -qi "Google Trust Services"; then
  echo "PASS: Issuer is Google Trust Services"
else
  echo "FAIL: Issuer is not Google Trust Services (got: $ISSUER)"
  FAILURES=$((FAILURES + 1))
fi
echo ""

# (c) HTML body contains _app/immutable (SvelteKit marker)
echo "--- Check (c): HTML contains _app/immutable ---"
HTML_BODY="$(curl -s "https://$HOST/" 2>/dev/null || true)"
if echo "$HTML_BODY" | grep -qF "_app/immutable"; then
  echo "PASS: HTML contains _app/immutable (SvelteKit app)"
else
  echo "FAIL: HTML does not contain _app/immutable (not the SvelteKit app)"
  FAILURES=$((FAILURES + 1))
fi
echo ""

# Summary
echo "=== Result: $FAILURES failure(s) ==="
if [ "$FAILURES" -gt 0 ]; then
  echo "FAILED — $HOST does not satisfy the staging browser host contract"
  exit 1
fi
echo "PASSED — $HOST satisfies the staging browser host contract"
exit 0
