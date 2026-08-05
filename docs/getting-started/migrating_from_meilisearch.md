# Migrating from Meilisearch

This guide maps common Meilisearch index, document, search, settings, and synonym operations to fjcloud JWT control-plane routes. Meilisearch is a supported hosted-search source for discovery and retained import-job creation, subject to the endpoint restrictions below.

## Before you start

Complete signup, email verification, and JWT setup in [Customer Quickstart](./customer-quickstart.md). That guide owns account creation and the first successful search. Review [Pricing FAQ](./pricing-faq.md) and [Error Reference](./error-reference.md) for the shared pricing and error contracts.

Use the same fjcloud environment-variable convention as the quickstart:

```bash
export API_BASE_URL="https://api.flapjack.foo"
export AUTH_TOKEN="<jwt-from-registration-or-login>"
export INDEX_NAME="products"
export INDEX_REGION="us-east-1"
```

Use `Authorization: Bearer $AUTH_TOKEN` for fjcloud operations. A Meilisearch host URL and API key belong only in the migration console's live credential fields; they are not fjcloud JWT replacements.

## Operation mapping

| Meilisearch operation | fjcloud route and owner                                               | Parity seam                                                                                                      |
| --------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Create index          | `POST /indexes` -> `create_index`                                     | fjcloud requires explicit creation with a destination region; do not depend on implicit creation from a write.   |
| Add or replace documents | `POST /indexes/{name}/batch` -> `batch_documents` with `addObject` | fjcloud uses a `requests[]` envelope, and the source primary-key value becomes the document `objectID`.           |
| Partially update documents | `POST /indexes/{name}/batch` -> `batch_documents` with `updateObject` | Translate the update into a fjcloud batch request; do not forward a Meilisearch document payload unchanged.   |
| Search an index       | `POST /indexes/{name}/search` -> `test_search`                        | Use the fjcloud search body and JWT authentication rather than Meilisearch query parameters or API-key headers.   |
| Get a document        | `GET /indexes/{name}/objects/{object_id}` -> `get_document`           | fjcloud identifies the record through the `/objects/` path segment.                                               |
| Delete a document     | `DELETE /indexes/{name}/objects/{object_id}` -> `delete_document`     | Delete by the destination `objectID`.                                                                             |
| Update index settings | `PUT /indexes/{name}/settings` -> `update_settings`                   | Translate settings by intent; Meilisearch settings are not a drop-in fjcloud payload contract.                    |
| Update synonyms       | `PUT /indexes/{name}/synonyms/{object_id}` -> `save_synonym`          | Create stable fjcloud synonym IDs and save each destination synonym entry explicitly.                             |
| Configure ranking     | `PUT /indexes/{name}/settings` or `/rules/{object_id}`                | Rebuild ranking intent with fjcloud settings and rules, then verify representative queries.                       |

## fjcloud workflow differences

fjcloud separates verified customer identity from source-search credentials. Use the JWT from the quickstart for destination operations. Use a Meilisearch key only as temporary source credentials when a supported import path asks for it.

Index creation is explicit and region-bound. Create the destination before manual document writes, then translate the Meilisearch primary-key field to fjcloud `objectID` values. Settings, filters, ranking behavior, and synonyms need semantic review rather than direct payload forwarding.

The runnable fjcloud curl patterns for create, batch, search, get, delete, synonym, and rule operations remain in [Migrating from Algolia](./migrating_from_algolia.md). Those examples target fjcloud routes and remain useful for validating a Meilisearch migration.

## Data migration with the console

[Open the migration console](/console/migrate) to inspect current availability and plan the shared workflow:

1. The console first presents destination provider and region eligibility, then source-provider selection. Availability still depends on the selected destination and migration mode.
2. Meilisearch discovery and create requests use the exact wire fields `endpoint` and `apiKey`; `host` is not an accepted alias. Use a temporary, source-restricted read key.
3. Discovery returns neutral index summaries before a retained import job is created. Follow the capability result shown for the selected destination rather than inferring every migration operation from source selection alone.

The retained job-detail route shape is shared across supported providers and preserves `source_provider` in links such as `/console/migrate/[jobId]?source_provider=meilisearch`. Use the manual fjcloud operations above to validate the translated destination behavior before cutover.

## Meilisearch import availability

`SourceImportProvider::has_adapter` returns `true` for `meilisearch`. The discovery and create handlers select Meilisearch-specific request DTOs, so both operations require `endpoint` plus `apiKey` rather than an Algolia-shaped body or a generic `host` field.

Production endpoints must be HTTPS Meilisearch Cloud hosts under `.meilisearch.io`. Self-hosted and loopback sources are refused outside the engine's debug-only local proof mode; fjcloud does not own an allowlist or bypass for that policy.

The overall create flow still fails closed unless migration availability and destination eligibility are enabled. A visible source-provider option alone is not evidence that every migration capability is enabled for the selected destination.

## Unsupported concepts

Translate source behavior deliberately even when using the hosted import adapter:

- Recreate filterable/searchable attributes, typo tolerance, ranking rules, and other search settings through fjcloud index settings. Test filters, sorting, typo behavior, and representative ranking queries before cutover.
- Recreate Meilisearch synonyms with fjcloud synonym IDs through the synonyms API. Verify asymmetric or phrase behavior rather than assuming identical evaluation.
- If a ranking rule has no direct setting equivalent, express the business intent with fjcloud rules or application-side ordering and test it against a known query set.
- Plan cutover around a separately populated fjcloud index. Keep the Meilisearch source authoritative until document counts and representative searches pass.

## Source evidence

- Meilisearch terminology: [Meilisearch indexes and settings](https://www.meilisearch.com/docs/resources/internals/indexes) and [add or replace documents](https://www.meilisearch.com/docs/reference/api/documents/add-or-replace-documents).
- Account, pricing, and shared error owners: [Customer Quickstart](./customer-quickstart.md), [Pricing FAQ](./pricing-faq.md), and [Error Reference](./error-reference.md).
- Shared fjcloud operation examples: [Migrating from Algolia](./migrating_from_algolia.md).
- Adapter boundary owner: `infra/api/src/models/algolia_import_job/provider.rs` (`SourceImportProvider::has_adapter`).
- Hosted-payload owners: `infra/api/src/routes/migration/source.rs` (`ListMeilisearchIndexesRequest`, `list_source_indexes`) and `infra/api/src/routes/migration/jobs.rs` (`CreateMeilisearchImportJobRequest`, `create_import_job`).
- Producer endpoint-policy evidence: `docs/audits/migration-discovery/20260803T212302Z_neutral_discovery_consumer/evidence.md`.
- fjcloud route owners: `infra/api/src/router/route_assembly.rs` (`add_index_lifecycle_and_replica_routes`, `add_index_configuration_routes`), plus the corresponding handlers under `infra/api/src/routes/indexes/`.
