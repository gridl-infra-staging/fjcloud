# Email Production (SES)

## SES Setup

### Required Environment Variables

| Variable           | Description             | Example               |
| ------------------ | ----------------------- | --------------------- |
| `SES_FROM_ADDRESS` | Verified sender address | `system@flapjack.foo` |
| `SES_REGION`       | AWS region for SES      | `us-east-1`           |

At startup, `main.rs` captures the SES env into `StartupEnvSnapshot` and validates it via `SesConfig::from_reader(...)`. In production, if either value is missing or empty the API **will not start** (fail-fast). In local dev mode (`ENVIRONMENT=local`/`dev`/`development` plus `NODE_SECRET_BACKEND=memory`), when both are absent startup uses `NoopEmailService` instead — emails are logged but not sent.

### AWS Credential Chain

The API uses `aws_config::load_defaults()` which resolves credentials via the standard AWS chain:

1. Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`)
2. Shared credentials file (`~/.aws/credentials`)
3. IAM role via IMDS (EC2 instance profile / ECS task role)

The loaded config is shared across all AWS clients (EC2, Route53, SSM, SES).

### How SES Wires at Startup (`main.rs`)

1. `StartupEnvSnapshot::from_env()` captures the SES env once, then `SesConfig::from_reader(...)` validates `SES_FROM_ADDRESS` and `SES_REGION`
2. `aws_config::load_defaults()` loads the shared AWS SDK config
3. SES SDK config is built from the shared config with the SES-specific region override
4. `SesEmailService::new(ses_client, from_address)` is created and stored in `AppState`
5. `tracing::info!("SES email service configured")` is logged (no secrets)

### Required IAM Permissions

The SES client needs `ses:SendEmail` permission. Minimal IAM policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ses:SendEmail",
      "Resource": "arn:aws:ses:us-east-1:ACCOUNT_ID:identity/flapjack.foo"
    }
  ]
}
```

## Sandbox vs Production Mode

### Read-Only SES Readiness Contract (Stage 1)

Use one canonical SES identity input source for readiness checks: `SES_FROM_ADDRESS`.

```bash
scripts/validate_ses_readiness.sh --identity "$SES_FROM_ADDRESS" --region "$SES_REGION"
```

If `--region` is omitted, `scripts/validate_ses_readiness.sh` defaults to `SES_REGION` when it is set.

The command is read-only and only calls:

- `aws sesv2 get-account`
- `aws sesv2 get-email-identity`

Expected machine-readable JSON steps:

- `get_account`
- `sending_enabled`
- `production_access`
- `identity_verified`
- `dkim_verified`
- `unproven_deliverability_items`

Interpretation rules:

- `get_account` must pass.
- `sending_enabled` must be `true`.
- `production_access` reports `ProductionAccessEnabled`; `false` means sandbox and is reported explicitly so sandbox cannot be mistaken for production deliverability.
- `identity_verified` must report `SUCCESS`.
- `dkim_verified` must report `SUCCESS` for domain identities; for email identities it reports that DKIM verification is not applicable.
- `identity_verified` and `dkim_verified` detail state whether the checked identity was an email identity or a domain identity.
- `unproven_deliverability_items` documents boundaries that Stage 1 does not prove: SPF, MAIL FROM, bounce/complaint handling, first-send evidence, and inbox-receipt evidence.

For staging domain identity and DKIM proof, cross-reference `ops/terraform/tests_stage7_runtime_smoke.sh::assert_ses_identity_verified` instead of duplicating runtime-smoke procedures here.

### Canonical Live Deliverability Evidence Wrapper (Stage 2+)

Use `scripts/launch/ses_deliverability_evidence.sh` as the canonical operator entrypoint for credentialed SES deliverability evidence:

```bash
bash scripts/launch/ses_deliverability_evidence.sh \
  --artifact-dir ops/terraform/artifacts/ses_deliverability \
  --env-file /path/to/redacted/operator/env.file
```

Before running the wrapper, make sure the chosen env file or ambient shell
actually provides the wrapper's canonical inputs:

