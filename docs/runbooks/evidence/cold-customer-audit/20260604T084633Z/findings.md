# Cold Customer Algolia-Refugee Journey — Canonical Findings

## Evidence Root

- **Original UTC root:** `docs/runbooks/evidence/cold-customer-audit/20260604T084633Z/`
- **Canonical findings owner:** this file.
- **Stage 1 rerun root:** `docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/`
- **Stage 1 guard:** `findings_before_hash=35f22b61cfa0ad2e0e253d0f06572f0bfe3e1a8c` in `docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/preflight.md`.
- **Stage 4 guard result:** unchanged immediately before this update; canonical in-place write was safe.
- **Stage 2 CLI evidence:** `docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/cli/stage_02_cli_evidence.md`, `summary.json`, and `cli_steps.jsonl`.
- **Stage 3 browser evidence:** `docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/browser/stage_03_browser_evidence.md`, `run_stdout.log`, and `browser/test_results/e2e-ui-full-cold_customer_-ff2ff-h-stays-coherent-on-staging-chromium/trace.zip`.
- **Tab owner:** `web/src/routes/console/indexes/[name]/index_detail_tabs.ts` (`INDEX_DETAIL_TABS`).

## Current Qualitative Signal

The stale June 4 blocker narrative is historical only. The current rerun evidence shows the cold-customer journey completes the critical first-search moment from both owner surfaces:

1. **CLI surface:** Stage 2 reports `overall=pass`; `summary.json` preserves `seeded_record_object_id=doc-0` and `seeded_record_title=Document 0`; `cli_steps.jsonl` records `search_index` with `outcome=pass`, HTTP 200, `response_body.nbHits=1`, and a hit with `objectID=doc-0` / `title=Document 0`.
2. **Browser surface:** Stage 3 reports `1 passed (48.7s)` in `browser/run_stdout.log`; `stage_03_browser_evidence.md` records that the live staging journey reached `assertFirstSearchFindsUploadedRecord()`, kept the real `waitForSearchPreviewHitsToContain(page, "Blue Ridge trail running vest", 45_000)` assertion, continued through migrate/billing/pricing, and rendered the uploaded record through `/api/search/<index>`.

This closes the June 4 "both surfaces fail first search" conclusion for current staging. The remaining open question is only F9's tab-depth coverage: the rerun exercises Search Preview and the adjacent surfaces, but does not iterate every index-detail tab.

## Findings Disposition Map

| ID | Previous status | Current disposition | Evidence decision |
|----|-----------------|---------------------|-------------------|
| F1 | `fix-in-stage-5` | no defect found / closed by rerun | Stage 2 owner artifacts prove first post-batch CLI search returns the seeded hit: `overall=pass`, `search_index.outcome=pass`, `response_body.nbHits=1`, `objectID=doc-0`, `title=Document 0`. |
| F2 | `fix-in-stage-5` | no defect found / closed by rerun | Stage 2 reached index creation and completed the full CLI owner against `CANARY_INDEX_REGION=us-east-1`; the historical default-region drift no longer blocks this rerun. |
| F3 | `blocked` | no defect found / closed by rerun | Stage 3 live staging browser run passed through the same-origin Search Preview proxy and rendered the expected uploaded record. |
| F4 | `inconclusive` | no defect found / closed by rerun | Stage 3 kept the real 45 s hit assertion and passed, so first-search hit retrieval is no longer blocked by F3 or ambiguous. |
| F5 | `fix-in-stage-5` | no defect found / closed by rerun | Stage 2 completed registration, email verification, confirmed verified state, batch write, search, and cleanup; the historical inbox-domain probe drift no longer blocks this rerun. |
| F6 | `blocked` | no defect found / closed by rerun | Stage 3 continued through the post-login pricing assertion after Search Preview. |
| F7 | `blocked` | no defect found / closed by rerun | Stage 3 continued through the billing assertion after Search Preview. |
| F8 | `blocked` | no defect found / closed by rerun | Stage 3 continued through the migrate-from-Algolia assertion after Search Preview. |
| F9 | `inconclusive` | inconclusive, no defect observed | `INDEX_DETAIL_TABS` defines the expected tab inventory and the rerun reaches Search Preview, but the owner evidence still does not programmatically iterate every tab panel. No new tab probe was added in Stage 4. |

## Findings (Defects And Open Questions)

