# Stage 2 Staging Webhook Continuity

- probe_started_at_utc: 2026-05-20T21:39:17Z
- command_shape_owner: chats/icg/evidence/may19_pm_3/06_webhook_verification_summary.md:3-24
- staging_trigger_command: STRIPE_API_KEY=*** stripe trigger invoice.payment_succeeded
- staging_webhook_endpoint_discovery: we_1TSoyTGXI8zVz4UHnp185FdS\thttps://api.flapjack.foo/webhooks/stripe\tenabled\tfalse
- sanctioned_staging_replay_command: STRIPE_WEBHOOK_SECRET=*** bash scripts/stripe_webhook_replay_fixture.sh --run --allow-staging-target --target-url https://api.staging.flapjack.foo/webhooks/stripe --timestamp 1779313157
- observation: Stripe staging-account endpoint discovery still resolves to `api.flapjack.foo`; to prove staging-host continuity after the sanctioned-host fix (`scripts/stripe_webhook_replay_fixture.sh:27`), this artifact uses the sanctioned staging replay path and captures staging-host journal evidence.

## Trigger CLI output (Stage 6 shape)
Checking for new versions...

A newer version of the Stripe CLI is available, please update to: v1.41.2
Setting up fixture for: customer
Running fixture for: customer
Setting up fixture for: payment_method
Running fixture for: payment_method
Setting up fixture for: invoiceitem
Running fixture for: invoiceitem
Setting up fixture for: invoice
Running fixture for: invoice
Setting up fixture for: invoice_pay
Running fixture for: invoice_pay
Trigger succeeded! Check dashboard for event details.

## Sanctioned staging replay output
{"result":"passed","classification":"webhook_post_succeeded","mode":"run","target_url":"https://api.staging.flapjack.foo/webhooks/stripe","detail":"webhook endpoint returned HTTP 200","event_id":"evt_replay_1779313157","timestamp":"1779313157"}

## Staging-host journal lines near replay window
May 20 21:39:17 fjcloud-api-staging fjcloud-api[1027699]: {"timestamp":"2026-05-20T21:39:17.598214Z","level":"DEBUG","fields":{"message":"ignoring webhook event type: customer.updated"},"target":"api::routes::webhooks","span":{"method":"POST","path":"/webhooks/stripe","request_id":"da417e0c-4ba1-4e99-83bc-7c004c85fe20","tenant_id":"-","name":"request"},"spans":[{"method":"POST","path":"/webhooks/stripe","request_id":"da417e0c-4ba1-4e99-83bc-7c004c85fe20","tenant_id":"-","name":"request"}]}
May 20 21:39:17 fjcloud-api-staging fjcloud-api[1027699]: {"timestamp":"2026-05-20T21:39:17.600255Z","level":"INFO","fields":{"message":"request completed","status":200,"duration_ms":4},"target":"api::middleware::request_logging","span":{"method":"POST","path":"/webhooks/stripe","request_id":"da417e0c-4ba1-4e99-83bc-7c004c85fe20","tenant_id":"-","name":"request"},"spans":[{"method":"POST","path":"/webhooks/stripe","request_id":"da417e0c-4ba1-4e99-83bc-7c004c85fe20","tenant_id":"-","name":"request"}]}

- signature_failure_lines_present: no
- webhook_secret_not_configured_lines_present: no
- status_200_line_present: yes_for_staging_host
- strict_reject_owner: infra/api/src/routes/webhooks.rs:92-105
