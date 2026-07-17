# Stage 1 Canonical Proof Map (E2E UI Bulletproof Sweep)

This artifact is the single Stage 1 per-spec inventory and categorization map.

## Scope Gate Evidence

Grouped inventory command run before exclusion:

```bash
ls web/tests/e2e-ui/full/*.spec.ts web/tests/e2e-ui/full/admin/*.spec.ts web/tests/e2e-ui/smoke/*.spec.ts | wc -l
```

Observed count before exclusion: `25`

Stage-1 exclusion set (only these two):

- `web/tests/e2e-ui/full/signup_to_paid_invoice.spec.ts`
- `web/tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts`

Retained set for this table: `23` specs.

## Bucket Semantics

- Bucket A: staging-RDS or customer-owned read-path proof.
- Bucket B: external-system proof (Stripe, SES/S3-style artifact reads, canonical-host contract, external migration source).
- Bucket C: genuinely read-only, content-only, visual-only, or currently blocked proof.

## Canonical Retained-Spec Table

| Spec path                                                     | Owner spec docs (SSOT)                                                                                                                                                                                                                                        | Claimed behavior now                                                                                                                 | Bucket | Future proof target                                                                                                   | Provisional rationale                                                                                                                               |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------ | --------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `web/tests/e2e-ui/full/account.spec.ts`                       | `docs/screen_specs/settings.md`                                                                                                                                                                                                                               | Account profile render/update, password-change lifecycle, delete-account redirect contract.                                          | A      | Tighten destructive-account assertions to exact persistence/readback contract rows.                                   | Authenticated customer-owned dashboard path with direct account read/write verification.                                                            |
| `web/tests/e2e-ui/full/admin/admin-pages.spec.ts`             | `docs/screen_specs/admin_alerts.md`; `docs/screen_specs/admin_billing.md`; `docs/screen_specs/admin_cold_storage.md`; `docs/screen_specs/admin_customers.md`; `docs/screen_specs/admin_migrations.md`; `docs/screen_specs/admin_replicas.md`                  | Admin shell pages render seeded tables/empty states; billing/admin quick actions show expected confirmation surfaces.                | A      | Replace shell-level checks with route-specific system assertions per admin owner specs.                               | Existing owner coverage is explicit in `docs/screen_specs/coverage.md`; staged hardening remains route-owner scoped.                                |
| `web/tests/e2e-ui/full/admin/customer-detail.spec.ts`         | `docs/screen_specs/admin_customers.md`; `docs/screen_specs/admin_customer_detail.md`                                                                                                                                                                          | Admin customer drill-down, tab lazy-mounts, quota/status actions, impersonation return path, deterministic list/detail waits.        | A      | Add tighter server-backed status transition proofs with explicit before/after row assertions.                         | Customer lifecycle/admin controls are first-party read paths against staged data owners.                                                            |
| `web/tests/e2e-ui/full/admin/fleet.spec.ts`                   | `docs/screen_specs/admin_login.md`; `docs/screen_specs/admin_fleet.md`; `docs/screen_specs/admin_vm_detail.md`                                                                                                                                                | Admin login gate, fleet table/filtering, VM detail navigation, admin nav contract coverage.                                          | A      | Expand VM detail and fleet side-effect assertions tied to admin VM owner spec criteria.                               | Admin auth + fleet flows are staged first-party paths rather than external third-party contracts.                                                   |
| `web/tests/e2e-ui/full/admin/vlm_screenshot_capture.spec.ts`  | `docs/screen_specs/admin_customers.md` (via `web/tests/e2e-ui/full/vlm_capture/tuples.ts`)                                                                                                                                                                    | Captures admin-customers tuple visuals per lane/state/viewport; skips unproducible states with structured reason.                    | C      | Keep visual-only capture proof and pair with system-side state seam in later stage for currently unproducible tuples. | Visual artifact generation only; no direct system write/read mutation in this spec lane.                                                            |
| `web/tests/e2e-ui/full/api-keys.spec.ts`                      | `docs/screen_specs/api_keys.md`                                                                                                                                                                                                                               | API-key table render, key creation one-time reveal, revoke removal contract.                                                         | A      | Strengthen one-time-secret exposure proof with exact post-revoke read-path assertions.                                | First-party dashboard API-key contract with customer-owned data-path checks.                                                                        |
| `web/tests/e2e-ui/full/auth.spec.ts`                          | `docs/screen_specs/login.md`; `docs/screen_specs/signup.md`; `docs/screen_specs/forgot_password.md`; `docs/screen_specs/reset_password.md`; `docs/screen_specs/verify_email.md`                                                                               | Login/logout/session-expiry handling, forgot/reset UX, invalid verify token path, signup validation and duplicate-email handling.    | A      | Add success-path verify-email/signup completion proofs now tracked in later-stage journey hardening.                  | Auth route owners already mapped; this spec is core first-party route/read behavior.                                                                |
| `web/tests/e2e-ui/full/billing.spec.ts`                       | `docs/screen_specs/dashboard_billing.md`; `docs/screen_specs/payment_method_setup.md`; `docs/screen_specs/invoices.md`                                                                                                                                        | Billing shell, payment-method availability branch, invoices list/detail with PDF action and structured totals.                       | B      | Add stronger external Stripe/mail artifact cross-checks per invoice/payment setup contracts.                          | Billing evidence depends on external billing/payment system contracts, so it is external-proof class.                                               |
| `web/tests/e2e-ui/full/customer-journeys.spec.ts`             | `docs/screen_specs/dashboard.md`; `docs/screen_specs/onboarding.md`; `docs/screen_specs/index_detail.md`; `docs/screen_specs/documents.md`; `docs/screen_specs/search_preview.md`                                                                             | Fresh-user end-to-end flow from onboarding through document upload and search hit, then cleanup.                                     | A      | Expand deterministic assertions for each route-owner checkpoint in the journey.                                       | Composite of customer-owned dashboard/index routes with staged data-path checks.                                                                    |
| `web/tests/e2e-ui/full/dashboard.spec.ts`                     | `docs/screen_specs/dashboard.md`; `docs/screen_specs/logs.md`; `docs/screen_specs/error_boundaries.md`                                                                                                                                                        | Dashboard shell/nav/layout, log-view path checks, plan-aware UI behavior, verification banner states, dashboard error boundary copy. | A      | Tighten estimated-bill and logs assertions to exact owner-spec criteria and seeded values.                            | Dashboard/logs/error-boundary flows are first-party route contracts with staged read paths.                                                         |
| `web/tests/e2e-ui/full/index-detail.spec.ts`                  | `docs/screen_specs/index_detail.md`; `docs/screen_specs/documents.md`                                                                                                                                                                                         | Index detail tab lazy-mount contract across settings/documents/dictionaries/rules/synonyms/chat surfaces.                            | A      | Add tab-by-tab value assertions that prove owner criteria beyond visibility-only checks.                              | Direct first-party index-detail/document route behavior against staged index fixtures.                                                              |
| `web/tests/e2e-ui/full/indexes.spec.ts`                       | `docs/screen_specs/indexes.md`; `docs/screen_specs/index_detail.md`; `docs/screen_specs/search_preview.md`                                                                                                                                                    | Index list render/create/cancel/duplicate handling, detail navigation, and preview result visibility.                                | A      | Harden create/delete and preview assertions against exact table/detail state transitions.                             | Customer-owned index lifecycle reads/writes are first-party staged data-path proofs.                                                                |
| `web/tests/e2e-ui/full/isolation.spec.ts`                     | `docs/screen_specs/dashboard.md`; `docs/screen_specs/onboarding.md`; `docs/screen_specs/index_detail.md`; `docs/screen_specs/documents.md`; `docs/screen_specs/search_preview.md`                                                                             | Cross-tenant isolation for identically named indexes and tenant-scoped search/route-access constraints.                              | A      | Expand tenant-boundary negative assertions to explicit forbidden-response contracts.                                  | Isolation checks are first-party multi-tenant read-path proofs in staged environment.                                                               |
| `web/tests/e2e-ui/full/migration-recovery.spec.ts`            | `docs/screen_specs/migrate.md`                                                                                                                                                                                                                                | Authenticated direct access to `/console/migrate`, unavailable-state copy, and absence of customer migration controls.               | A      | Keep unavailable-state assertions aligned with the replacement-importer availability contract.                        | First-party route/read behavior; no external Algolia credentials or migration-source calls are exercised while customer imports are paused.         |
| `web/tests/e2e-ui/full/onboarding.spec.ts`                    | `docs/screen_specs/dashboard.md`; `docs/screen_specs/onboarding.md`; `docs/screen_specs/index_detail.md`; `docs/screen_specs/documents.md`; `docs/screen_specs/search_preview.md`                                                                             | Dashboard onboarding banner, wizard step progression, index-name validation, and advance-to-credentials path.                        | A      | Add stronger post-create index ownership/readback assertions from route-owner specs.                                  | First-party onboarding/index creation behavior in staged customer-owned data path.                                                                  |
| `web/tests/e2e-ui/full/public-pages.spec.ts`                  | `docs/screen_specs/landing.md`; `docs/screen_specs/pricing.md`; `docs/screen_specs/beta.md`; `docs/screen_specs/status.md`; `docs/screen_specs/terms.md`; `docs/screen_specs/privacy.md`; `docs/screen_specs/dpa.md`; `docs/screen_specs/error_boundaries.md` | Landing/pricing/legal/status content contracts, CTA route links, calculator rows, public error-boundary recovery copy.               | C      | Keep content assertions explicit and expand deterministic textual contract coverage where shallow.                    | Public/static content and route-shape proof with minimal system mutation; primarily read-only/content.                                              |
| `web/tests/e2e-ui/full/public-vlm_screenshot_capture.spec.ts` | `docs/screen_specs/terms.md`; `docs/screen_specs/privacy.md`; `docs/screen_specs/dpa.md` (via `web/tests/e2e-ui/full/vlm_capture/tuples.ts`)                                                                                                                  | Captures legal-page visuals per public tuple lane/state/viewport.                                                                    | C      | Maintain visual baselines and strengthen companion content assertions in non-capture specs.                           | Visual-only tuple capture; no system-side write path exercised.                                                                                     |
| `web/tests/e2e-ui/full/unified-search.spec.ts`                | `docs/screen_specs/search_preview.md`                                                                                                                                                                                                                         | Search tab visibility, generate-preview-key behavior, and mounted search box contract.                                               | A      | Add deterministic preview-response assertion checks tied to owner acceptance criteria.                                | First-party Search route behavior against staged index fixtures.                                                                                    |
| `web/tests/e2e-ui/full/vlm_screenshot_capture.spec.ts`        | `docs/screen_specs/dashboard.md` (via `web/tests/e2e-ui/full/vlm_capture/tuples.ts`)                                                                                                                                                                          | Captures authenticated dashboard visuals for tuple-defined states/viewports.                                                         | C      | Keep as visual proof and pair later with deeper system-side assertions for each dashboard state.                      | Screenshot capture only; no standalone system-side write/read assertions beyond render.                                                             |
| `web/tests/e2e-ui/smoke/auth.spec.ts`                         | `docs/screen_specs/login.md`; `docs/screen_specs/signup.md`; `docs/screen_specs/forgot_password.md`; `docs/screen_specs/reset_password.md`; `docs/screen_specs/verify_email.md`                                                                               | Smoke login success and OAuth route-shape contract (302/501, never 500).                                                             | A      | Keep smoke assertions deterministic and complementary to full auth coverage.                                          | First-party auth gate proof on customer-facing routes.                                                                                              |
| `web/tests/e2e-ui/smoke/dashboard.spec.ts`                    | `docs/screen_specs/dashboard.md`; `docs/screen_specs/logs.md`; `docs/screen_specs/error_boundaries.md`                                                                                                                                                        | Smoke dashboard core sections, nav links, and plan badge presence.                                                                   | A      | Strengthen smoke checks to catch structural regressions without duplicating full-suite behavior.                      | First-party dashboard read-path proof, quick regression guard.                                                                                      |
| `web/tests/e2e-ui/smoke/indexes.spec.ts`                      | `docs/screen_specs/indexes.md`; `docs/screen_specs/index_detail.md`; `docs/screen_specs/search_preview.md`                                                                                                                                                    | Smoke seeded index visibility in indexes table.                                                                                      | A      | Add deterministic table-row identity assertions that fail on wrong tenant/seed.                                       | First-party index read-path smoke guard with staged seeded data.                                                                                    |
| `web/tests/e2e-ui/smoke/public-staging-host.spec.ts`          | **PROVISIONAL GAP:** no current `docs/screen_specs/*.md` owner honestly owns canonical-host assertion                                                                                                                                                         | Verifies staging serves SvelteKit app (`_app/immutable`) and remote target host matches canonical staging hostname.                  | C      | Define explicit owner for canonical-host contract, then promote this row to bucket B once owner is assigned.          | Canonical-host contract is external-surface proof; owner mapping unresolved in current screen-spec set, so provisional gap retained in Stage 1 map. |