- `SES_FROM_ADDRESS`
- `SES_REGION`
- optional `SES_TEST_RECIPIENT` when the safe recipient is not the sender or an
  explicitly chosen SES mailbox simulator address

AWS credentials alone are not enough for the wrapper to produce a meaningful `summary.json`. If `SES_FROM_ADDRESS` is missing, the wrapper blocks before it can delegate readiness. If `SES_REGION` is missing, the wrapper blocks readiness delegation, recipient preflight, and the canonical live-send seam.

Wrapper artifacts are run-scoped under the caller-supplied artifact root as
`fjcloud_ses_deliverability_evidence_<timestamp>_<pid>/...`, and `summary.json`
inside that run directory is the machine-readable source of truth.

Interpret `summary.json` fields as follows:

- `overall_verdict`: `fail` only when `send_attempt.status=fail`; `blocked` when any prerequisite state is blocked (`account_status`, `identity_status`, `recipient_preflight`, or `send_attempt`); otherwise `pass`.
- `sender`: resolved wrapper inputs (`from_address`, `region`) for this run.
- `account_status`: delegated readiness account summary (`status`, `detail`, `is_sandbox`).
- `identity_status`: delegated readiness sender-identity summary (`status`, `detail`).
- `recipient_preflight`: wrapper-owned recipient gate summary (`status`, `detail`, `source`, `recipient`, `is_mailbox_simulator`).
- `send_attempt`: canonical delegated seam summary (`status`, `detail`, `exit_code`, `named_test_marker_found`, `command`).
- `suppression_check`: explicit suppression lookup result (`not_checked` by default) and not a proxy for delivery outcomes.
- `deliverability_boundaries`: explicit unproven boundaries that remain open (SPF, MAIL FROM, bounce/complaint handling, first-send evidence, inbox-receipt proof).
- `redaction`: confirms sensitive values and full email bodies are redacted in wrapper artifacts.

Current verified Stage 1 truth snapshot as of 2026-04-23:

- Canonical SES env source path for current operator runs:
  `.secret/.env.secret` from repo root (or explicit `--env-file` override for alternate checkouts).
- Historical Stage 1 env source snapshot:
  `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret`.
- Canonical sender identity: `system@flapjack.foo`, using inherited `flapjack.foo` domain identity/DKIM readiness.
- Account readiness snapshot: `SendingEnabled=true` and `ProductionAccessEnabled=true (production access enabled)`.
- Checked-in Stage 1 boundary-proof owners: `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/reconciliation_summary.md` and `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/drift_blocker.md`; treat `docs/runbooks/evidence/ses-deliverability/20260423T202158Z_ses_boundary_proof_full.txt` as historical context only.
- Stage 3 first-send companion owner: `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/first_send_retrieval_status.md` records the wrapper run path and retrieval-owner status without closing first-send/inbox boundaries.
- Stage 4/5 bounce+complaint companion owners: `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/bounce_blocker.txt` and `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/complaint_blocker.txt` (or `bounce_event.json` / `complaint_event.json` if checked-in retrieval proof exists).
- Latest Stage 4 wrapper artifact (current source of truth): `/Users/stuart/.matt/projects/fjcloud_dev-cd6902f9/apr23_am_1_ses_deliverability_refined.md-4c6ea1bd/artifacts/stage_04_ses_deliverability/fjcloud_ses_deliverability_evidence_20260423T063739Z_63867/summary.json` reports `overall_verdict=pass` with `account_status.status=pass`, `identity_status.status=pass`, `recipient_preflight.status=pass`, and `send_attempt.status=pass`; `sender.from_address` / `sender.region` are intentionally redacted as `REDACTED` in the artifact.
- The preserved Stage 3 artifact is a blocked-path evidence run rather than a passing live-send proof: `/tmp/fjcloud_ses_stage3_F4LfPY/artifacts/fjcloud_ses_deliverability_evidence_20260423T010330Z_76079/summary.json` records `overall_verdict=blocked` with empty `sender` inputs and blocked prerequisite states.

### Check Current Account Status Directly

```bash
aws sesv2 get-account --region us-east-1
```

