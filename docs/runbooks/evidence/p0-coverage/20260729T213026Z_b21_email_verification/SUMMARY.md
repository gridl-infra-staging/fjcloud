# B21 email-verification execution evidence

Recorded at `2026-07-29T21:30:26Z` against HEAD
`4f66b70d136a0cee48d052261118e05866b71fdb`.

## RED and GREEN specimens

- Stage 1 RED: `stage_1_b21_red.json` reports the exact B21 title under the
  general `chromium` project with result status `skipped`, one skipped test,
  and no executed pass. The reporter command itself completed with `exit=0`;
  the RED condition is the skipped B21 result.
- Stage 2/current-HEAD GREEN: `stage_2_b21_green.json` was regenerated at this
  HEAD. It reports the exact B21 title under
  `chromium:email-verification` with result status `passed`, one expected test,
  zero skipped tests, and `exit=0`.
- The canonical executed-pass receipt remains
  `docs/runbooks/evidence/local-p0-coverage/20260729T204838Z/receipt.json`, with
  its B21 runner log at
  `docs/runbooks/evidence/local-p0-coverage/20260729T204838Z/raw/b21_auth_end_effects.log`.
  This bundle does not duplicate or redefine that receipt.

## Fail-capable mutation proofs

All three specimens used:

`cd web && npx playwright test tests/e2e-ui/full/auth-end-effects.spec.ts --grep "valid verification token shows success heading and login CTA @p0_coverage" --project=chromium:email-verification --reporter=line`

- Heading mutation: `raw/mutation_heading.log` records `exit=1`. The changed
  rendered heading was observed by the route fixture's identical
  `Email verified` oracle at `web/tests/fixtures/fixtures.ts:3841`, before the
  duplicate B21 assertion at `auth-end-effects.spec.ts:102` could run. After
  immediate restoration, B21 passed with `exit=0`.
- `data-success` mutation: `raw/mutation_data_success.log` records `exit=1`,
  received `false` instead of `true`, and points to
  `auth-end-effects.spec.ts:101`. The restored-source verification was a
  validation-cache hit for the immediately preceding clean-tree B21
  `exit=0` pass at the same HEAD and whole-repo tree.
- Login-href mutation: `raw/mutation_login_href.log` records `exit=1`,
  received `/signup` instead of `/login`, and points to
  `auth-end-effects.spec.ts:103`. The restored-source verification was the
  same clean-tree `exit=0` cache hit.
- No source, spec, fixture, or Playwright configuration mutation remains.

## Measured collateral coverage

- `cold_customer_algolia_refugee_journey.spec.ts`: not covered by the new
  project. `raw/collateral_cold_customer_list.log` reports
  `0 tests in 0 files`, `exit=1`; project `testMatch` excludes this file.
- `first_five_minutes_customer_polish.spec.ts`: not covered by the new
  project. `raw/collateral_first_five_minutes_list.log` reports
  `0 tests in 0 files`, `exit=1`; project `testMatch` excludes this file.
- Because neither collateral spec was selected, neither verification leg
  executed and no collateral product-path failure or isolation rerun applied.

## Sibling-project regression evidence

- Stage 2 B2 billing-portal log:
  `raw/stage_2_b2_billing_portal.log` records two passed tests and `exit=0`.
- Stage 2 B7 upgrade-to-shared log:
  `raw/stage_2_b7_upgrade_to_shared.log` records one passed test and `exit=0`.

Consuming the real verification token remained a browser visit to
`/verify-email/<token>`.
