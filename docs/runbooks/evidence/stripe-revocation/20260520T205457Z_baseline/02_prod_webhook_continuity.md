# Stage 2 Prod Webhook Continuity

- probe_started_at_utc: 2026-05-20T21:38:52Z
- command_shape_owner: chats/icg/evidence/may19_pm_3/06_webhook_verification_summary.md:3-24
- resend_command: STRIPE_API_KEY=*** stripe events resend evt_1TYeXOGXI8zVz4UHSUEyo5HU --webhook-endpoint we_1TPn3kGXI8zVz4UHakNGfb4O
- prod_webhook_endpoint_discovery: we_1TPn3kGXI8zVz4UHakNGfb4O\thttps://api.flapjack.foo/webhooks/stripe\tenabled\ttrue

## Resend CLI output (contract fields)
{
  "id": "evt_1TYeXOGXI8zVz4UHSUEyo5HU",
  "livemode": true,
  "type": "invoice.payment_succeeded",
  "pending_webhooks": 1,
  "request": {
    "id": "req_tWgXNPQFJFcSCa"
  }
}

## Prod host journal lines near resend window
May 20 21:38:52 fjcloud-api-prod fjcloud-api[379054]: {"timestamp":"2026-05-20T21:38:52.247756Z","level":"INFO","fields":{"message":"acknowledging duplicate webhook delivery for already processed event","event_id":"evt_1TYeXOGXI8zVz4UHSUEyo5HU","event_type":"invoice.payment_succeeded"},"target":"api::routes::webhooks","span":{"method":"POST","path":"/webhooks/stripe","request_id":"49618a7b-1e7e-453a-ba0e-4e20ec241937","tenant_id":"-","name":"request"},"spans":[{"method":"POST","path":"/webhooks/stripe","request_id":"49618a7b-1e7e-453a-ba0e-4e20ec241937","tenant_id":"-","name":"request"}]}
May 20 21:38:52 fjcloud-api-prod fjcloud-api[379054]: {"timestamp":"2026-05-20T21:38:52.247894Z","level":"INFO","fields":{"message":"request completed","status":200,"duration_ms":7},"target":"api::middleware::request_logging","span":{"method":"POST","path":"/webhooks/stripe","request_id":"49618a7b-1e7e-453a-ba0e-4e20ec241937","tenant_id":"-","name":"request"},"spans":[{"method":"POST","path":"/webhooks/stripe","request_id":"49618a7b-1e7e-453a-ba0e-4e20ec241937","tenant_id":"-","name":"request"}]}

- signature_failure_lines_present: no
- webhook_secret_not_configured_lines_present: no
- status_200_line_present: yes
- strict_reject_owner: infra/api/src/routes/webhooks.rs:92-105
