# Algolia to fjcloud Route Mapping and Gaps

UTC evidence directory: `docs/runbooks/evidence/algolia_api_mapping/20260603T180703Z`

This is the single Stage 1 mapping source of truth for later quickstart, migration, and validator work. Algolia source details live in `algolia_api_surface.md`; fjcloud behavior is mapped only from the route assembly and handler owners cited below.

Canonical fjcloud route owners:

- `infra/api/src/router/route_assembly.rs:217-225` registers `POST /indexes` -> `create_index` and `POST /indexes/:name/search` -> `test_search`.
- `infra/api/src/router/route_assembly.rs:250-265` registers rule and synonym search/get/put/delete routes, including `save_rule` and `save_synonym`.
- `infra/api/src/router/route_assembly.rs:283-289` registers `POST /indexes/:name/batch` -> `batch_documents` and `GET/DELETE /indexes/:name/objects/:object_id` -> `get_document` / `delete_document`.
- `infra/api/src/router/route_assembly.rs:402-410` registers migration-assist routes, not default customer write routes.
- `infra/api/src/router/route_assembly.rs:414-419` registers onboarding credential generation, not the default JWT write path.
- `infra/api/src/routes/migration.rs:88-131` validates Algolia credentials and delegates list/migrate work to the migration target.
- `infra/api/src/routes/indexes/lifecycle.rs:49-112` owns `create_index`.
- `infra/api/src/routes/indexes/documents.rs:250-300` owns `batch_documents`; `documents.rs:250-253` documents `addObject`, `updateObject`, and `deleteObject` actions in the `requests` array.
- `infra/api/src/routes/indexes/documents.rs:354-403` owns `get_document`.
- `infra/api/src/routes/indexes/documents.rs:405-454` owns `delete_document`.
- `infra/api/src/routes/indexes/search.rs:119-183` owns `test_search`.
- `infra/api/src/routes/indexes/synonyms.rs:120-171` owns `save_synonym`.
- `infra/api/src/routes/indexes/rules.rs:117-168` owns `save_rule`.
- `infra/api/src/routes/onboarding.rs:238-302` owns optional search/browse-key generation via `generate_credentials`.

Current customer-doc drift:

- `docs/getting-started/customer-quickstart.md:81-126` still routes customers through `POST /onboarding/credentials`, then data-plane `.../batch` and `.../query`.
- `docs/getting-started/error-reference.md:38-40` still documents onboarding-credential errors as part of the primary customer path.

Current validator drift:

- `scripts/validate_customer_quickstart.sh:177-260` covers `/health`, `/docs`, OPTIONS on `/auth/register`, `/auth/verify-email`, and `/indexes/contract-check/search`, then delegates to the canary loop.
- `scripts/canary/customer_loop_synthetic.sh:799-921` exercises `run_index_batch_step`, `run_index_search_step`, and `run_customer_loop`; the data-plane write is a batch `addObject`, and the search path is `/indexes/${CANARY_INDEX_NAME}/search`.

Non-default seams:

- `infra/api/src/routes/migration.rs:88-131` plus `route_assembly.rs:402-410` are migration-assist routes. They are not the default JWT write path for ordinary customer docs.
- `infra/api/src/routes/onboarding.rs:238-302` plus `route_assembly.rs:414-419` are optional search/browse-key generation. They should not be treated as the primary write/auth path for the Stage 2 quickstart rewrite.

## Create index

Algolia operation evidence: `algolia_api_surface.md` says reachable official sources do not establish a standalone create-index REST endpoint; they establish create-on-write behavior.

fjcloud owner:

- Route: `POST /indexes`, registered in `infra/api/src/router/route_assembly.rs:217-220`.
- Handler: `create_index` in `infra/api/src/routes/indexes/lifecycle.rs:49-112`.

Mapping:

- Algolia create-on-write nuance maps to fjcloud explicit control-plane index creation.
- fjcloud requires a verified customer, validates the index name and region, enforces rate limits and quota, then creates the index on a shared VM.

Gap / parity seam:

- Not 1:1. Algolia can create an index by writing records/rules/synonyms/settings to a missing index; fjcloud exposes explicit `POST /indexes` as the canonical create-index customer path.
- Stage 2 docs should not imply Algolia-style implicit index creation on first record write unless route code changes later.

## Push records

Algolia operation evidence: `algolia_api_surface.md` maps save records to a batch write helper using `addObject`.

fjcloud owner:

- Route: `POST /indexes/:name/batch`, registered in `infra/api/src/router/route_assembly.rs:283`.
- Handler: `batch_documents` in `infra/api/src/routes/indexes/documents.rs:250-300`.

Mapping:

- Algolia `saveObjects` / `addObject` maps to fjcloud `batch_documents` with a `requests` array action of `addObject`.

Gap / parity seam:

- fjcloud uses a JWT-authenticated control-plane route path `/indexes/{name}/batch`, not the current quickstart's data-plane `/1/indexes/{name}/batch` with Algolia headers.
- Stage 4 must keep batch write coverage, but should anchor it to the canonical JWT path unless later stages intentionally preserve data-plane docs.

## Search

Algolia operation evidence: `algolia_api_surface.md` maps search to `POST /1/indexes/{indexName}/query`.

fjcloud owner:

- Route: `POST /indexes/:name/search`, registered in `infra/api/src/router/route_assembly.rs:225`.
- Handler: `test_search` in `infra/api/src/routes/indexes/search.rs:119-183`.

Mapping:

