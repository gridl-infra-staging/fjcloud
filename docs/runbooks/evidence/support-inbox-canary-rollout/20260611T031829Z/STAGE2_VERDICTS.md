# Stage 2 Verdicts

target_env=staging
HEAD_SHA=7e5db7f560177fd99358d7ba34810f5afa24a91e
ORIGIN_MAIN_SHA=7e5db7f560177fd99358d7ba34810f5afa24a91e
disposition=blocked on canary

## Commands

- export FJCLOUD_SECRET_FILE="${FJCLOUD_SECRET_FILE:-.secret/.env.secret}"
- source scripts/lib/env.sh && load_env_file "$FJCLOUD_SECRET_FILE"
- unset inherited AWS credential environment variables before rerun so the project secret file, not inherited shell state, owns AWS auth.
- set -o pipefail; source scripts/lib/env.sh && load_env_file "$FJCLOUD_SECRET_FILE" && bash scripts/probe_canary_live_state.sh staging --json > "$EVIDENCE_DIR/probe_canary_live_state_staging.json" 2> "$EVIDENCE_DIR/probe_canary_live_state_staging.stderr.log"; CANARY_RC=$?; printf 'CANARY_RC=%s\n' "$CANARY_RC" > "$EVIDENCE_DIR/probe_canary_live_state_staging.exitcode"
- set -o pipefail; source scripts/lib/env.sh && load_env_file "$FJCLOUD_SECRET_FILE" && ENVIRONMENT=staging bash scripts/canary/support_email_deliverability.sh > "$EVIDENCE_DIR/support_email_deliverability.stdout.log" 2> "$EVIDENCE_DIR/support_email_deliverability.stderr.log"; SUPPORT_EMAIL_RC=$?; printf 'SUPPORT_EMAIL_RC=%s\n' "$SUPPORT_EMAIL_RC" > "$EVIDENCE_DIR/support_email_deliverability.exitcode"

## Canary Live State

CANARY_RC=1
CANARY_JSON_FOUND=1
CANARY_JSON_VALID=1
CANARY_READY=false
CANARY_ALARMS_STATUS=pass
CANARY_ALL_CHECKS_PASS=false
CANARY_FAILED_CHECKS=errors_24h
canary_disposition=blocked

## Support Email Deliverability

SUPPORT_EMAIL_RC=0
SUPPORT_EMAIL_JSON_FOUND=1
SUPPORT_EMAIL_JSON_VALID=1
SUPPORT_EMAIL_PASSED=true
SUPPORT_EMAIL_AUTH_VERDICT_PASSED=true
SUPPORT_EMAIL_FIRST_FAILED_STEP=
SUPPORT_EMAIL_FIRST_FAILED_DETAIL=
support_email_disposition=green

## Runtime Environment Note

Initial captures inherited stale AWS credential variables from the caller environment. The final captures unset inherited AWS credential variables before loading the authorized project secret file, preserving the existing secret-loading owner while avoiding caller-state pollution.
