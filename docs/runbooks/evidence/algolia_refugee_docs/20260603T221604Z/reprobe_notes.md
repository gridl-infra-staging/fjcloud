# Reprobe notes

- The first bare `bash scripts/validate_customer_quickstart.sh staging` attempt failed before mutation because the shell lacked `SES_FROM_ADDRESS`, `SES_REGION`, `INBOUND_ROUNDTRIP_S3_URI`, and `INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN`.
- Staging was re-run through the canonical SSM hydrator `scripts/launch/hydrate_seeder_env_from_ssm.sh staging`; the hydrate output is recorded with values redacted in `hydrate_staging_keys.txt`.
- The hydrated staging output directly records success lines for every migration executable case: list, create, batch add, search, get object, batch update, delete object, save synonym, and save rule.
- `prod --contract-only` now probes exact documented HTTP verbs. The live response proves route-method presence without mutation: auth/register and verify-email return `415`; authenticated index routes return `401`; no documented verb returns `404`, `405`, transport failure, or `5xx`.
