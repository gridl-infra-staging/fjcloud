# Organic Alert Dispatch Probe Summary

- Date (UTC): 2026-05-06T08:49:23Z
- Result: PASS
- Exit code: 0
- Deployed SHA (SSM /fjcloud/staging/last_deploy_sha): 5a57ea6a280a1d63b54957b3732dcf8cc0a08c2e
- API URL: https://api.flapjack.foo
- Seed customer email: organic-alert-probe-20260506T084923Z-18708@example.invalid
- Seed customer UUID: 6f394900-ba8d-440c-aa36-d4b1f871918e
- Seed invoice UUID: 8d5c33e3-6a8f-47e3-a1ef-295f6b0664ce
- Seed stripe_invoice_id: in_organic_probe_20260506T084923Z_18708
- Replay command: bash scripts/stripe_webhook_replay_fixture.sh --run --allow-staging-target --target-url https://api.flapjack.foo/webhooks/stripe --event-type invoice.payment_failed --invoice-id in_organic_probe_20260506T084923Z_18708 --next-payment-attempt 1778060979 --attempt-count 1
- Alert query result: 248d0c12-2ae8-4680-9813-80663548b198|sent
- Cleanup confirmation: deleted captured rows only
- Probe stdout log: docs/runbooks/evidence/alert-delivery/20260506T084923Z_organic_dispatch_probe/probe_stdout.log
- Probe stderr log: docs/runbooks/evidence/alert-delivery/20260506T084923Z_organic_dispatch_probe/probe_stderr.log
- Failure alert rows: docs/runbooks/evidence/alert-delivery/20260506T084923Z_organic_dispatch_probe/failure_alert_rows.txt
- Failure journalctl capture: docs/runbooks/evidence/alert-delivery/20260506T084923Z_organic_dispatch_probe/failure_journalctl_fjcloud_api.txt
- Detail: Alert persisted with delivery_status='sent'.
