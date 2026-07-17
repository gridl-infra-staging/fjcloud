## Purpose

Establish the single staging DNS contract for follow-on infrastructure stages. This artifact records the 2026-04-20 correction that `flapjack.foo`, not `flapjack.cloud`, is the owned public domain for fjcloud staging, the 2026-04-21 cutover evidence, and the 2026-04-25 reconciliation that locked the checked-in Terraform/runtime-smoke contract to the live ALB-plus-Pages routing split.

## Canonical Staging Domain

Decision status: finalized.

- Canonical Cloudflare zone: `flapjack.foo`.
- Canonical staging deployment domain: `staging.flapjack.foo`.
- Canonical staging web console hostname: `cloud.staging.flapjack.foo`.
- Required staging public hostnames: `staging.flapjack.foo`, `api.staging.flapjack.foo`, `www.staging.flapjack.foo`, `cloud.staging.flapjack.foo`.
- DNS authority: Cloudflare zone for `flapjack.foo`.
- Historical `flapjack.cloud` evidence is non-authoritative for new work because the operator does not own that domain.

## Out Of Scope

- No Route53 VM-hostname behavior changes in `docs/env-vars.md`.
- No application runtime code changes.
- No manual-only QA; all validation must be reproducible CLI commands.

## Source Alignment

| Source | Current contract |
|---|---|
| `README.md:15` | Public URL is `cloud.flapjack.foo`. |
| `PROJECT_OVERVIEW.md:43` | Cloudflare must publish `flapjack.foo` public records. |
| `ops/terraform/_shared/variables.tf` | Root Terraform `domain` default is `flapjack.foo`. |
| `ops/terraform/dns/variables.tf` | DNS module `domain` default is `flapjack.foo`. |
| `ops/terraform/_shared/main.tf` | `local.deployment_domain` maps staging root-zone input `flapjack.foo` to `staging.flapjack.foo` before wiring DNS, runtime params, and monitoring. |
| `ops/terraform/dns/main.tf` | `local.deployment_domain` prevents staging from owning prod-root records; staging apex/api/www target the staging ALB under `staging.flapjack.foo`, and staging `cloud` stays proxied to `staging.flapjack-cloud.pages.dev`. ACM validation and SES DKIM records are also published through Cloudflare. |
| `ops/scripts/validate_bootstrap.sh` | Bootstrap validation checks the Cloudflare `flapjack.foo` zone. |
| `docs/env-vars.md` | Documents canonical Cloudflare env vars plus the `FLAPJACK_FOO` token/zone aliases. |

## Live Evidence

This document keeps the original contract and its historical troubleshooting notes, but the live-status authority is now [`docs/runbooks/staging-evidence.md`](./staging-evidence.md).

Historical cutover status recorded there on 2026-04-21:

- Public hosts routed through Cloudflare: `flapjack.foo`, `api.flapjack.foo`, `www.flapjack.foo`, `cloud.flapjack.foo`.
- ACM certificate status: `ISSUED`.
- SES identity status: `SUCCESS`.
- SES DKIM status: `SUCCESS`.
- Public health check: `https://api.flapjack.foo/health` returned `200`.

Latest checked-owner reconciliation recorded on 2026-07-08:

- The checked-in Terraform DNS contract in `ops/terraform/_shared/main.tf` and
  `ops/terraform/dns/main.tf` normalizes staging root-zone input
  `flapjack.foo` to deployment domain `staging.flapjack.foo`, so staging no
  longer targets prod-root public records.
- The runtime owner in `ops/terraform/tests_stage7_runtime_smoke.sh` requires
  staging apex/api/www to be DNS-only CNAMEs to the environment-specific ALB
  name (`fjcloud-staging-alb-*` for staging) and requires
  `cloud.staging.flapjack.foo` to be proxied to the staging Pages host.
- `web/svelte.config.js` and `web/src/routes/+layout.ts` now describe the
  Pages-backed `cloud` surface as a current deployment detail rather than as a
  contradictory ownership claim.
- `bash ops/terraform/tests_stage7_runtime_smoke.sh --env staging --domain flapjack.foo --api-ami-id "$STAGING_API_AMI_ID" --flapjack-ami-id "$STAGING_FLAPJACK_AMI_ID" --env-file "$FJCLOUD_SECRET_FILE"`
  is the live DNS verdict owner. The smoke normalizes that root-zone input to
  `staging.flapjack.foo` for `env=staging`.
- The 2026-07-08 rerun emitted
  `ops/terraform/artifacts/plan_staging_20260708T141024Z.txt` and
  `ops/terraform/artifacts/evidence_staging_20260708T141024Z.jsonl`; it exited
  `0` with Cloudflare DNS, ACM, ALB listener, target health, SES DKIM, and
  `https://api.staging.flapjack.foo/health` all passing.