Key fields in the response:

- `SendingEnabled: true` — sending is active
- `ProductionAccessEnabled: true` — in **production mode**

### Sandbox Limitations

In sandbox mode, you can only send to **verified** email addresses or domains. To verify a recipient:

```bash
aws sesv2 create-email-identity --email-identity test@example.com --region us-east-1
```

### Request Production Access

```bash
aws sesv2 put-account-details \
  --production-access-enabled \
  --mail-type TRANSACTIONAL \
  --website-url "https://cloud.flapjack.foo" \
  --use-case-description "Transactional emails: email verification, password reset, invoices, quota warnings" \
  --additional-contact-email-addresses "hi@flapjack.foo,support@flapjack.foo" \
  --region us-east-1
```

AWS typically reviews within 24 hours. Check status with `aws sesv2 get-account`.

## Verify SES Identity And DKIM

```bash
aws sesv2 get-email-identity --email-identity "$SES_FROM_ADDRESS" --region "$SES_REGION"
```

Expected output includes:

- `VerifiedForSendingStatus: true`
- `IdentityType: EMAIL_ADDRESS` or `IdentityType: DOMAIN`

For `IdentityType: DOMAIN`, also confirm:

- `DkimAttributes.Status: SUCCESS`

When `SES_FROM_ADDRESS` is an address under a verified domain, such as
`system@flapjack.foo`, SES can send from that address through the parent
`flapjack.foo` identity. In that case, the email address itself can still show
as unverified in SES; the readiness script first checks the exact address, then
falls back to the parent domain identity and requires the domain verification
and DKIM status to be successful.

For domain identities, if DKIM is not verified, add the CNAME records shown in `DkimAttributes.Tokens` to DNS.

## Failure Triage

### Common SES Errors

| Error                                   | Cause                                                                 | Action                                                            |
| --------------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------- |
| `MessageRejected`                       | Recipient not verified (sandbox), content policy, or suppression list | Check sandbox status; verify recipient; review message content    |
| `AccountSendingPausedException`         | Account suspended due to bounces/complaints                           | Check SES console reputation dashboard; file support case         |
| `MailFromDomainNotVerifiedException`    | Domain identity not verified                                          | Run `get-email-identity` and verify DKIM records                  |
| `LimitExceededException` / `Throttling` | Sending rate exceeded                                                 | Check account sending limits with `get-account`; request increase |
| `ConfigurationSetDoesNotExistException` | Referenced config set doesn't exist                                   | We don't use config sets — should not occur                       |

### Where to Check

1. **SES Console** → Account dashboard: sending stats, reputation metrics, bounce/complaint rates
2. **CloudWatch Metrics** → `AWS/SES` namespace: `Send`, `Delivery`, `Bounce`, `Complaint`
3. **Application logs** — search for `email delivery failed` (the `EmailError::DeliveryFailed` message includes the SES SDK error type and request ID)

### Debugging a Failed Send

1. Check application logs for the `EmailError::DeliveryFailed` message — it includes the SDK error
2. Cross-reference the SES request ID in CloudWatch or SES event logs
3. If `MessageRejected`, check if we're in sandbox and the recipient is unverified

## CLI Command Reference

```bash
# Account status (sandbox vs production, sending limits)
aws sesv2 get-account --region us-east-1

# Configured identity status (verification; domain identities also show DKIM)
aws sesv2 get-email-identity --email-identity "$SES_FROM_ADDRESS" --region "$SES_REGION"

# Sending statistics (last 14 days)
aws sesv2 get-account --region us-east-1 --query 'SendQuota'

# List suppressed addresses (bounced/complained)
aws sesv2 list-suppressed-destinations --region us-east-1

# Remove an address from suppression list
aws sesv2 delete-suppressed-destination \
  --email-address user@example.com --region us-east-1
```

## Rollback / Startup Behavior

### Fail-Fast Startup

In production (including `NODE_SECRET_BACKEND=memory` without a local `ENVIRONMENT` label), if `SES_FROM_ADDRESS` or `SES_REGION` is missing or empty, the snapshot-backed `SesConfig::from_reader(...)` validation returns an error and the API exits immediately with a descriptive message. This prevents running in a state where email sends would silently fail.

