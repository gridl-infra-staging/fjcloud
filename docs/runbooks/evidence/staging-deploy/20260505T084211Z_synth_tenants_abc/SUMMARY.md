# Stage 8 Synthetic Traffic Evidence — Tenants A/B/C

verdict=GREEN

| Field | Value |
|---|---|
| Deployed SHA | 5a57ea6a280a1d63b54957b3732dcf8cc0a08c2e |
| API URL | https://api.flapjack.foo |
| Timestamp (UTC) | 2026-05-05T08:47:08Z |
| Settle window | 320s (one scheduler cycle + 20s buffer) |

## Per-Tenant Results

| Tenant | Customer ID | Plan | avg_storage_gb | avg_document_count | Verdict |
|---|---|---|---|---|---|
| A | 0a65f0b7-14b3-4e08-acf6-2222a02c7858 | shared | 0.025915 | 20131 | PASS |
| B | 3048552a-a78e-446d-ab94-48fe995e2b6c | dedicated | 0.000478 | 500 | PASS |
| C | d6e4dc27-2f9b-41be-900b-13f4d678105f | dedicated | 0.000478 | 500 | PASS |

## Zero-Check Assertion

Each tenant evaluated against the same OR condition used in
`capture_stage_d_evidence.sh:97-107`:

```
total_search_requests > 0 OR total_write_operations > 0
OR avg_storage_gb > 0 OR avg_document_count > 0
```

All three tenants pass: `avg_storage_gb > 0` and `avg_document_count > 0` for each.

## Seeder Modes

- Tenant A: full execute (`--duration-minutes 3`) — provision + storage backfill + sustained writes
- Tenant B: `--provision-only` — provision only, metering agent emits usage_records on index existence
- Tenant C: `--provision-only` — same as B

## Scope

This bundle proves **attribution continuity** across all three contract
tenants (A/shared, B/dedicated-small, C/dedicated-medium) post-deploy.
It does NOT prove:
- Invoice generation or billing rehearsal
- VLM verdicts
- Organic alert dispatch
- Sustained load performance