Historical notes from the 2026-04-20 correction lane:

- AWS account identity succeeded for account `213880904778` using operator credentials.
- Existing staging ALB DNS was `fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com`.
- Prior AWS ACM and SES resources were aligned to `flapjack.cloud`; those are historical and should not drive new staging DNS work.
- `dig +short NS flapjack.foo @1.1.1.1` returned Cloudflare nameservers.
- `api.flapjack.foo` had no public A/CNAME in the earlier read-only DNS check.
- Historical secret-source snapshot only (not active guidance): `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret` contained `CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO` and `CLOUDFLARE_ZONE_ID_FLAPJACK_FOO`.
- An earlier read-only Cloudflare lookup returned HTTP 403 with code `9109` (`Invalid access token`); that specific credential issue is historical and is no longer the current blocker per the 2026-04-21 staging evidence update.

## Public DNS Record Matrix

| Record owner | Terraform source | DNS type | Target/value | TTL/proxy expectation | Validation command |
|---|---|---|---|---|---|
| `staging.flapjack.foo` | `ops/terraform/dns/main.tf` `local.public_dns_records.apex` | `CNAME` | Staging ALB DNS name | DNS-only, `var.dns_ttl` | `dig +short CNAME staging.flapjack.foo @1.1.1.1` |
| `api.staging.flapjack.foo` | `local.public_dns_records.api` | `CNAME` | Staging ALB DNS name | DNS-only, `var.dns_ttl` | `dig +short CNAME api.staging.flapjack.foo @1.1.1.1` |
| `www.staging.flapjack.foo` | `local.public_dns_records.www` | `CNAME` | Staging ALB DNS name | DNS-only, `var.dns_ttl` | `dig +short CNAME www.staging.flapjack.foo @1.1.1.1` |
| `cloud.staging.flapjack.foo` | `local.public_dns_records.cloud` | `CNAME` | `staging.flapjack-cloud.pages.dev` | Proxied, TTL `1` | `dig +short CNAME cloud.staging.flapjack.foo @1.1.1.1` |
| ACM validation names | `cloudflare_dns_record.cert_validation` | `CNAME` | AWS ACM generated validation values | DNS-only, TTL 60 | `aws acm describe-certificate --certificate-arn <arn> --query 'Certificate.DomainValidationOptions'` |
| SES DKIM names | `cloudflare_dns_record.ses_dkim` | `CNAME` | AWS SES generated DKIM values | DNS-only, `var.dns_ttl` | `aws sesv2 get-email-identity --email-identity staging.flapjack.foo --region us-east-1` |

## SES Identity Contract

- Terraform now manages `aws_sesv2_email_identity.domain` for `local.deployment_domain`.
- Terraform publishes three SES Easy DKIM CNAME records through Cloudflare from `dkim_signing_attributes[0].tokens`.
- Runtime validation remains `aws sesv2 get-email-identity --email-identity staging.flapjack.foo --region us-east-1` for staging and requires both identity verification and DKIM status to be `SUCCESS`.

## Current Blockers

There is no current DNS blocker for the staging smoke contract.

- Cloudflare zone access, ACM issuance, target-group health, and public API
  health passed in the 2026-07-08 smoke.
- Keep using
  `ops/terraform/tests_stage7_runtime_smoke.sh::assert_cloudflare_public_records`
  as the DNS verdict owner for this contract.
- Remaining launch blockers exist outside the DNS contract, especially the
  staging seed-index / billing-lane runtime failure documented in
  [`docs/runbooks/staging-evidence.md`](./staging-evidence.md).

## Validation

Run this when re-validating the DNS contract after a future public-DNS change.
For current reruns, source the pinned Stage 1 input artifact first:

```bash
. docs/runbooks/evidence/rc-shape-drift/20260708T131824Z/rerun_inputs.env

STAGING_API_AMI_ID="$(aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=fjcloud-api-staging' 'Name=instance-state-name,Values=running' \
  --query 'Reservations[].Instances[].ImageId | [0]' --output text)"
STAGING_FLAPJACK_AMI_ID="$(aws ssm get-parameter \
  --name /fjcloud/staging/aws_ami_id --query Parameter.Value --output text)"

bash ops/terraform/tests_stage7_runtime_smoke.sh \
  --env staging \
  --domain flapjack.foo \
  --api-ami-id "$STAGING_API_AMI_ID" \
  --flapjack-ami-id "$STAGING_FLAPJACK_AMI_ID" \
  --env-file "$FJCLOUD_SECRET_FILE"
```

The smoke harness validates Cloudflare zone access, the ALB/Pages public-route split, ACM issuance, ALB HTTPS routing, SES DKIM verification, and `https://api.staging.flapjack.foo/health`.
