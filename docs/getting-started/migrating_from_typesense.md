# Migrating from Typesense

This guide maps common Typesense collection, document, search, synonym, and curation operations to fjcloud JWT control-plane routes. Typesense is a supported hosted-search source for discovery and retained import-job creation, subject to the endpoint restrictions below.

## Before you start

Complete signup, email verification, and JWT setup in [Customer Quickstart](./customer-quickstart.md). That guide owns account creation and the first successful search. Review [Pricing FAQ](./pricing-faq.md) and [Error Reference](./error-reference.md) for the shared pricing and error contracts.

Use the same fjcloud environment-variable convention as the quickstart:

```bash
export API_BASE_URL="https://api.flapjack.foo"
export AUTH_TOKEN="<jwt-from-registration-or-login>"
export INDEX_NAME="products"
export INDEX_REGION="us-east-1"
```

Use `Authorization: Bearer $AUTH_TOKEN` for fjcloud operations. A Typesense host URL and API key belong only in the migration console's live credential fields; they are not fjcloud JWT replacements.

## Operation mapping

| Typesense operation | fjcloud route and owner                                               | Parity seam                                                                                                        |
| ------------------- | --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Create collection   | `POST /indexes` -> `create_index`                                     | A fjcloud index is the destination container and requires an explicit region.                                      |
| Import or upsert documents | `POST /indexes/{name}/batch` -> `batch_documents` with `addObject` | fjcloud uses a `requests[]` envelope; preserve the Typesense document `id` as `objectID` when it is the stable key. |
| Partially update documents | `POST /indexes/{name}/batch` -> `batch_documents` with `updateObject` | Translate partial changes into fjcloud batch actions instead of forwarding Typesense import parameters.       |
| Search a collection | `POST /indexes/{name}/search` -> `test_search`                        | Use the fjcloud search body and JWT authentication instead of Typesense query parameters or API-key headers.       |
| Retrieve a document | `GET /indexes/{name}/objects/{object_id}` -> `get_document`           | fjcloud identifies the record through the `/objects/` path segment.                                                 |
| Delete a document   | `DELETE /indexes/{name}/objects/{object_id}` -> `delete_document`     | Delete by the destination `objectID`.                                                                               |
| Configure collection schema and search behavior | `PUT /indexes/{name}/settings` -> `update_settings` | Translate field, filter, facet, sort, and ranking intent; schemas are not interchangeable payloads.             |
| Configure synonym sets | `PUT /indexes/{name}/synonyms/{object_id}` -> `save_synonym`       | fjcloud synonyms are index-scoped entries; attach equivalent entries to each destination that needs them.           |
| Configure curations or overrides | `PUT /indexes/{name}/rules/{object_id}` -> `save_rule`        | Rebuild the curation intent as fjcloud rules and verify the affected queries.                                        |

## fjcloud workflow differences

fjcloud separates verified customer identity from source-search credentials. Use the JWT from the quickstart for destination operations. Use a Typesense key only as temporary source credentials when a supported import path asks for it.

A Typesense collection schema is not a fjcloud settings payload. Create the destination explicitly, preserve stable document IDs as `objectID`, and translate field, facet, filter, sort, ranking, synonym, and curation behavior by intent.

The runnable fjcloud curl patterns for create, batch, search, get, delete, synonym, and rule operations remain in [Migrating from Algolia](./migrating_from_algolia.md). Those examples target fjcloud routes and remain useful for validating a Typesense migration.

## Data migration with the console

[Open the migration console](/console/migrate) to inspect current availability and plan the shared workflow:

1. The console first presents destination provider and region eligibility, then source-provider selection. Availability still depends on the selected destination and migration mode.
2. Typesense discovery and create requests use the exact wire fields `node` and `apiKey`; `host` is not an accepted alias. Use a temporary, source-restricted read key.
3. Discovery returns neutral collection summaries before a retained import job is created. Follow the capability result shown for the selected destination rather than inferring every migration operation from source selection alone.

The retained job-detail route shape is shared across supported providers and preserves `source_provider` in links such as `/console/migrate/[jobId]?source_provider=typesense`. Use the manual fjcloud operations above to validate the translated destination behavior before cutover.

## Typesense import availability

`SourceImportProvider::has_adapter` returns `true` for `typesense`. The discovery and create handlers select Typesense-specific request DTOs, so both operations require `node` plus `apiKey` rather than an Algolia-shaped body or a generic `host` field.

Production endpoints must be HTTPS Typesense Cloud hosts under `.typesense.net`. Self-hosted and loopback sources are refused outside the engine's debug-only local proof mode; fjcloud does not own an allowlist or bypass for that policy.

The overall create flow still fails closed unless migration availability and destination eligibility are enabled. A visible source-provider option alone is not evidence that every migration capability is enabled for the selected destination.

## Unsupported concepts

Translate source behavior deliberately even when using the hosted import adapter:

- Recreate collection field types, facets, filters, sort fields, and ranking behavior through fjcloud settings. Test representative filters, facets, sorting, and ranking before cutover.
- Current Typesense synonym sets can be shared across collections, while fjcloud synonym entries are index-scoped. Create equivalent fjcloud entries in every destination index that needs them.
- Rebuild Typesense curations or overrides with fjcloud rules. Verify pinned, hidden, promoted, and demoted result behavior with a known query set rather than forwarding the source payload.
- Treat joins, aliases, and other collection-level behavior outside documents, settings, synonyms, and curations as a separate application migration. Rebuild the required behavior and validate it before routing production traffic.

## Source evidence

- Typesense terminology: [Typesense API reference](https://typesense.org/docs/latest/api/) and [collection concepts](https://typesense.org/docs/30.0/api/collections.html).
- Account, pricing, and shared error owners: [Customer Quickstart](./customer-quickstart.md), [Pricing FAQ](./pricing-faq.md), and [Error Reference](./error-reference.md).
- Shared fjcloud operation examples: [Migrating from Algolia](./migrating_from_algolia.md).
- Adapter boundary owner: `infra/api/src/models/algolia_import_job/provider.rs` (`SourceImportProvider::has_adapter`).
- Hosted-payload owners: `infra/api/src/routes/migration/source.rs` (`ListTypesenseIndexesRequest`, `list_source_indexes`) and `infra/api/src/routes/migration/jobs.rs` (`CreateTypesenseImportJobRequest`, `create_import_job`).
- Producer endpoint-policy evidence: `docs/audits/migration-discovery/20260803T212302Z_neutral_discovery_consumer/evidence.md`.
- fjcloud route owners: `infra/api/src/router/route_assembly.rs` (`add_index_lifecycle_and_replica_routes`, `add_index_configuration_routes`), plus the corresponding handlers under `infra/api/src/routes/indexes/`.
