# Pricing And Support Email Surface Closeout

Captured: 2026-06-04T18:00:18Z
HEAD: `0d6b499d71727be2abffd966366c9805fe842db2`

This bundle is output-only evidence for the Stage 3 closeout. It is not a contract owner.
For durable ownership, use the code and runbook seams cited below.

## Audited Surface Owners

| Surface | HEAD conclusion | Owner and proof anchors |
| --- | --- | --- |
| `/pricing` | HEAD owns the tax disclaimer through the shared pricing object, and the Svelte page renders that field on the pricing card. | `web/src/lib/pricing.ts:55-82` defines `MARKETING_PRICING.tax_disclaimer`; `web/src/routes/pricing/+page.svelte:89` renders `{pricing.tax_disclaimer}`. |
| `/signup` | HEAD owns the support mailto through the shared support constants, and the signup page renders the expected "Need help? Contact support@flapjack.foo" block. | `web/src/lib/format.ts:188-191` defines `SUPPORT_EMAIL` and `LEGAL_SUPPORT_MAILTO`; `web/src/routes/signup/+page.svelte:142-150` renders the link; `web/src/routes/signup/signup.test.ts:52-57` asserts text and href. |
| Verify-email failure | HEAD failure-state copy uses the shared support constants. | `web/src/routes/verify-email/[token]/+page.svelte:60-68` renders the failure mailto; `web/src/routes/verify-email/[token]/verify-email.test.ts:45-52` asserts the failure text and href. |
| Public error boundary | HEAD public errors use sanitized boundary copy plus one support-reference mailto block. | `web/src/lib/error-boundary/recovery-copy.ts:167-176` builds support reference and subject mailto; `web/src/lib/error-boundary/SupportReferenceBlock.svelte:15-23` renders the block; `web/src/routes/error.test.ts:174-257` asserts sanitized copy, one reference, and the mailto. |
| `/console/billing` | HEAD cancellation support copy uses the shared support constants in the billing UI. | `web/src/routes/console/billing/+page.svelte:163-184` renders cancellation support links; `web/src/routes/console/billing/billing.test.ts:147-166` asserts the "Contact support@flapjack.foo to cancel" href. |

## Public Live Probes

These are live-state observations from `cloud.flapjack.foo`, not proof of what HEAD owns.

```bash
curl -fsS https://cloud.flapjack.foo/pricing | grep -F 'Prices are quoted in USD and exclusive of any applicable tax in your jurisdiction.'
```

Result: FAIL, exit 1. A follow-up diagnostic `curl -sS -o /tmp/fjcloud_pricing_probe.html -w '%{http_code} %{redirect_url}\n' https://cloud.flapjack.foo/pricing` returned HTTP 200, but the live HTML did not contain the checked-in tax disclaimer.

```bash
curl -fsS https://cloud.flapjack.foo/signup | grep -F 'mailto:support@flapjack.foo'
```

Result: FAIL, exit 1. A follow-up diagnostic `curl -sS -o /tmp/fjcloud_signup_probe.html -w '%{http_code} %{redirect_url}\n' https://cloud.flapjack.foo/signup` returned HTTP 200, but the live HTML did not contain the checked-in signup support block or literal mailto.

Reconciliation: the matching HEAD seams and focused validations pass, so these are recorded as undeployed/live-state gaps rather than product-code defects in this stage. `bash scripts/local-ci.sh --fast` also reported informational prod deploy drift: prod `dev_sha` was `c62287ada3f7662305032263766441fa4388ac98` while this closeout HEAD was `0d6b499d71727be2abffd966366c9805fe842db2`.

## Verified At HEAD

```bash
cd web && npx vitest run src/routes/verify-email/[token]/verify-email.test.ts src/routes/error.test.ts src/routes/console/billing/billing.test.ts
```

Result: PASS under bash. Vitest reported 3 files passed and 33 tests passed.

```bash
bash ops/terraform/tests_runbooks_static.sh
```

Result: PASS. Runbook Static Tests reported 109/109 passed.

```bash
bash scripts/local-ci.sh --fast
```

Result: PASS. Local CI reported 14 gates passed, 0 failed, 0 skipped.

Note: the first Vitest attempt was launched through zsh and failed before collection with `zsh:1: no matches found: src/routes/verify-email/[token]/verify-email.test.ts`. The same checklist command was then rerun through bash, matching the repo operating instructions, and passed.

## Alert Recipient Contract

Live SNS probe:

```bash
source /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret
aws sns list-subscriptions-by-topic --topic-arn "arn:aws:sns:us-east-1:213880904778:fjcloud-alerts-prod" --output json
```

Result: PASS. The confirmed endpoint set was exactly `stuart.clifford@gmail.com`; no pending endpoints were observed.

Checked-in prod contract owner seam:

- `ops/terraform/_shared/variables.tf:45-57` validates `alert_emails`.
- `ops/terraform/_shared/main.tf:26` normalizes `alert_emails`; `ops/terraform/_shared/main.tf:103-125` rejects empty prod recipients and passes normalized values into monitoring.
- `docs/runbooks/infra-terraform-apply.md:236-269` owns the production apply instructions and pins `-var='alert_emails=["stuart.clifford@gmail.com"]'`.
- `ops/terraform/tests_runbooks_static.sh:12-195` owns the static contract test for the pinned prod recipient and declined-recipient exclusions.

This `findings.md` file is not the contract owner for `alert_emails`; update the runbook and static test seam above if the contract changes.

## Evidence-Only Support Email Sweep

Command:

```bash
rg -n --glob '!docs/runbooks/evidence/support_email_surfaces/**' "SUPPORT_EMAIL|LEGAL_SUPPORT_MAILTO|support@flapjack\\.foo" web/src docs/runbooks
```

The sweep excluded this support-surface evidence directory to avoid recursive pseudo-owners. Hits in the five audited surfaces matched the owner table above. Additional hits are evidence-only follow-ups and do not block this stage because they do not disprove the audited owners:

- `web/src/lib/format.ts` also defines `BETA_FEEDBACK_MAILTO`.
- Public/legal surfaces: `web/src/routes/privacy/+page.svelte`, `web/src/routes/dpa/+page.svelte`, `web/src/routes/terms/+page.svelte`, their tests/helpers, `web/src/routes/status/status.test.ts`.
- Layout/footer/beta components: `web/src/routes/+layout.svelte`, `web/src/lib/components/SiteFooter.svelte`, `web/src/lib/components/BetaSupportBadge.svelte`, `web/src/lib/components/BetaPill.svelte`.
- Console-adjacent surfaces: `web/src/routes/console/+layout.svelte`, `web/src/routes/console/layout.test.ts`, `web/src/routes/console/error.test.ts`, `web/src/routes/console/onboarding/+page.svelte`, `web/src/routes/console/onboarding/onboarding.test.ts`, `web/src/routes/console/billing/+page.server.ts`, `web/src/routes/console/billing/billing.server.test.ts`.
- Runbooks and historical evidence outside this bundle family: `docs/runbooks/infra-alarm-triage.md`, `docs/runbooks/support_email_probe.md`, `docs/runbooks/email-production.md`, `docs/runbooks/operator-readiness/support_inbox_roundtrip/20260505T020144Z_dispatch.md`, and older `docs/runbooks/evidence/**` bundles such as SES, browser, UI-polish, launch-verification, cold-customer-audit, and pipeline-propagation evidence.

## Files Touched

Product code files touched: none.

Stage output written:

- `docs/runbooks/evidence/support_email_surfaces/20260604T180018Z/findings.md`
