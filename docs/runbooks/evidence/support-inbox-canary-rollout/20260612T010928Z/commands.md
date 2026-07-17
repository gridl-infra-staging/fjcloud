# Stage 2 Commands

- `git fetch origin main`
- `git switch --detach origin/main`
- `mkdir -p docs/runbooks/evidence/support-inbox-canary-rollout/20260612T010928Z`
- `git rev-parse HEAD > provenance.env HEAD_SHA (5c1281182f045fd6c3f8c948134915cb165bfeaa)`
- `git rev-parse origin/main > provenance.env ORIGIN_MAIN_SHA (5c1281182f045fd6c3f8c948134915cb165bfeaa)`
- `bash scripts/probe_live_state.sh`
- `cp docs/live-state/20260612T010939Z/SUMMARY.md docs/runbooks/evidence/support-inbox-canary-rollout/20260612T010928Z/live_state_SUMMARY.md`
- `write LIVE_STATE_DIR=docs/live-state/20260612T010939Z and LIVE_STATE_SUMMARY=docs/live-state/20260612T010939Z/SUMMARY.md to live_state_pointer.env`
- `source scripts/lib/env.sh; load_env_file "$FJCLOUD_SECRET_FILE"; source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)`
- `write public-safe env contract to docs/runbooks/evidence/support-inbox-canary-rollout/20260612T010928Z/seed_synthetic_env_contract_public.env`
- `probe AWS STS after load_env_file .secret/.env.secret (InvalidClientTokenId)`
- `probe AWS STS after loading .secret/stuart-cli_accessKeys.csv (InvalidClientTokenId)`
- `write STAGE2_VERDICTS.md with blocked_before_execute disposition`

## Stage 3 Commands

- `sed -n '1,220p' docs/runbooks/evidence/support-inbox-canary-rollout/20260612T010928Z/provenance.env`
- `sed -n '1,260p' docs/runbooks/evidence/support-inbox-canary-rollout/20260612T010928Z/commands.md`
- `sed -n '1,220p' docs/runbooks/evidence/support-inbox-canary-rollout/20260612T010928Z/STAGE2_VERDICTS.md`
- `rg -n "final_execute_disposition|blocked_before_execute|tenant_mapping|seeder_start|SEEDER_START_TS|stage3_seeder_start_ts_source" docs/runbooks/evidence/support-inbox-canary-rollout/20260612T010928Z scripts/launch/seed_synthetic_traffic.sh scripts/tests/seed_synthetic_traffic_test.sh infra/migrations/003_usage_records.sql`
- `test -s docs/runbooks/evidence/support-inbox-canary-rollout/20260612T010928Z/usage_records_attribution_blocked.md` => exit 1 before artifact creation
- `write usage_records_attribution_blocked.md with blocked_prerequisite classification`
- `test -s docs/runbooks/evidence/support-inbox-canary-rollout/20260612T010928Z/usage_records_attribution_blocked.md` => exit 0 after artifact creation
- `grep -q "final_classification: blocked_prerequisite" docs/runbooks/evidence/support-inbox-canary-rollout/20260612T010928Z/usage_records_attribution_blocked.md` => exit 0
- final_classification: blocked_prerequisite

## Stage 4 Commands

- `git rev-parse HEAD` => d507c91ef36508ac3591d0b6f6a259d1d6762825
- `write STAGE4_VERDICTS.md skeleton with pinned_HEAD_SHA and STAGE=stage4`
- `bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging` => exit 254 (no output)
- `aws sts get-caller-identity --output json` => exit 254, InvalidClientTokenId
- CSV fallback `.secret/stuart-cli_accessKeys.csv` via `aws sts get-caller-identity` => exit 254, InvalidClientTokenId
- `write STAGE4_VERDICTS.md with final_classification: blocked_prerequisite`
- final_classification: blocked_prerequisite (same credential blocker as Stage 2/3)

## Stage 5

- Evidence bundle selected: `docs/runbooks/evidence/support-inbox-canary-rollout/20260612T010928Z/`; no newer Stage 2-4 bundle from this lane was present.
- `set -o pipefail; source scripts/lib/env.sh && load_env_file "${FJCLOUD_SECRET_FILE:-.secret/.env.secret}" && ENVIRONMENT=staging bash scripts/canary/support_email_deliverability.sh > "$EVIDENCE_DIR/support_email_deliverability_stage5.stdout.log" 2> "$EVIDENCE_DIR/support_email_deliverability_stage5.stderr.log"; printf '%s\n' "$?" > "$EVIDENCE_DIR/support_email_deliverability_stage5.exitcode"` => exit 1.
- Generated artifacts: `support_email_deliverability_stage5.stdout.log`, `support_email_deliverability_stage5.stderr.log`, `support_email_deliverability_stage5.exitcode`, `support_email_deliverability_stage5_verdict.env`.
- `support_email_deliverability_stage5_verdict.env` final classification: `runtime`.
- `write SUMMARY.md with Stage 2 blocked execute, Stage 3 blocked usage attribution, Stage 4 blocked canary root-cause classification, and Stage 5 support-email rerun verdict`.
- Final disposition: blocked; not a green launch claim because support-email rerun is `runtime`, synthetic execute remains `blocked_before_execute`, `usage_records` attribution remains `blocked_prerequisite`, and customer-loop canary root-cause classification remains `blocked_prerequisite`.