The validation happens **before** any server socket is bound, so a misconfigured deploy will be visible instantly (process exits with non-zero status).

In local dev mode (`ENVIRONMENT=local`/`dev`/`development` plus `NODE_SECRET_BACKEND=memory`), when both SES vars are absent, startup substitutes `NoopEmailService` — emails are logged via `tracing` but not sent. This allows the API to start with zero external dependencies.

### Deployment Env Var Checklist

Before deploying, confirm these are set in the environment:

- [ ] `SES_FROM_ADDRESS` — the verified sender (e.g., `system@flapjack.foo`)
- [ ] `SES_REGION` — the SES region (e.g., `us-east-1`)
- [ ] AWS credentials available via one of the standard chain methods
- [ ] The configured SES sender identity is verified; if it is a domain identity, DKIM is passing

### Rollback

Email sending has no persistent state in the application — it's a stateless call to SES. If a bad deploy introduces email issues:

1. Revert to the previous binary (see [API Deployment](api-deployment.md) rollback procedure)
2. No database rollback needed — email is fire-and-forget from the app's perspective
3. Check SES dashboard for any reputation impact from the bad deploy

### Live Smoke Tests (Delegated Seam / Diagnostics)

Use `scripts/launch/ses_deliverability_evidence.sh` as the preferred operator evidence path. Direct cargo invocation is a diagnostic/delegated seam path only.

```bash
cd infra && cargo test -p api --test email_test \
  ses_live_smoke_sends_verification_email -- --ignored
```

The optional ignored test `infra/api/tests/email_test.rs::ses_live_smoke_sends_verification_email` remains the credentialed live-send seam the wrapper delegates to. Stage 1 does not run or replace this ignored live test.

Optionally set `SES_TEST_RECIPIENT` to send to a different safe recipient. If omitted, the wrapper attempts verified self-recipient discovery from `SES_FROM_ADDRESS` and blocks when no verified recipient can be proven.

Mailbox simulator recipients (`*@simulator.amazonses.com`) satisfy wrapper preflight and allow send-evidence runs without inbox-receipt proof.

In sandbox mode, non-simulator recipients must be verified; otherwise the wrapper reports recipient-preflight blocked and does not attempt the live-send seam.

## Inbound Test Inbox

Inbound SES operability uses a shared test inbox contract:

- Verified recipient domain: `test.flapjack.foo`
- Active receipt rule: `mailpail-to-s3`
- S3 sink: `s3://flapjack-cloud-releases/e2e-emails/`

Primary probe entrypoints:

- `scripts/validate_inbound_email_roundtrip.sh` — full outbound-to-inbound roundtrip (send probe, poll S3 sink, fetch RFC822, assert `Authentication-Results` verdicts).
- `scripts/probe_ses_simulator_send.sh` — send-only simulator probe for `bounce|complaint` destinations.
- `scripts/canary/support_email_deliverability.sh` — canary wrapper that delegates to the roundtrip probe.

Source contracts and parsers:

- `scripts/lib/test_inbox_helpers.sh`
- `scripts/lib/parse_inbound_auth_headers.py`

### Override Environment Variables

`scripts/validate_inbound_email_roundtrip.sh` supports the following overrides:

| Variable | Default | Purpose |
| --- | --- | --- |
| `INBOUND_ROUNDTRIP_S3_URI` | `s3://flapjack-cloud-releases/e2e-emails/` | S3 sink URI to poll for inbound RFC822 objects |
| `INBOUND_ROUNDTRIP_POLL_MAX_ATTEMPTS` | `30` | Maximum S3 poll attempts before timeout |
| `INBOUND_ROUNDTRIP_POLL_SLEEP_SEC` | `2` | Sleep interval (seconds) between poll attempts |
| `INBOUND_ROUNDTRIP_NONCE` | auto-generated | Explicit nonce override for deterministic probe IDs |
| `INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN` | `test.flapjack.foo` | Recipient domain for the roundtrip probe |
| `INBOUND_ROUNDTRIP_RECIPIENT_LOCALPART` | `roundtrip-<nonce>` | Recipient local part used to construct probe address |

