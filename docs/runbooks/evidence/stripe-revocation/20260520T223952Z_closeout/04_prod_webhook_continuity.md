# Stage 4 Prod Webhook Continuity

- probe_started_at_utc: 2026-05-20T22:42:44Z
- command_shape_owner: docs/runbooks/evidence/stripe-revocation/20260520T205457Z_baseline/02_prod_webhook_continuity.md:3-26
- prior_runbook_owner: chats/icg/evidence/may19_pm_3/06_webhook_verification_summary.md:3-24
- log_query_since_utc: 2026-05-20 22:40:45 UTC
- prod_webhook_endpoint_id: we_1TPn3kGXI8zVz4UHakNGfb4O
- resend_event_id: evt_1TYeXOGXI8zVz4UHSUEyo5HU
- resend_command: STRIPE_API_KEY=*** stripe events resend evt_1TYeXOGXI8zVz4UHSUEyo5HU --webhook-endpoint we_1TPn3kGXI8zVz4UHakNGfb4O --live

## Resend CLI output
```json
{
  "id": "evt_1TYeXOGXI8zVz4UHSUEyo5HU",
  "livemode": true,
  "pending_webhooks": 1,
  "request": {
    "id": "req_tWgXNPQFJFcSCa"
  },
  "type": "invoice.payment_succeeded"
}
```

- redaction_note: full live event payload intentionally omitted from the committed artifact to avoid storing customer PII and hosted invoice URLs; the continuity contract only needs `id`, `livemode`, `type`, `pending_webhooks`, and Stripe request id.

## Prod host journal lines near resend window
```text
May 20 22:41:24 fjcloud-api-prod fjcloud-api[379054]: {"timestamp":"2026-05-20T22:41:24.902333Z","level":"WARN","fields":{"message":"request completed","status":400,"duration_ms":0},"target":"api::middleware::request_logging","span":{"method":"POST","path":"/webhooks/stripe","request_id":"de8f5215-264a-4a0c-a3f1-f71e86a17612","tenant_id":"-","name":"request"},"spans":[{"method":"POST","path":"/webhooks/stripe","request_id":"de8f5215-264a-4a0c-a3f1-f71e86a17612","tenant_id":"-","name":"request"}]}
May 20 22:42:14 fjcloud-api-prod fjcloud-api[379054]: {"timestamp":"2026-05-20T22:42:14.064813Z","level":"INFO","fields":{"message":"acknowledging duplicate webhook delivery for already processed event","event_id":"evt_1TYeXOGXI8zVz4UHSUEyo5HU","event_type":"invoice.payment_succeeded"},"target":"api::routes::webhooks","span":{"method":"POST","path":"/webhooks/stripe","request_id":"7d4abd8e-065e-4ae4-acb6-e1e6ee3ac7d7","tenant_id":"-","name":"request"},"spans":[{"method":"POST","path":"/webhooks/stripe","request_id":"7d4abd8e-065e-4ae4-acb6-e1e6ee3ac7d7","tenant_id":"-","name":"request"}]}
May 20 22:42:14 fjcloud-api-prod fjcloud-api[379054]: {"timestamp":"2026-05-20T22:42:14.064961Z","level":"INFO","fields":{"message":"request completed","status":200,"duration_ms":7},"target":"api::middleware::request_logging","span":{"method":"POST","path":"/webhooks/stripe","request_id":"7d4abd8e-065e-4ae4-acb6-e1e6ee3ac7d7","tenant_id":"-","name":"request"},"spans":[{"method":"POST","path":"/webhooks/stripe","request_id":"7d4abd8e-065e-4ae4-acb6-e1e6ee3ac7d7","tenant_id":"-","name":"request"}]}
```

- status_200_line_present: yes
- status_200_line: May 20 22:42:14 fjcloud-api-prod fjcloud-api[379054]: {"timestamp":"2026-05-20T22:42:14.064961Z","level":"INFO","fields":{"message":"request completed","status":200,"duration_ms":7},"target":"api::middleware::request_logging","span":{"method":"POST","path":"/webhooks/stripe","request_id":"7d4abd8e-065e-4ae4-acb6-e1e6ee3ac7d7","tenant_id":"-","name":"request"},"spans":[{"method":"POST","path":"/webhooks/stripe","request_id":"7d4abd8e-065e-4ae4-acb6-e1e6ee3ac7d7","tenant_id":"-","name":"request"}]}
- signature_failure_lines_present: no
- webhook_secret_not_configured_lines_present: no
- strict_reject_owner: infra/api/src/routes/webhooks.rs:92-105