- Algolia single-index search maps to fjcloud `test_search`.
- fjcloud builds a search body from a validated `query` plus extra parameters, records access, and delegates to flapjack using the tenant-scoped index UID.

Gap / parity seam:

- Path differs: Algolia REST uses `/1/indexes/{indexName}/query`; fjcloud control plane uses `/indexes/{name}/search`.
- Current quickstart documents data-plane `/query` at `docs/getting-started/customer-quickstart.md:123-126`, which is drift relative to this Stage 1 owner mapping.

## Get object

Algolia operation evidence: `algolia_api_surface.md` maps get object to `GET /1/indexes/{indexName}/{objectID}`.

fjcloud owner:

- Route: `GET /indexes/:name/objects/:object_id`, registered in `infra/api/src/router/route_assembly.rs:286-289`.
- Handler: `get_document` in `infra/api/src/routes/indexes/documents.rs:354-403`.

Mapping:

- Algolia get object maps to fjcloud `get_document`.
- fjcloud validates the `object_id`, rejects cold/restoring indexes through the shared ready-target resolver, and delegates to flapjack.

Gap / parity seam:

- Path differs: fjcloud includes `/objects/{object_id}` while Algolia REST puts `{objectID}` directly under the index path.
- Stage 4 currently has no validator coverage for object retrieval; add it beyond the batch-plus-search loop.

## Update record

Algolia operation evidence: `algolia_api_surface.md` maps update record to single-record `partialUpdateObject` and multi-record `partialUpdateObjects` batch behavior.

fjcloud owner:

- Route: `POST /indexes/:name/batch`, registered in `infra/api/src/router/route_assembly.rs:283`.
- Handler: `batch_documents` in `infra/api/src/routes/indexes/documents.rs:250-300`.

Mapping:

- Algolia partial update maps to fjcloud `batch_documents` with `requests[].action` of `updateObject`.
- `documents.rs:250-253` is the owner anchor for the supported batch action vocabulary.

Gap / parity seam:

- Not 1:1. fjcloud record updates currently flow through `POST /indexes/{name}/batch` rather than a dedicated object-update route.
- There is no `POST /indexes/{name}/objects/{object_id}/partial` equivalent in the cited route assembly.
- Stage 4 must add validator coverage for `updateObject` through the batch route.

## Delete record

Algolia operation evidence: `algolia_api_surface.md` maps single-record delete to `DELETE /1/indexes/{indexName}/{objectID}` and multi-record delete to batch `deleteObject`.

fjcloud owner:

- Route: `DELETE /indexes/:name/objects/:object_id`, registered in `infra/api/src/router/route_assembly.rs:286-289`.
- Handler: `delete_document` in `infra/api/src/routes/indexes/documents.rs:405-454`.

Mapping:

- Algolia single-record delete maps to fjcloud `delete_document`.
- Algolia batch delete can also be represented through fjcloud `batch_documents` with `deleteObject`, but the required Stage 1 mapping owner for delete record is `delete_document`.

Gap / parity seam:

- Path differs in the same way as get object: fjcloud uses `/objects/{object_id}`.
- Stage 4 currently has no validator coverage for single-record delete.

## Save synonym

Algolia operation evidence: `algolia_api_surface.md` maps save synonym to `PUT /1/indexes/{indexName}/synonyms/{objectID}`.

fjcloud owner:

- Route: `PUT /indexes/:name/synonyms/:object_id`, registered in `infra/api/src/router/route_assembly.rs:257-265`.
- Handler: `save_synonym` in `infra/api/src/routes/indexes/synonyms.rs:120-171`.

Mapping:

- Algolia save synonym maps directly to fjcloud `save_synonym`.
- fjcloud validates the synonym object ID path segment, resolves a ready index target, and forwards the JSON body to flapjack.

Gap / parity seam:

- Mostly 1:1 by operation type, with a control-plane path prefix difference and JWT auth rather than Algolia application/API key headers.
- Stage 4 currently has no synonym validator coverage.

## Save rule

Algolia operation evidence: `algolia_api_surface.md` maps save rule to `PUT /1/indexes/{indexName}/rules/{objectID}`.

fjcloud owner:

- Route: `PUT /indexes/:name/rules/:object_id`, registered in `infra/api/src/router/route_assembly.rs:250-255`.
- Handler: `save_rule` in `infra/api/src/routes/indexes/rules.rs:117-168`.

Mapping:

- Algolia save rule maps directly to fjcloud `save_rule`.
- fjcloud validates the rule object ID path segment, resolves a ready index target, and forwards the JSON body to flapjack.

Gap / parity seam:

- Mostly 1:1 by operation type, with a control-plane path prefix difference and JWT auth rather than Algolia application/API key headers.
- Stage 4 currently has no rule validator coverage.

## Later-stage handoff

Stage 2 should reuse the doc-drift findings in this file, especially that `customer-quickstart.md:81-126` and `error-reference.md:38-40` still center onboarding credentials and data-plane paths.

Stage 3 should reuse this mapping matrix as its single source of truth for Algolia-to-fjcloud operation mapping. Do not recopy or rederive mappings into a new source-of-truth file.

Stage 4 should reuse the validator-gap findings here instead of rediscovering coverage holes: current validation covers registration, email verification, batch `addObject`, and search, but does not cover get object, update record via `updateObject`, delete record, save synonym, or save rule.

Open questions:

- Whether later stages intentionally keep any data-plane compatibility docs. Stage 1 maps only repo-owned fjcloud control-plane owners plus explicitly non-default onboarding/migration seams.
