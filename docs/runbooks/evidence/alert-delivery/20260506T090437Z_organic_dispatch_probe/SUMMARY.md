# Organic Alert Dispatch Probe Summary

- Date (UTC): 2026-05-06T09:04:37Z
- Result: PASS
- Exit code: 0
- Deployed SHA (SSM /fjcloud/staging/last_deploy_sha): 5a57ea6a280a1d63b54957b3732dcf8cc0a08c2e
- API URL: https://api.flapjack.foo
- Seed customer email: organic-alert-probe-20260506T090437Z-45416@example.invalid
- Seed customer UUID: b402eaf2-b118-4a34-b093-ad114ef3e164
- Seed invoice UUID: ad80dfac-a63c-4a4c-aa94-2707ea376bfb
- Seed stripe_invoice_id: in_organic_probe_20260506T090437Z_45416
- Replay command: bash scripts/stripe_webhook_replay_fixture.sh --run --allow-staging-target --target-url https://api.flapjack.foo/webhooks/stripe --event-type invoice.payment_failed --invoice-id in_organic_probe_20260506T090437Z_45416 --next-payment-attempt 1778061893 --attempt-count 1
- Alert query result: 51ff9a3c-d610-4945-aabb-06365be612f6|sent
- Cleanup confirmation: deleted captured rows only
- Probe stdout log: docs/runbooks/evidence/alert-delivery/20260506T090437Z_organic_dispatch_probe/probe_stdout.log
- Probe stderr log: docs/runbooks/evidence/alert-delivery/20260506T090437Z_organic_dispatch_probe/probe_stderr.log
- Failure alert rows: docs/runbooks/evidence/alert-delivery/20260506T090437Z_organic_dispatch_probe/failure_alert_rows.txt
- Failure journalctl capture: docs/runbooks/evidence/alert-delivery/20260506T090437Z_organic_dispatch_probe/failure_journalctl_fjcloud_api.txt
- Detail: Alert persisted with delivery_status='sent'.
