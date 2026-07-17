# Stage 1 Commands

- export FJCLOUD_SECRET_FILE="${FJCLOUD_SECRET_FILE:-.secret/.env.secret}"
- test -f "$FJCLOUD_SECRET_FILE"
- set -o pipefail; FJCLOUD_SECRET_FILE="$FJCLOUD_SECRET_FILE" bash scripts/probe_live_state.sh > "$EVIDENCE_DIR/probe_live_state.stdout.log" 2> "$EVIDENCE_DIR/probe_live_state.stderr.log"; PROBE_RC=$?; printf 'PROBE_RC=%s\n' "$PROBE_RC" > "$EVIDENCE_DIR/probe_live_state.exitcode"
- LIVE_STATE_DIR="$(ls -td docs/live-state/[0-9]*T[0-9]*Z 2>/dev/null | head -n 1)"
- LIVE_STATE_SUMMARY="$LIVE_STATE_DIR/SUMMARY.md"
- cp "$LIVE_STATE_SUMMARY" "$EVIDENCE_DIR/live_state_SUMMARY.md"
- source scripts/lib/env.sh && load_env_file "$FJCLOUD_SECRET_FILE"
- set -o pipefail; source scripts/lib/env.sh && load_env_file "$FJCLOUD_SECRET_FILE" && ENVIRONMENT=staging bash scripts/canary/support_email_deliverability.sh > "$EVIDENCE_DIR/support_email_deliverability.stdout.log" 2> "$EVIDENCE_DIR/support_email_deliverability.stderr.log"; SUPPORT_EMAIL_RC=$?; printf 'SUPPORT_EMAIL_RC=%s\n' "$SUPPORT_EMAIL_RC" > "$EVIDENCE_DIR/support_email_deliverability.exitcode"
- unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_REGION
- set -o pipefail; source scripts/lib/env.sh && load_env_file "$FJCLOUD_SECRET_FILE" && bash scripts/probe_canary_live_state.sh staging --json > "$EVIDENCE_DIR/probe_canary_live_state_staging.json" 2> "$EVIDENCE_DIR/probe_canary_live_state_staging.stderr.log"; CANARY_RC=$?; printf 'CANARY_RC=%s\n' "$CANARY_RC" > "$EVIDENCE_DIR/probe_canary_live_state_staging.exitcode"
- unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_REGION
- set -o pipefail; source scripts/lib/env.sh && load_env_file "$FJCLOUD_SECRET_FILE" && ENVIRONMENT=staging bash scripts/canary/support_email_deliverability.sh > "$EVIDENCE_DIR/support_email_deliverability.stdout.log" 2> "$EVIDENCE_DIR/support_email_deliverability.stderr.log"; SUPPORT_EMAIL_RC=$?; printf 'SUPPORT_EMAIL_RC=%s\n' "$SUPPORT_EMAIL_RC" > "$EVIDENCE_DIR/support_email_deliverability.exitcode"

## Stage 3 commands

### seed_synthetic_traffic.sh --tenant A --dry-run
```
set -o pipefail; bash scripts/launch/seed_synthetic_traffic.sh --tenant A --dry-run > "$EVIDENCE_DIR/seed_synthetic_dry_run_tenant_a.stdout.log" 2> "$EVIDENCE_DIR/seed_synthetic_dry_run_tenant_a.stderr.log"; SEED_DRY_RUN_RC=$?; printf 'SEED_DRY_RUN_RC=%s\n' "$SEED_DRY_RUN_RC" > "$EVIDENCE_DIR/seed_synthetic_dry_run_tenant_a.exitcode"
```

### post-lane canary probe
```
set -o pipefail; source scripts/lib/env.sh && load_env_file "$FJCLOUD_SECRET_FILE" && bash scripts/probe_canary_live_state.sh staging --json > "$EVIDENCE_DIR/probe_canary_post_lane_staging.json" 2> "$EVIDENCE_DIR/probe_canary_post_lane_staging.stderr.log"; POST_LANE_CANARY_RC=$?; printf 'POST_LANE_CANARY_RC=%s\n' "$POST_LANE_CANARY_RC" > "$EVIDENCE_DIR/probe_canary_post_lane_staging.exitcode"
```
