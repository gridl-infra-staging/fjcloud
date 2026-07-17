# Stage 7 Canary Dry-Run Summary

| Field | Value |
|---|---|
| Mode | dry-run |
| Exit code | 0 |
| Steps passed count | 9/9 |
| Steps skipped | Stripe-mutating branch skipped (--dry-run) |
| Deployed SHA | 5a57ea6a280a1d63b54957b3732dcf8cc0a08c2e |
| API URL | https://api.flapjack.foo |
| Timestamp (UTC) | 2026-05-05T08:33:34Z |

Scope: This bundle proves the non-Stripe customer loop against the deployed binary (signup, email verification via S3 inbox, index CRUD+search, deterministic cleanup). It does not prove live-money billing (Stage 8), alert delivery (Stage 5), or heartbeat liveness (Stage 6).
