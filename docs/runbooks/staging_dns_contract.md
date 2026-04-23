## Purpose

Establish the single staging DNS contract for follow-on infrastructure stages. This artifact records the 2026-04-20 correction that `flapjack.foo`, not `flapjack.cloud`, is the owned public domain for fjcloud staging, and the later 2026-04-21 evidence that the Cloudflare/DNS cutover is now complete.

## Canonical Staging Domain

Decision status: finalized.

- Canonical root domain: `flapjack.foo`.
- Canonical web console hostname: `cloud.flapjack.foo`.
- Required public hostnames: `flapjack.foo`, `api.flapjack.foo`, `www.flapjack.foo`, `cloud.flapjack.foo`.
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
| `PRIORITIES.md:43` | Cloudflare must publish `flapjack.foo` public records. |
| `ops/terraform/_shared/variables.tf` | Root Terraform `domain` default is `flapjack.foo`. |
| `ops/terraform/dns/variables.tf` | DNS module `domain` default is `flapjack.foo`. |
| `ops/terraform/dns/main.tf` | Public ALB, ACM validation, and SES DKIM DNS records are parameterized by `var.domain` and published through Cloudflare. |
| `ops/scripts/validate_bootstrap.sh` | Bootstrap validation checks the Cloudflare `flapjack.foo` zone. |
| `docs/env-vars.md` | Documents canonical Cloudflare env vars plus the `FLAPJACK_FOO` token/zone aliases. |

## Live Evidence

This document keeps the original contract and its historical troubleshooting notes, but the live-status authority is now [`docs/runbooks/staging-evidence.md`](./staging-evidence.md).

Current live status recorded there on 2026-04-21:

- Public hosts routed through Cloudflare: `flapjack.foo`, `api.flapjack.foo`, `www.flapjack.foo`, `cloud.flapjack.foo`.
- ACM certificate status: `ISSUED`.
- SES identity status: `SUCCESS`.
- SES DKIM status: `SUCCESS`.
- Public health check: `https://api.flapjack.foo/health` returned `200`.

Historical notes from the 2026-04-20 correction lane:

- AWS account identity succeeded for account `213880904778` using operator credentials.
- Existing staging ALB DNS was `fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com`.
- Prior AWS ACM and SES resources were aligned to `flapjack.cloud`; those are historical and should not drive new staging DNS work.
- `dig +short NS flapjack.foo @1.1.1.1` returned Cloudflare nameservers.
- `api.flapjack.foo` had no public A/CNAME in the earlier read-only DNS check.
- `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret` contains `CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO` and `CLOUDFLARE_ZONE_ID_FLAPJACK_FOO`.
- An earlier read-only Cloudflare lookup returned HTTP 403 with code `9109` (`Invalid access token`); that specific credential issue is historical and is no longer the current blocker per the 2026-04-21 staging evidence update.

## Public DNS Record Matrix

| Record owner | Terraform source | DNS type | Target/value | TTL/proxy expectation | Validation command |
|---|---|---|---|---|---|
| `flapjack.foo` | `ops/terraform/dns/main.tf` `local.public_dns_records.apex` | `CNAME` | Staging ALB DNS name | DNS-only, `var.dns_ttl` | `dig +short CNAME flapjack.foo @1.1.1.1` |
| `api.flapjack.foo` | `local.public_dns_records.api` | `CNAME` | Staging ALB DNS name | DNS-only, `var.dns_ttl` | `dig +short CNAME api.flapjack.foo @1.1.1.1` |
| `www.flapjack.foo` | `local.public_dns_records.www` | `CNAME` | Staging ALB DNS name | DNS-only, `var.dns_ttl` | `dig +short CNAME www.flapjack.foo @1.1.1.1` |
| `cloud.flapjack.foo` | `local.public_dns_records.cloud` | `CNAME` | Staging ALB DNS name | DNS-only, `var.dns_ttl` | `dig +short CNAME cloud.flapjack.foo @1.1.1.1` |
| ACM validation names | `cloudflare_dns_record.cert_validation` | `CNAME` | AWS ACM generated validation values | DNS-only, TTL 60 | `aws acm describe-certificate --certificate-arn <arn> --query 'Certificate.DomainValidationOptions'` |
| SES DKIM names | `cloudflare_dns_record.ses_dkim` | `CNAME` | AWS SES generated DKIM values | DNS-only, `var.dns_ttl` | `aws sesv2 get-email-identity --email-identity flapjack.foo --region us-east-1` |

## SES Identity Contract

- Terraform now manages `aws_sesv2_email_identity.domain` for `var.domain`.
- Terraform publishes three SES Easy DKIM CNAME records through Cloudflare from `dkim_signing_attributes[0].tokens`.
- Runtime validation remains `aws sesv2 get-email-identity --email-identity flapjack.foo --region us-east-1` and requires both identity verification and DKIM status to be `SUCCESS`.

## Current Blockers

No active DNS-contract blocker is recorded in the latest staging evidence.

- Cloudflare zone access, public records, ACM issuance, SES verification, and public API health are all recorded as complete in [`docs/runbooks/staging-evidence.md`](./staging-evidence.md).
- Remaining launch blockers are outside the DNS contract: Stripe staging credentials, credentialed billing evidence, and one unrelated cold-storage encryption drift representation in Terraform evidence.

## Validation

Run these when re-validating the DNS contract after a future public-DNS change:

```bash
bash ops/terraform/tests_stage7_runtime_smoke.sh \
  --env staging \
  --domain flapjack.foo \
  --ami-id <current-staging-ami-id>
```

The smoke harness validates Cloudflare zone access, public CNAMEs, ACM issuance, ALB HTTPS routing, SES DKIM verification, and `https://api.flapjack.foo/health`.