### Simulator Destinations

Use mailbox simulator destinations for send-dispatch probes:

- `bounce@simulator.amazonses.com`
- `complaint@simulator.amazonses.com`

Acceptance criterion for simulator probes is a non-empty `MessageId` in the JSON output from `scripts/probe_ses_simulator_send.sh`.

Important boundary: simulator probes verify send-dispatch only. They do not verify handler-side-effect processing in fjcloud. See `docs/research/ses_bounce_complaint_gap.md` for the explicit open gap.

### Bounce/Complaint Handling Gap (Follow-on Owner Contract)

`bounce_complaint_handling=unproven`

This runbook remains the operator-facing contract for the gap. Keep deep rationale in `docs/research/ses_bounce_complaint_gap.md` and avoid duplicating a second analysis owner here.

Canonical staging proof owner for this boundary:

- `scripts/probe_ses_bounce_complaint_e2e.sh`

Probe contract:

- Required inputs: `bounce|complaint` mode plus one explicit staging env-file path.
- Env-file must provide `API_URL`, `ADMIN_KEY`, `DATABASE_URL` or `INTEGRATION_DB_URL`, `SES_FROM_ADDRESS`, and `SES_REGION`.
- Subject convention: the script owns the stable prefix `fjcloud-ses-bounce-complaint-probe` and appends a per-run suffix.
- Timeout contract: bounded SNS side-effect polling with `SES_PROBE_POLL_MAX_ATTEMPTS` (default `30`) and `SES_PROBE_POLL_SLEEP_SEC` (default `2`).
- Proof sequence:
  - First live send via `scripts/customer_broadcast.sh --live-send`.
  - Poll for webhook side effects and assert one suppression row (`email_suppression`) plus one correlated audit action in `audit_log`.
  - Second live send via `scripts/customer_broadcast.sh --live-send` and assert `/admin/broadcast` still returns `mode="live_send"` with non-zero `suppressed_count`.
  - Assert row-level suppression evidence in `email_log` for the second subject (`delivery_status='suppressed'`) at the dedicated simulator recipient.

Targeted validation commands:

```bash
bash scripts/tests/probe_ses_bounce_complaint_e2e_smoke.sh
bash scripts/tests/customer_broadcast_smoke.sh
cd infra && cargo test -p api --test admin_broadcast_test -- --ignored live_broadcast_suppressed_recipient_logs_suppressed_and_keeps_failure_count_for_real_failures
cd infra && cargo test -p api --test ses_bounce_complaint_handler_test -- --ignored
```

Status rule: do not promote this boundary based only on simulator dispatch checks; keep `bounce_complaint_handling=unproven` until staging evidence proves the full app path end-to-end.

### Evidence Interpretation

Use `docs/runbooks/evidence/ses-deliverability/` as the evidence tree for inbound probe outcomes.

Current baseline: `docs/runbooks/evidence/ses-deliverability/20260428T195818Z_deliverability_canary/` (captured via `source scripts/lib/env.sh && load_env_file .secret/.env.secret && bash scripts/canary/support_email_deliverability.sh` twice).
Baseline proof artifacts: `docs/runbooks/evidence/ses-deliverability/20260428T195818Z_deliverability_canary/run_1.json`, `run_2.json`, and `gate_summary.json`.
Stage 3 live roundtrip proof artifact remains: `docs/runbooks/evidence/ses-deliverability/20260428T194527Z_stage3_live_probe/roundtrip.json`.

Interpretation contract:

- `roundtrip.json` must contain steps `send_probe`, `poll_inbox_s3`, `fetch_rfc822`, and `auth_verdict`.
- `roundtrip.json` passes only when `auth_verdict` reports `dkim=pass`, `spf=pass`, and `dmarc=pass`.
- `simulator_bounce.json` and `simulator_complaint.json` contain `send_probe`.
- Simulator JSON passes only when `send_probe` includes a non-empty `message_id`/`MessageId`.
