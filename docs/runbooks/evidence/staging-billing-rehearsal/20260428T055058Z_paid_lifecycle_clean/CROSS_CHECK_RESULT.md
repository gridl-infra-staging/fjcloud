# Deferred Cross-Check — RESOLVED

The "Stage 2 proof owner cross-check" deferred at probe time
(connection refused to localhost:35432) was re-run on 2026-04-29
via SSM exec on the staging API instance (which has VPC ingress to
RDS that operator laptops do not).

## Method

`aws ssm send-command` to instance `i-0afc7651593f12372`
(fjcloud-api-staging) running `psql "$DATABASE_URL" -f` of the
documented invoice readback. No data mutated.

## Result: PASSED

| Field | Persisted (staging RDS) | Expected (regression test) |
|---|---|---|
| invoice_id | `e7806ad2-977d-4f4b-9ff9-95c7ddab49e3` | (input) |
| customer_id | `0a65f0b7-14b3-4e08-acf6-2222a02c7858` | (any UUID) |
| subtotal_cents | **11** | **11** ✓ |
| total_cents | **500** | **500** ✓ |
| minimum_applied | **t (true)** | **true** ✓ |
| status | paid | paid ✓ |
| stripe_invoice_id | `in_1TR4Y2KH9mdklKeI6OXXpo17` | non-null Stripe invoice |
| period_start / period_end | 2026-04-01 / 2026-04-30 | April billing month |
| paid_at_utc | 2026-04-28T05:51:09Z | < now |

## What this proves

The persisted invoice row in staging matches the values asserted by
the local known-answer Rust regression test
`infra/api/tests/billing_regression_test.rs::shared_plan_staging_bundle_known_answer_regression`.
Both pass. There is no drift between the regression test's
hand-calculated reference values and the actual persisted values
on staging.

## Lane 6 status: definitively closed

Both verification paths (local known-answer test + staging-side
persisted-values readback) now pass on the same data. No further
verification needed for this lane.

## Cross-references

- Known-answer test: [billing_regression_test.rs](../../../../../infra/api/tests/billing_regression_test.rs)
  test name: `shared_plan_staging_bundle_known_answer_regression`
- Originally-deferred query: SUMMARY.md lines 99-106 (this directory)
- Re-verification timestamp UTC: 20260429T191900Z (approximate)
