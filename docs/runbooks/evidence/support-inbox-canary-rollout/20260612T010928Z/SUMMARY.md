# Support Inbox + Synthetic Canary Rollout - Stage 5 Evidence Summary

## Provenance

| Field | Value |
| --- | --- |
| Target environment | staging |
| Evidence bundle | `docs/runbooks/evidence/support-inbox-canary-rollout/20260612T010928Z/` |
| CREATED_AT_UTC | `2026-06-12T01:09:28Z` |
| Stage 2 pinned HEAD_SHA | `5c1281182f045fd6c3f8c948134915cb165bfeaa` |
| Stage 2 ORIGIN_MAIN_SHA | `5c1281182f045fd6c3f8c948134915cb165bfeaa` |
| Stage 4 pinned HEAD_SHA | `d507c91ef36508ac3591d0b6f6a259d1d6762825` |

## Commands

| Lane | Command | Exit code | Artifacts |
| --- | --- | --- | --- |
| Stage 2 live synthetic execute prerequisite | `bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging` | 254 | `hydrate_seeder_env_from_ssm_staging.exitcode`, `hydrate_seeder_env_from_ssm_staging.stderr.log`, `STAGE2_VERDICTS.md` |
| Stage 3 usage attribution prerequisite review | read Stage 2 verdict and mapping/start timestamp artifacts | 0 | `usage_records_attribution_blocked.md` |
| Stage 4 customer-loop canary root-cause prerequisite | `bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging`; `aws sts get-caller-identity --output json` | 254 | `STAGE4_VERDICTS.md`, `aws_credential_blocker_public.env` |
| Stage 5 support-email deliverability rerun | `set -o pipefail; source scripts/lib/env.sh && load_env_file "${FJCLOUD_SECRET_FILE:-.secret/.env.secret}" && ENVIRONMENT=staging bash scripts/canary/support_email_deliverability.sh` | 1 | `support_email_deliverability_stage5.stdout.log`, `support_email_deliverability_stage5.stderr.log`, `support_email_deliverability_stage5.exitcode`, `support_email_deliverability_stage5_verdict.env` |

## Verdicts

| Lane | Verdict | Detail |
| --- | --- | --- |
| Support email deliverability - Stage 5 currency rerun | runtime | Exit code `1`; `support_email_deliverability_stage5_verdict.env` records `SUPPORT_EMAIL_STAGE5_JSON_PASSED=false` and `SUPPORT_EMAIL_STAGE5_AUTH_VERDICT=failed`. This does not overwrite the older green support-email evidence. |
| Synthetic traffic live execute | blocked | Stage 2 records `final_execute_disposition: blocked_before_execute`; AWS credential probes returned `InvalidClientTokenId` before any live mutation. |
| `usage_records` attribution | blocked | Stage 3 records `final_classification: blocked_prerequisite`; no Tenant A mapping artifact or seeder start timestamp exists because execute was not reached. |
| Customer-loop canary root-cause classification | blocked | Stage 4 records `final_classification: blocked_prerequisite`; the same AWS credential blocker prevented Lambda and CloudWatch evidence capture. |

## Final disposition

**blocked** - This bundle is not a green launch claim. The lane remains open because the Stage 5 support-email rerun is `runtime`, Stage 2 synthetic execute is blocked before mutation by invalid AWS credentials, Stage 3 `usage_records` attribution lacks the required mapping/start timestamp inputs, and Stage 4 customer-loop canary root-cause classification remains blocked on the same credential prerequisite.

ROADMAP status remains `Open seam` until a credentialed rerun proves support-email deliverability, live synthetic execute, `usage_records` attribution, and canary root-cause evidence green at HEAD.
