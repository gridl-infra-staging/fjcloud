# Stage 2 SSM Runtime Snapshot

- captured_at_utc: 2026-05-20T21:10:03Z
- sts_arn: arn:aws:iam::213880904778:user/stuart-cli
- owner_mapping: ops/scripts/lib/generate_ssm_env.sh:43-166 (SSM_TO_ENV + get-parameters-by-path)
- runtime_boundary: docs/design/secret_sources.md:38-52,72-89

## staging
- name: /fjcloud/staging/stripe_secret_key
  - version: 9
  - value_redacted: sk_test...POncY
- name: /fjcloud/staging/stripe_publishable_key
  - version: 3
  - value_redacted: pk_test...xjubE
- name: /fjcloud/staging/stripe_webhook_secret
  - version: 10
  - value_redacted: whsec_y...DWNB8

## prod
- name: /fjcloud/prod/stripe_secret_key
  - version: 2
  - value_redacted: sk_live...xesZY
- name: /fjcloud/prod/stripe_publishable_key
  - version: 2
  - value_redacted: pk_live...A1PYb
- name: /fjcloud/prod/stripe_webhook_secret
  - version: 2
  - value_redacted: whsec_I...aWw7r

