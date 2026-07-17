# GAP_SPEC - Stage 4 Section 1 In-VPC Rerun

Bundle: `docs/runbooks/evidence/ses-coverage-a1/20260603T033009Z_in_vpc_rerun`

## Non-Green Rows

- `verify_email_clickthrough`: rc=1 pass=0
  - Classification: `repo_owned_prerequisite`
  - Smallest owner path: `scripts/probe_verify_email_clickthrough_e2e.sh`
  - Observed detail: No TERMINUS line; log shows email_verified_at was not set after clickthrough polling.

- `password_reset_clickthrough`: rc=1 pass=0
  - Classification: `repo_owned_prerequisite`
  - Smallest owner path: `scripts/probe_password_reset_clickthrough_e2e.sh`
  - Observed detail: No TERMINUS line; log shows password_reset_token was not cleared after reset polling.

- `dunning_email_inbox`: rc=1 pass=0
  - Classification: `repo_owned_prerequisite`
  - Smallest owner path: `scripts/probe_dunning_email_inbox_e2e.sh`
  - Observed detail: No dunning inbox TERMINUS and final JSON result is failed/rehearsal_reset_failed.
  - Probe classification: `rehearsal_reset_failed`
  - Probe detail: dunning owner script exited 1

- `ses_bounce`: rc=1 pass=0
  - Classification: `repo_owned_prerequisite`
  - Smallest owner path: `scripts/probe_ses_bounce_complaint_e2e.sh`
  - Observed detail: Final JSON passed=false; first customer_broadcast live send returned HTTP 401.
  - Probe passed field: `false`
  - First failed step: `first_live_send` - First broadcast call failed for subject 'fjcloud-ses-bounce-complaint-probe-bounce-20260603T033325Z-739239-first': [customer-broadcast] ERROR: broadcast request failed with HTTP 401.

- `ses_complaint`: rc=1 pass=0
  - Classification: `repo_owned_prerequisite`
  - Smallest owner path: `scripts/probe_ses_bounce_complaint_e2e.sh`
  - Observed detail: Final JSON passed=false; first customer_broadcast live send returned HTTP 401.
  - Probe passed field: `false`
  - First failed step: `first_live_send` - First broadcast call failed for subject 'fjcloud-ses-bounce-complaint-probe-complaint-20260603T033330Z-739428-first': [customer-broadcast] ERROR: broadcast request failed with HTTP 401.

- `staging_dunning_delivery`: rc=1 pass=0
  - Classification: `repo_owned_prerequisite`
  - Smallest owner path: `scripts/validate_staging_dunning_delivery.sh`
  - Observed detail: Final JSON result=failed; reset flow reported test_tenant_not_found for allowlisted tenant.
  - Probe classification: `rehearsal_reset_failed`
  - Probe detail: Reset flow failed for tenant 193638a5-35f7-407f-a734-3f73de224336: test_tenant_not_found — No stripe_customer_id was found for tenant 193638a5-35f7-407f-a734-3f73de224336.
  - First failed step: `reset_test_state` - {"result":"blocked","classification":"test_tenant_not_found","detail":"No stripe_customer_id was found for tenant 193638a5-35f7-407f-a734-3f73de224336.","artifact_dir":"/tmp/fjcloud_staging_billing_rehearsal_20260603T033335Z_739686","planned_steps":["metering collection", "aggregation job", "invoice finalization", "Stripe test webhook delivery", "invoice paid reconciliation", "email evidence capture"],"steps":[{"name":"preflight","result":"blocked","classification":"not_run","detail":"Preflight did not run."},{"name":"metering_evidence","result":"blocked","classification":"not_run","detail":"Metering evidence did not run."},{"name":"live_mutation_guard","result":"blocked","classification":"test_tenant_not_found","detail":"No stripe_customer_id was found for tenant 193638a5-35f7-407f-a734-3f73de224336."},{"name":"live_mutation_attempt","result":"blocked","classification":"test_tenant_not_found","detail":"Reset flow was not completed."}],"elapsed_ms":682}

## Open Questions

- Are the deployed staging API `ADMIN_KEY` and `/fjcloud/staging/admin_key` still expected to match for `/admin/broadcast`, or did admin auth rotate without the SSM parameter used by this rerun?
- Is `FJCLOUD_TEST_TENANT_IDS` still the intended allowlist for June 2026 dunning rehearsal, given the first allowlisted tenant lacks `stripe_customer_id` in staging?
- Do the clickthrough failures indicate an API-side state-transition regression, a stale `APP_BASE_URL`/routing mismatch, or a probe expectation that no longer matches the deployed flow?
