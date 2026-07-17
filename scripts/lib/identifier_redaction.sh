#!/usr/bin/env bash
# Shared identifier-redaction helper.
#
# Stripe/Privacy.com object IDs are not credentials in the secret-key sense
# but they are PII-adjacent live-mode identifiers. Evidence bundles under
# docs/runbooks/ are synced to public mirrors via .debbie.toml, so identifiers
# headed for those bundles flow through this helper. Returns "[REDACTED]" for
# any non-empty input, an empty string for empty input.

redact_identifier() {
    local value="${1:-}"
    if [ -n "$value" ]; then
        printf '[REDACTED]\n'
        return
    fi
    printf '\n'
}
