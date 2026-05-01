---
created: 2026-04-30
updated: 2026-04-30
---

# SES bounce/complaint e2e probe — staging — 2026-04-30T23:44Z

Status: **partial** — discovered two real launch blockers in the SES feedback path while running the e2e probe. First blocker fixed; second still open.

## Probe attempt

Inline standalone probe ran on staging API host via SSM-exec. Source: `/tmp/ses_bounce_probe_inline.sh`. Targeted recipient: `bounce@simulator.amazonses.com`.

The probe seeded a customer row with the simulator address, fired `POST /admin/broadcast`, polled `email_suppression`, and checked `audit_log`.

## Finding 1 — IAM policy missing `configuration-set` resource (FIXED)

**Symptom.** All 22 broadcast sends returned `failure_count: 22, success_count: 0`. Direct `aws sesv2 send-email --configuration-set-name "$SES_CONFIGURATION_SET" ...` from the staging host failed with:

```
AccessDeniedException ... User `arn:aws:sts::213880904778:assumed-role/fjcloud-instance-role/...'
is not authorized to perform `ses:SendEmail' on resource
`arn:aws:ses:us-east-1:213880904778:configuration-set/fjcloud-staging-flapjack-foo-feedback'
```

**Mechanism.** Apr 29 commit `d8c81ce7` ("Add SES suppression-aware send path and broadcast outcomes") attached `.configuration_set_name(&self.configuration_set_name)` unconditionally to every `SendEmail` call in `infra/api/src/services/email.rs:284`. SES authorises `SendEmail` against BOTH the identity ARN and the configuration-set ARN as separate resources. The instance role's `fjcloud-ses-send` inline policy granted only `identity/flapjack.foo`, so every outbound send from staging API has been silently denied since 2026-04-29.

**Scope.** Every SES email path through `SesEmailService::send_html_email` was affected: signup verification emails, password resets, invoice notifications, broadcasts, suppression-aware retries. None of this surfaced earlier because:
- Unit tests use `MockEmailService`, not the live SES client.
- `validate-stripe.sh` doesn't exercise outbound email.
- The Stripe Stage 5 runtime probe didn't include a real customer email send.
- Existing staging customers all use `@example.com` / `@example.test` test emails which SES wouldn't deliver to anyway, masking the IAM failure mode.

**Fix.** Updated `ops/iam/fjcloud-instance-role.tf` to include the configuration-set ARN in the policy `Resource` list:

```
"arn:aws:ses:us-east-1:213880904778:identity/flapjack.foo",
"arn:aws:ses:us-east-1:213880904778:configuration-set/fjcloud-*"
```

Applied directly via `aws iam put-role-policy --role-name fjcloud-instance-role --policy-name fjcloud-ses-send` (Terraform state for `ops/iam/` is empty / managed out-of-band; reconciling state drift is a separate cleanup task captured below).

**Verification.** Direct `aws sesv2 send-email` with `--configuration-set-name` from the staging host now returns `MessageId: 0100019de0cdc3d8-…`. SES accepts the call.

## Finding 2 — SNS subscription stuck in `PendingConfirmation` (OPEN)

**Symptom.** After Finding 1 was fixed and a real outbound send succeeded, no `email_suppression` row appeared. Investigation revealed the SNS HTTPS subscription `arn:aws:sns:us-east-1:213880904778:fjcloud-ses-feedback-staging` → `https://api.flapjack.foo/webhooks/ses/sns` is in `SubscriptionArn=PendingConfirmation` state.

A re-subscribe attempt triggered SNS to redeliver the `SubscriptionConfirmation` to the endpoint. Staging API logs (`request_id=1e52b7c4-37ff-4372-80f4-786842c74d04` at `2026-04-30T23:52:09Z`) show the handler returned **HTTP 400** in 13ms. The handler's signature verification or URL validation is rejecting the confirmation request.

**Mechanism (hypothesis).** `infra/api/src/routes/webhooks.rs::ses_sns_webhook` runs `validate_sns_url` on `SigningCertURL` and `SubscribeURL`, then `verify_sns_signature` (fetches the cert and verifies the canonicalized message). One of these is rejecting AWS's own SubscriptionConfirmation — most likely the URL allowlist or a cert-fetch path issue. 13ms is too short to indicate a network fetch, suggesting URL allowlist rejection.

**Impact.** Without subscription confirmation, no SES bounce/complaint events are delivered to our endpoint, so the `email_suppression` and `audit_log` side effects never fire, even when outbound sends generate real bounces. The end-to-end suppression path remains unproven.

**Next step (out of scope for this session's evidence capture).** Diagnose the 400 with debug-level logging on the SNS handler against a real SubscriptionConfirmation payload. Likely fix is a tightened `validate_sns_url` that accidentally rejects the AWS-region-suffixed SNS cert URL. Then re-trigger subscription confirmation; the existing handler logic (`confirm_subscription`) should land it in `Confirmed` state.

## Follow-ups recorded

- IAM Terraform-state drift in `ops/iam/`: state is empty, but the role + policies exist in AWS. Future Terraform runs will report adds. Either import existing resources into state or move IAM management to a fresh project that tracks state cleanly.
- SNS handler 400 on SubscriptionConfirmation — see Finding 2 above. Tracked separately.
- Once Finding 2 is closed, re-run the inline probe + capture suppression + audit row evidence.

## Artifacts

- `probe_stdout.log`, `probe_stderr.log` — first probe run (failed at email_suppression query due to stale `reason` column name; superseded by IAM finding)
- `/tmp/ses_bounce_probe_inline.sh` — inline probe source for repeatability (not committed; checked-in equivalent is `scripts/probe_ses_bounce_complaint_e2e.sh` once dependencies are present on the host)
