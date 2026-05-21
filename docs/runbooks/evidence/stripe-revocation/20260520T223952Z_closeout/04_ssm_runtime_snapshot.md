# Stage 4 SSM Runtime Snapshot

- captured_at_utc: 2026-05-20T22:41:08Z
- owner_chain: ops/scripts/lib/generate_ssm_env.sh:43-166
- source_boundary: docs/design/secret_sources.md:36-52,72-89
- command: aws ssm get-parameters-by-path --path /fjcloud/<env>/ --with-decryption --output json

## staging (/fjcloud/staging)
- /fjcloud/staging/stripe_publishable_key | version=3 | value_redacted=pk_test...xjubE
- /fjcloud/staging/stripe_secret_key | version=9 | value_redacted=sk_test...POncY
- /fjcloud/staging/stripe_webhook_secret | version=10 | value_redacted=whsec_y...DWNB8

## prod (/fjcloud/prod)
- /fjcloud/prod/stripe_publishable_key | version=2 | value_redacted=pk_live...A1PYb
- /fjcloud/prod/stripe_secret_key | version=2 | value_redacted=sk_live...xesZY
- /fjcloud/prod/stripe_webhook_secret | version=2 | value_redacted=whsec_I...aWw7r

## Notes
- Values are redacted to prefix/suffix evidence only.
- Full values were used only in-memory for active runtime probes and never committed.
