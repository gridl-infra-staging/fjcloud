# Pricing Audit Runbook

Use this runbook whenever provider pricing inputs change in
`infra/pricing-calculator/src/providers/`.

## Goal

Keep the public comparison surface accurate by updating provider pricing inputs,
refreshing each provider module's `last_verified` date only after full source
verification, with wall-clock freshness surfaced by the non-gating nightly
`pricing-freshness` tripwire.

## When To Run

- Any provider rate/plan change
- Any provider billing-model assumption change
- Any metadata source URL change
- Scheduled periodic pricing re-verification

## 1. Re-verify provider pricing sources

For every registered provider module in
`infra/pricing-calculator/src/providers/`:

- Re-open the source URLs from that module's `metadata().source_urls`
- Confirm pricing constants and plan assumptions still match published sources
- Update constants/assumptions in that provider module if needed

## 2. Refresh `last_verified` in each provider module

After source-backed verification, set `metadata().last_verified` in each
provider module to `Some(current_verification_date)`.

If a provider still relies on modeled or training-data inputs, keep
`metadata().last_verified = None` so the module does not claim a source-backed
verification date it does not actually have.

Do not refresh `last_verified` from the calendar alone. Re-open
`metadata().source_urls`, confirm pricing constants and plan assumptions against
the source pages, update the provider module only when those source-backed
values changed, and refresh `last_verified` only after that verification is
complete.

Expected provider modules:

- `algolia.rs`
- `griddle.rs`
- `meilisearch_resource_based.rs`
- `typesense_cloud.rs`
- `elastic_cloud.rs`
- `aws_opensearch.rs`

## 3. Keep undated third-party evidence explicit

`provider_registry()` in `infra/pricing-calculator/src/providers/mod.rs` is the
canonical provider list, and the competitor verification guard
`undated_third_party_metadata_is_reported_as_never_verified()` derives its
denominator from that registry with `ProviderId::Griddle` filtered out. That
leaves five third-party competitors for the guard to inspect; Flapjack Cloud is
our own product, not a competitor modeled from a public page.

Every third-party competitor whose `metadata().last_verified` is `None` must
appear in the `STAGE_2_UNVERIFIED_COMPETITOR_EVIDENCE` table in the same file,
or the guard fails. That table is the guard's sole expected-provider list; each
`(ProviderId, &str)` row records the observed source gap and the evidence bundle
that demonstrates it.

`undated_third_party_metadata_is_reported_as_never_verified()` checks that the
table matches the undated competitor metadata and that every listed provider is
reported with `ProviderFreshnessReason::NeverVerified`.
`unverified_competitor_evidence_reasons_record_observed_stage_2_status()` checks
that every reason names the current evidence bundle and source gap instead of a
placeholder status.

Remove an entry only after that provider's metadata carries a source-backed
`last_verified` date earned under section 4. Removing it while `last_verified`
is still `None` turns the guard red, which is the intended failure.

This is a separate concern from `stale_providers()` and `stale_providers_as_of()`,
which report both dated providers older than the threshold and undated entries.
Undated metadata is reported as `ProviderFreshnessReason::NeverVerified`; it is
not excluded from freshness output.

`last_verified` is customer-facing, not just an operator record: it feeds
`ProviderMetadata::verification_label()`, which `/pricing/compare` passes
through and `web/src/lib/components/LandingPricingCalculator.svelte` renders, so
an unearned date misleads visitors and not only operators.

## 4. Capture the evidence bundle before setting a date

A `last_verified` date asserts that a source was retrieved and read. Do not add
one when the source was not actually fetched, and never refresh a date from the
calendar alone — a calendar-only refresh is invalid regardless of how recently
the constants were last touched.

For each verification pass, capture evidence under
`docs/runbooks/evidence/pricing-audit/<UTCTIMESTAMP>/<provider>/`:

- The exact fetch command, verbatim, including every flag.
- The HTTP status and the effective URL after redirects.
- The fetched bytes. When a response is too large or too noisy to keep whole,
  keep an extracted price block instead, plus the full response headers.
- A `summary.md` for that provider recording the fetch results and, wherever the
  source did not fully back the model, the gap disposition: the exact gap, the
  smallest unblock, the owner files, the usable proxy with its bias and
  tolerance, and the ship/revert/park decision.

Every pricing constant changed during the pass needs a hand-calculated
known-answer assertion in that provider module's test section — expected values
worked out by hand from the captured source, not a snapshot of what the code
already returns.

Only after that capture is complete may `metadata().last_verified` move from
`None` to a date. When the fetch succeeded but the source did not expose every
modeled input, the honest outcome is to leave `last_verified = None` and keep
the provider recorded in the evidence table under section 3.

## 5. Understand the nightly freshness tripwire

Deploys are no longer blocked by competitor-pricing freshness. The deterministic
freshness seam lives in `infra/pricing-calculator/src/lib.rs` and
`infra/pricing-calculator/src/providers/mod.rs`; the wall-clock 90-day check now
runs only through the non-gating nightly `pricing-freshness` workflow job:

```bash
cd infra && cargo test -p pricing-calculator -- --ignored pricing_freshness_wall_clock_tripwire
```

Freshness logic:

- `stale_providers(90)` reports dated providers older than 90 days and
  undated providers as `NeverVerified`
- `ensure_pricing_freshness(90)` returns an error when either kind is present,
  naming affected providers and their verification labels

A red nightly means competitor pricing metadata is either older than the
accepted 90-day window or has never been verified. It does not block deploys.
The correct operator response is to re-verify the affected provider source URLs
before changing `last_verified`.

## 6. Run full validation commands

Run this exact command set after pricing updates:

```bash
cd infra && cargo test -p pricing-calculator -- compare_all
cd infra && cargo test -p pricing-calculator -- preset
cd infra && cargo test -p pricing-calculator -- stale
cd infra && cargo test -p pricing-calculator
cd infra && cargo check -p pricing-calculator
cd infra && cargo clippy -p pricing-calculator -- -D warnings
```

## 7. Update docs if public surface changed

If API names or maintenance workflow changed, update:

- `infra/pricing-calculator/src/lib.rs` exports
- `README.md` key-files/repo-structure references
- `FEATURES.md` pricing calculator feature entries