| ID | surface | owner files | severity | disposition | evidence summary |
|----|---------|-------------|----------|-------------|------------------|
| F1 | CLI: search after batch upload | `scripts/canary/contracts/cold_customer_journey_walkthrough.sh`, `infra/api/src/routes/indexes/search.rs`, `infra/api/src/services/flapjack_proxy/search.rs` | P0 | no defect found | Current Stage 2 owner artifacts prove the seeded search hit is visible: `summary.json` has `overall=pass`, `seeded_record_object_id=doc-0`, `seeded_record_title=Document 0`; `cli_steps.jsonl` has `search_index.outcome=pass`, HTTP 200, `response_body.nbHits=1`, and the `doc-0` hit. June 4's empty-hit result is historical context, not current staging truth. |
| F2 | CLI: probe default region ID | `scripts/canary/contracts/cold_customer_journey_walkthrough.sh`, `infra/api/src/provisioner/region_map.rs` | P1 | no defect found | Stage 2 used the owner command with `CANARY_INDEX_REGION=us-east-1`, created the index successfully, and completed the full CLI owner. The region-default issue is closed for this rerun; no product defect is present in current evidence. |
| F3 | Browser: Search Preview proxy auth | `web/src/routes/api/search/[name]/+server.ts`, `web/src/lib/flapjack-search-client.ts`, `web/tests/fixtures/search-preview-helpers.ts` | P0 | no defect found | Stage 3 evidence records that live staging generated the preview key, queried through `/api/search/<index>`, and rendered `Blue Ridge trail running vest`; `run_stdout.log` reports the Playwright owner passed. The June 4 deploy-lag blocker is no longer current. |
| F4 | Browser: first-search hit retrieval | `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts`, `web/tests/fixtures/search-preview-helpers.ts` | P0 | no defect found | The passing Stage 3 rerun kept the real `waitForSearchPreviewHitsToContain(page, "Blue Ridge trail running vest", 45_000)` assertion. Trace metadata shows the run moved from the Search Preview hit wait to `/console/migrate`, proving the hit assertion cleared before adjacent-surface checks. |
| F5 | CLI: probe default inbox domain | `scripts/canary/contracts/cold_customer_journey_walkthrough.sh`, `scripts/canary/customer_loop_synthetic.sh` | P1 | no defect found | Stage 2 verified email successfully, confirmed `email_verified=true`, and completed the full CLI owner. The historical inbox-domain drift is closed for the current rerun. |
| F6 | Browser: post-login pricing surface | `web/src/routes/pricing/+page.svelte`, `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts` | P1 | no defect found | Stage 3 evidence says the passing run continued through adjacent migrate, billing, and pricing surfaces after Search Preview. Trace metadata includes navigation to `/pricing` and the pricing assertions after the Search Preview hit wait. |
| F7 | Browser: billing tab | `web/src/routes/console/billing/+page.svelte`, `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts` | P1 | no defect found | Stage 3 evidence says the passing run continued through billing after Search Preview. Trace metadata includes navigation to `/console/billing` and billing assertions in `assertAdjacentCustomerSurfaces`. |
| F8 | Browser: migrate-from-Algolia tab | `web/src/routes/console/migrate/+page.svelte`, `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts` | P1 | no defect found | Stage 3 evidence says the passing run continued through migrate after Search Preview. Trace metadata includes navigation to `/console/migrate` and the migrate form assertions in `assertAdjacentCustomerSurfaces`. |
| F9 | Browser: console tabs (post-creation) | `web/src/routes/console/indexes/[name]/index_detail_tabs.ts`, `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts` | P2 | inconclusive | `INDEX_DETAIL_TABS` defines Overview, Settings, Documents, Dictionaries, Rules, Synonyms, Personalization, Recommendations, Chat, Suggestions, Analytics, Metrics, Merchandising, Experiments, Events, Security Sources, and Search Preview. The rerun reaches Search Preview and therefore provides proxy evidence that the post-creation tab route is usable, but it does not assert every tab's panel. Exact remaining gap: no per-tab iteration/content assertion in the current owner evidence. |

## Coverage Audit — Surfaces Examined With No Defect Found

