# Stage 1 Snapshot Summary

- UTC snapshot stamp:
  - 20260502T013922Z
- Repo SHA:
  - 745d4ec2550c3797dc3a60c6ec1c781313ff462f
- Evidence owner chain:
  - Stripe account selection: scripts/stripe/create_catalog.sh + scripts/lib/stripe_account.sh
  - Staging env rendering owner: ops/scripts/lib/generate_ssm_env.sh (SSM_TO_ENV)
  - Staging host read owner: scripts/launch/ssm_exec_staging.sh

## Mutation-target inventory (ID cross-reference only)

- Live catalog reference owner: docs/stripe/live_product_catalog.md
- Sandbox catalog reference owner: docs/stripe/sandbox_product_catalog.md

### Live account capture status (blocking evidence)

- Live account snapshot command failed because `STRIPE_SECRET_KEY_flapjack_cloud` was absent in local secrets.
- Blocking artifact (captured):
  - stripe_live/account_resolution_error.txt
- Because live Stripe API reads did not execute, Stage 1 live webhook/product JSON artifacts were not created in this snapshot.
- Live mutation-target IDs are therefore cross-referenced to docs owner only (not snapshot-captured here):
  - Legacy tiers (docs/stripe/live_product_catalog.md):
    - Flapjack Micro: `prod_UNtilkxgwOeR1m` / `price_1TP7utGXI8zVz4UHiJwV5XgC`
    - Flapjack Small: `prod_UNtiVT6SCzNJH1` / `price_1TP7urGXI8zVz4UHg2JeztNP`
    - Flapjack Medium: `prod_UNtiqBFZZ2Tl4H` / `price_1TP7usGXI8zVz4UHTdzHbFch`
    - Flapjack Large: `prod_UNti3xW0akqYPD` / `price_1TP7urGXI8zVz4UHIZ1sHxav`
  - Rate-card products (docs/stripe/live_product_catalog.md):
    - Hot Storage: `prod_UOaD34MwLpaF9B` / `price_1TPn3MGXI8zVz4UHD9W1V1rd`
    - Cold Storage: `prod_UOaD9g5act47W3` / `price_1TPn3NGXI8zVz4UHDdcfYC0Y`
    - Object Storage: `prod_UOaDt1UGcHhhkv` / `price_1TPn3OGXI8zVz4UHuTbUd9pY`
    - Object Egress: `prod_UOaD87yuG6cAx8` / `price_1TPn3PGXI8zVz4UHesIuNQuL`
    - Shared Minimum: `prod_UOaD5r1qMuwzl9` / `price_1TPn3QGXI8zVz4UH77Izq9Na`
    - Dedicated Minimum: `prod_UOaDcZTrbv9VRi` / `price_1TPn3RGXI8zVz4UHbNqTaCxC`
  - Primary live webhook endpoint (docs/stripe/live_product_catalog.md):
    - `we_1TPn3kGXI8zVz4UHakNGfb4O`

### Sandbox snapshot IDs (captured in Stage 1 artifacts)

- Source artifacts:
  - stripe_sandbox/products_active.json
  - stripe_sandbox/prices_active.json
  - stripe_sandbox/webhook_endpoints.json
- Legacy tier products (captured):
  - Flapjack Micro: `prod_TwGDLouRNXOOXJ` / `price_1SyNgwKH9mdklKeIeMbTKAY0`
  - Flapjack Small: `prod_TwGEidVrV4QLjZ` / `price_1SyNiGKH9mdklKeISKMpbcmj`
  - Flapjack Medium: `prod_TwGF3jimx6jPU0` / `price_1SyNidKH9mdklKeI4aKsONvU`
  - Flapjack Large: `prod_TwGF4YX0N95n5h` / `price_1SyNiyKH9mdklKeIlaMX7rPg`
- Rate-card products (captured):
  - Hot Storage: `prod_UOZRhBQpI8xyYa` / `price_1TPmJ5KH9mdklKeIW7qrRZm9`
  - Cold Storage: `prod_UOZSoBvGj1hmfh` / `price_1TPmJ6KH9mdklKeIL9jcZtp4`
  - Object Storage: `prod_UOZSa0Wckr1hUL` / `price_1TPmJ7KH9mdklKeIXMwNkygB`
  - Object Egress: `prod_UOZS2j55Xvgy7t` / `price_1TPmJ8KH9mdklKeIxl8q4Jny`
  - Shared Minimum: `prod_UOZS16OvDxZPlF` / `price_1TPmJ9KH9mdklKeIAdR3zjqC`
  - Dedicated Minimum: `prod_UOZSsjKYrAKSzr` / `price_1TPmJAKH9mdklKeIjE2rw99k`
- Primary sandbox webhook endpoint (captured):
  - `we_1TPDB0KH9mdklKeIkGaA4BZ7` (`https://api.flapjack.foo/webhooks/stripe`)
- Stale sandbox endpoint expected for later removal (captured):
  - `we_1SyNmKKH9mdklKeIucug7tZE`

## Staging SSM + host runtime context

- Stripe SSM metadata snapshots:
  - staging_ssm/stripe_parameter_describe.json
  - staging_ssm/stripe_parameter_path_metadata.json
- Staging host STRIPE_* render snapshot (redacted):
  - staging_host/stripe_env_host_redacted.txt
- Staging deploy SHA snapshot:
  - staging_host/last_deploy_sha.txt
- Local-only rollback secret material path (NOT committed values):
  - /Users/stuart/parallel_development/fjcloud_dev/may01_pm_4_wave1_stripe_artifacts_cleanup/fjcloud_dev/.secret/local_only_stage1_stripe_rollback_20260502T013922Z.env

## Rollback mechanics for later mutation stages (2-7)

These commands are references for later mutation stages. Commands marked MUTATION are not executed in Stage 1.

1. Stripe product/webhook archive reversal references (MUTATION)

```bash
stripe products update <prod_id> --active true
stripe webhook_endpoints update <we_id> --disabled false
```

2. SSM parameter re-put flow (MUTATION)

```bash
aws ssm put-parameter \
  --region us-east-1 \
  --name /fjcloud/staging/stripe_secret_key \
  --type SecureString \
  --overwrite \
  --value "<value from local rollback file>"
```

3. Staging env regeneration + restart flow (MUTATION, later-stage use)

```bash
bash scripts/launch/ssm_exec_staging.sh "sudo bash /opt/fjcloud/ops/scripts/lib/generate_ssm_env.sh staging"
bash scripts/launch/ssm_exec_staging.sh "sudo systemctl restart fjcloud-api fjcloud-aggregation-job"
```

4. Binary rollback distinction (read-only reference)

- See docs/runbooks/infra-deploy-rollback.md for last_deploy_sha and binary rollback flow.
- Stage 1 captures last deploy SHA in staging_host/last_deploy_sha.txt so later stages can separate SSM secret rollback from binary rollback.