## Exact-Once Row Verification Command

```bash
python3 - <<'PY'
from pathlib import Path
import re
excluded = {
    'web/tests/e2e-ui/full/signup_to_paid_invoice.spec.ts',
    'web/tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts',
}
patterns = (
    'web/tests/e2e-ui/full/*.spec.ts',
    'web/tests/e2e-ui/full/admin/*.spec.ts',
    'web/tests/e2e-ui/smoke/*.spec.ts',
)
expected = sorted(
    p.as_posix()
    for pattern in patterns
    for p in Path().glob(pattern)
    if p.as_posix() not in excluded
)

text = Path('web/tests/e2e-ui/full/system_proof_gaps.md').read_text()
rows = re.findall(r'^\| `(web/tests/e2e-ui/(?:full|smoke)/[^`]+\.spec\.ts)` \|', text, flags=re.MULTILINE)
counts = {p: rows.count(p) for p in expected}
missing = [p for p, c in counts.items() if c == 0]
dups = [p for p, c in counts.items() if c > 1]
extra = sorted(set(rows) - set(expected))
print(f'rows_matched={len(rows)} expected={len(expected)}')
print('missing=', missing)
print('duplicates=', dups)
print('extra=', extra)
raise SystemExit(1 if missing or dups or extra else 0)
PY
```

## Stage 2 Seam Gaps

Stage 2 derives one canonical list of bucket A/B rows from the table above whose
future proof target requires a shared helper that does not yet exist in
`web/tests/fixtures/staging_db_lookup.ts`, `web/tests/fixtures/staging_stripe_lookup.ts`,
or the cleanup registry in `web/tests/fixtures/fixtures.ts`. Stages 3/4/5 reuse
this section as the SSOT for seam needs — do NOT re-derive it from the table
above; instead extend this section if a new caller surfaces.

Existing shared seams already in place at Stage 2 start:

- `staging_db_lookup.ts` exports:
  `buildVerificationTokenLookupSql`,
  `buildSsmStagingPsqlCommand`,
  `parseSingleColumnSingleRowOutput`,
  `execSsmStagingShell`,
  `findVerificationTokenViaStagingSsm`,
  `findPaidInvoiceEvidenceViaStagingSsm`.
- `staging_stripe_lookup.ts` exports `readStripeDefaultPaymentMethod`.
- `fixtures.ts` owns teardown via `_trackIndexForCleanup`, `_trackCustomerForCleanup`,
  `deleteTrackedCustomerForCleanup`, `cleanupStaleFixtureIndexesOnce`, and the
  `STALE_FIXTURE_INDEX_PREFIXES = ['e2e-', 'manual-iso-', 'test-index']` set.

### Seam gaps (bucket A/B specs whose Stage 1 future proof target lacks a shared call path)

| Spec                                                  | Future proof target (from canonical table)                                                    | Missing shared seam                                                                                                                                                                   | Owner file to extend   |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- |
| `web/tests/e2e-ui/full/account.spec.ts`               | Tighten destructive-account assertions to exact persistence/readback contract rows.           | Customer-row readback by email returning `(customer_id, status, stripe_customer_id)`; needed to assert `status='deleted'` after delete-account flow.                                  | `staging_db_lookup.ts` |
| `web/tests/e2e-ui/full/auth.spec.ts`                  | Add success-path verify-email/signup completion proofs.                                       | Customer-row readback by email returning verification status (`email_verified_at IS NOT NULL`, `email_verify_token IS NULL`); needed to assert verify-email actually flipped the row. | `staging_db_lookup.ts` |
| `web/tests/e2e-ui/full/onboarding.spec.ts`            | Add stronger post-create index ownership/readback assertions from route-owner specs.          | Customer-row readback by email (same shape as above) to bind the just-created customer to its index ownership chain.                                                                  | `staging_db_lookup.ts` |
| `web/tests/e2e-ui/smoke/auth.spec.ts`                 | Keep smoke assertions deterministic and complementary to full auth coverage.                  | Same customer-row readback to gate smoke success path without inlining shell+psql.                                                                                                    | `staging_db_lookup.ts` |
| `web/tests/e2e-ui/full/admin/customer-detail.spec.ts` | Add tighter server-backed status transition proofs with explicit before/after row assertions. | Customer-row readback by email returning `status` — also covers admin suspend/reactivate before/after row reads.                                                                      | `staging_db_lookup.ts` |

Pipe-separated multi-column DB readbacks all share the same parser shape that
`findPaidInvoiceEvidenceViaStagingSsm` already uses internally
(`parseSingleRowPipeSeparatedOutput`); that parser is currently file-private.
The Stage 2 minimum extension is to:

1. Export `parseSingleRowPipeSeparatedOutput` from `staging_db_lookup.ts` so new
   multi-column readbacks reuse it directly instead of re-implementing or
   adding a parallel parser module.
2. Add `buildCustomerStatusLookupSql(email)` and
   `findCustomerStatusViaStagingSsm(email)` to `staging_db_lookup.ts` returning
   `(customer_id, status, stripe_customer_id, email_verified_at_is_null, email_verify_token_is_null)`
   — one call path covers all five rows above.

Buckets not covered here are bucket C (visual-only, content-only, or
canonical-host) which the canonical retained-spec table already documents as
having no system-side write/read mutation proof target for this sweep.

## Stage 3 Dispositions (identity + key proof hardening)

- `web/tests/e2e-ui/full/account.spec.ts`: delete-account flow now proves persisted post-write state through `findCustomerStatusViaStagingSsm(email)` and asserts `stagingStatus === 'deleted'`.
- `web/tests/e2e-ui/full/auth.spec.ts`: fresh signup + verify-email success path now proves DB-state transition via `findCustomerStatusViaStagingSsm(email)` before/after `completeFreshSignupEmailVerification(...)`:
  pre-verify requires `email_verified_at IS NULL` and token present; post-verify requires verified timestamp present and token cleared.
- `web/tests/e2e-ui/full/api-keys.spec.ts`: create/revoke write paths now prove lifecycle via fixture-owned `listApiKeys()` read seam in `fixtures.ts` (create presence by name; revoke absence by seeded id). Reveal assertions remain deterministic read-only UI contracts.
- `web/tests/e2e-ui/smoke/auth.spec.ts`: login success path remains read-only and was tightened with deterministic post-login navigation assertions; no new write claim was introduced, so no helper-backed write proof seam is required.

## Stage 4 Dispositions (index lifecycle + search/onboarding proof hardening)

- `web/tests/e2e-ui/full/indexes.spec.ts`: create assertions now verify list row + detail route heading after write; delete assertion now verifies post-delete list absence and detail-route not-found path; preview flow asserts seeded hit content (not widget mount alone), and poll contract failures (`submitFailure`) now fail instead of being reclassified as environment skips.
- `web/tests/e2e-ui/full/unified-search.spec.ts`: retained one shell discoverability test and upgraded active/generate tests to require seeded tenant hit evidence through shared `seedSearchableIndex` + search-preview helpers.
- `web/tests/e2e-ui/full/onboarding.spec.ts`: valid onboarding-create path now proves persisted readback on `/dashboard/indexes` and routes teardown through fixture-owned `registerIndexForCleanup` instead of spec-local delete helper.
- `web/tests/e2e-ui/full/customer-journeys.spec.ts`: journey now registers onboarding-created index via fixture cleanup seam and asserts persisted index presence before continuing documents/search assertions.
- `web/tests/e2e-ui/full/isolation.spec.ts`: added per-tenant list-path visibility assertions for identically named indexes before detail/search checks, while retaining negative cross-tenant hit assertions.
- `web/tests/e2e-ui/smoke/indexes.spec.ts`: smoke proof now extends beyond list cell visibility to detail-route accessibility for the seeded index.
- `web/tests/e2e-ui/full/index-detail.spec.ts`: rules/synonyms expectations now use stable contract assertions (section headings, add/update form presence, Object ID label, Save Rule/Save Synonym controls) instead of brittle exact empty-state copy checks; all tab tests pass green with `--retries=0`.

## Stage 5 Dispositions (admin customer lifecycle proof hardening)

- `web/tests/e2e-ui/full/admin/customer-detail.spec.ts`: soft-delete and suspend/reactivate flows now prove the staging customer row status transitions through `findCustomerStatusViaStagingSsm(email)` (`active` → `suspended` → `active`, plus terminal `deleted`) rather than trusting page-banner/state changes alone.
- `web/tests/e2e-ui/full/billing.spec.ts`: invoice-detail proof now reuses a fixture-owned adapter for `findPaidInvoiceEvidenceViaStagingSsm` and asserts staged invoice id/status/period against the rendered invoice detail route instead of relying on PDF-link presence alone.
- `web/tests/e2e-ui/full/admin/admin-pages.spec.ts`: admin billing bulk-finalize proof now asserts the real action feedback contract (`billing-feedback-message` success or `billing-feedback-error` failure/partial-failure) rather than assuming a success-only banner.
- `web/tests/e2e-ui/full/migration-recovery.spec.ts`: migration proof now asserts the authenticated unavailable page, preserved direct route access, and absence of credential/list/import controls while customer-facing Algolia migration is paused.
- `web/tests/e2e-ui/full/public-pages.spec.ts`: footer legal-link assertions were tightened with deterministic `contentinfo` link contracts while keeping this lane read-only/content-contract (no fabricated backend mutation proof).
- `web/tests/e2e-ui/smoke/public-staging-host.spec.ts`: canonical host smoke remains a provisional owner-gap row; the contract assertion now accepts both immutable-asset and SvelteKit runtime-module bootstraps so it reflects real staging/local host surfaces without inventing a new route owner.
- `web/tests/e2e-ui/full/public-vlm_screenshot_capture.spec.ts`, `web/tests/e2e-ui/full/vlm_screenshot_capture.spec.ts`, and `web/tests/e2e-ui/full/admin/vlm_screenshot_capture.spec.ts`: retained as visual-only bucket-C proofs with `tuples.ts` as sole tuple registry and `assertNoCaptureRedirect` as the redirect guard.

## Stage 7 Audit Dispositions (read-path specs without seam-gap retrofit)

These bucket-A specs were not listed in Stage 2 seam gaps because their future proof targets do not require new shared DB/Stripe lookup helpers. Their current assertions are read-path proofs against staged data; no write-side helper retrofit was in scope for this sweep.

- `web/tests/e2e-ui/full/admin/fleet.spec.ts`: admin login gate, fleet table rendering/filtering, and VM detail navigation are first-party admin read-path proofs. Future hardening (VM detail side-effect assertions tied to admin VM owner spec criteria) requires admin-action write seams not surfaced in this sweep's seam-gap analysis.
- `web/tests/e2e-ui/full/dashboard.spec.ts`: dashboard shell/nav/layout, log-view paths, plan-aware UI behavior, and error boundary copy are first-party route-contract proofs. Future hardening (estimated-bill and logs assertions against exact seeded values) requires billing-data seeding and readback seams outside this sweep's scope.
- `web/tests/e2e-ui/smoke/dashboard.spec.ts`: smoke-level dashboard section rendering, nav link presence, and plan badge visibility are read-path regression guards complementary to the full dashboard suite above. No write-side proof target exists for smoke-level checks.