| Surface | Evidence anchor | Owner files | Note |
|---------|-----------------|-------------|------|
| CLI: register | `20260605T092601Z_rerun/cli/cli_steps.jsonl` step `register` (HTTP 201) | `scripts/canary/contracts/cold_customer_journey_walkthrough.sh`, `scripts/lib/customer_lifecycle_steps.sh`, `infra/api/src/routes/auth.rs` | Signup completed. |
| CLI: email verification | `20260605T092601Z_rerun/cli/cli_steps.jsonl` step `verify_email` (HTTP 200) | `scripts/lib/customer_lifecycle_steps.sh`, `infra/api/src/routes/auth.rs` | Verification email landed and `/auth/verify-email` accepted it. |
| CLI: confirm verified state | `20260605T092601Z_rerun/cli/cli_steps.jsonl` step `confirm_verified` (HTTP 200) | `infra/api/src/routes/account.rs` | Verified account state confirmed. |
| CLI: index creation | `20260605T092601Z_rerun/cli/cli_steps.jsonl` step `create_index` (HTTP 201) | `infra/api/src/routes/indexes/lifecycle.rs`, `infra/api/src/provisioner/region_map.rs` | Index created in the rerun. |
| CLI: batch write | `20260605T092601Z_rerun/cli/cli_steps.jsonl` step `batch_write` (HTTP 200) | `infra/api/src/services/flapjack_proxy/documents.rs`, `scripts/lib/deterministic_batch_payload.sh` | Five deterministic records accepted. |
| CLI: first search | `20260605T092601Z_rerun/cli/cli_steps.jsonl` step `search_index` (HTTP 200, `nbHits=1`) | `infra/api/src/routes/indexes/search.rs`, `infra/api/src/services/flapjack_proxy/search.rs` | Seeded `doc-0` / `Document 0` hit returned. |
| CLI: index deletion | `20260605T092601Z_rerun/cli/cli_steps.jsonl` step `delete_index` (HTTP 204) | `infra/api/src/routes/indexes/lifecycle.rs` | Cleanup completed. |
| CLI: account/admin cleanup | `20260605T092601Z_rerun/cli/cli_steps.jsonl` steps `delete_account` and `admin_cleanup` | `infra/api/src/routes/account.rs`, `infra/api/src/routes/admin/tenants.rs` | Cleanup completed; admin cleanup's 404 is accepted because account deletion already removed the tenant. |
| Browser: Search Preview first hit | `20260605T092601Z_rerun/browser/stage_03_browser_evidence.md`, `browser/run_stdout.log`, `browser/test_results/.../trace.zip` | `web/src/routes/api/search/[name]/+server.ts`, `web/src/lib/flapjack-search-client.ts`, `web/tests/fixtures/search-preview-helpers.ts` | Live staging rendered `Blue Ridge trail running vest`; Playwright owner passed. |
| Browser: migrate-from-Algolia | `20260605T092601Z_rerun/browser/stage_03_browser_evidence.md`, trace metadata | `web/src/routes/console/migrate/+page.svelte`, `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts` | Adjacent surface reached after Search Preview. |
| Browser: billing | `20260605T092601Z_rerun/browser/stage_03_browser_evidence.md`, trace metadata | `web/src/routes/console/billing/+page.svelte`, `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts` | Adjacent surface reached after Search Preview. |
| Browser: pricing | `20260605T092601Z_rerun/browser/stage_03_browser_evidence.md`, trace metadata | `web/src/routes/pricing/+page.svelte`, `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts` | Public and post-login pricing assertions reached. |
| Browser: index-detail tab route | `web/src/routes/console/indexes/[name]/index_detail_tabs.ts`, Stage 3 Search Preview traversal | `web/src/routes/console/indexes/[name]/index_detail_tabs.ts`, `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts` | Search Preview is exercised; full per-tab coverage remains F9's explicit gap. |

## Blocked / Inconclusive Detail (Consolidated)

No current blocked rows remain after the Stage 2 and Stage 3 reruns.

F9 remains inconclusive:

- **Exact gap:** the current browser owner reaches Search Preview but does not iterate all `INDEX_DETAIL_TABS` entries and assert each tab panel's content.
- **Proxy evidence used:** `INDEX_DETAIL_TABS` is the canonical tab inventory, and the Stage 3 journey proves the post-creation index-detail route can reach Search Preview after record upload.
- **Why no new probe was added:** Stage 4 is disposition-only; the checklist explicitly forbids adding tab-iteration work, a new spec, or a new probe family.
- **Open question:** whether every non-Search-Preview index-detail tab panel renders meaningful content for a cold customer under the same staging session.

## Internal Consistency Check

- The stale June 4 deploy-lag blocker logic is retained only as historical context; current dispositions are based on Stage 2/3 owner artifacts under `20260605T092601Z_rerun/`.
- Every row with `no defect found` names the current artifact that closed it.
- The only `inconclusive` row is F9, and it records the exact evidence gap rather than implying a product defect.
- No `blocked` rows remain.
- The canonical findings file stayed the single narrative because the Stage 1 hash guard matched before write.
