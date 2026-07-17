# SES bounce/complaint suppression — live e2e GREEN proof

**Date:** 2026-05-01 19:29 UTC
**Mode:** bounce (against bounce@simulator.amazonses.com)
**Result:** PASSED (all 6 probe steps green, elapsed 6.9s)

## Three silent bugs that hid this path

This was the first GREEN run after fixing three independent bugs:

1. **cef6e9f6** (2026-04-30): IAM `fjcloud-ses-send` granted `ses:SendEmail` on
   the SES identity ARN only, not the configuration-set ARN. After d8c81ce7
   made every send attach the configuration set, SES denied every staging
   email send for ~36 hours.

2. **37091982** (2026-04-30): SNS canonical signing string omitted trailing
   `\n` on the final field. AWS spec emits `key\nvalue\n` for every field
   including the last; our string was one byte short. Every real
   SubscriptionConfirmation and Notification failed signature verification
   despite 14 unit tests passing (test fixture used the same buggy
   canonicalization).

3. **97f607a1** (2026-05-01): SesNotification parser used
   `#[serde(rename = "notificationType")]` but our SES terraform stack
   uses `aws_sesv2_configuration_set_event_destination` which publishes
   to SNS with `eventType` discriminator. AWS sent eventType, parser
   demanded notificationType, every real bounce/complaint was rejected
   with 400 BadRequest. Same fixture-pinned-the-bug pattern as #2 — 14
   integration tests passed because their JSON used notificationType too.

## What the GREEN run proves end-to-end

- Email broadcast via API: 22 sends, 22 successes (IAM fix verified in production)
- SES configuration set event destination: SNS notification delivered (terraform wiring works)
- SNS signature verification: passes (canonical fix verified in production)
- Handler parses SES event payload: succeeds (eventType fix verified in production)
- Handler writes suppression row: source='ses_sns_webhook', reason='bounce_permanent_general'
- Handler writes audit log row: action='ses_permanent_bounce_suppressed'
- Subsequent broadcast suppression: second send to same recipient enforces suppression (suppressed_count=1)

## Probe artifact

- Stdout: this SUMMARY.md (the probe's emit_result JSON is below for archival)
- Probe script + deps were uploaded to s3://fjcloud-releases-staging/probes/20260501T181937Z_bounce_e2e/
  and downloaded onto staging EC2 via SSM exec
- Run from staging EC2 (i.e. inside VPC) using /etc/fjcloud/env + synthesized API_URL

## Probe JSON

```json
{"passed":true,"steps":[{"name":"preflight","passed":true},{"name":"seed_probe_customer","passed":true},{"name":"first_live_send","passed":true},{"name":"poll_sns_side_effects","passed":true,"detail":"Observed suppression reason='bounce_permanent_general', source='ses_sns_webhook', and audit action 'ses_permanent_bounce_suppressed'."},{"name":"second_live_send","passed":true,"detail":"Second live broadcast completed; response suppressed_count='1'; email_log suppressed rows for probe recipient='1'."},{"name":"cleanup_probe_customer","passed":true}],"elapsed_ms":6946}
```

## Next

- Update `docs/research/ses_bounce_complaint_gap.md` to lift `bounce_complaint_handling=unproven` to `verified`
- Update PRIORITIES.md to remove the SES launch-blocker entry from Summary
- Run probe in `complaint` mode separately to verify the complaint path (handler is parameterized, expected to also work)
