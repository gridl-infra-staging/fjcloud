# Migrating from Meilisearch

This guide maps common Meilisearch index, document, search, settings, and synonym operations to fjcloud JWT control-plane routes. It also states the current automated-import boundary: Meilisearch is a recognized source identity in the console and API, but fjcloud does not yet have a Meilisearch source adapter.

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

The runnable fjcloud curl patterns for create, batch, search, get, delete, synonym, and rule operations remain in [Migrating from Algolia](./migrating_from_algolia.md). Those examples target fjcloud routes and are reusable even when Meilisearch automated import is unavailable.

## Data migration with the console

[Open the migration console](/console/migrate) only to inspect the current availability and plan the shared workflow:

1. The console first presents destination provider and region eligibility, then source-provider selection. Destination eligibility does not imply that a source adapter exists.
2. Selecting Meilisearch mounts the shared hosted-search credential panel with **Meilisearch host URL** and **Meilisearch API key** fields. Its guidance calls for an HTTPS host and a temporary, source-restricted read key.
3. Stop at that boundary today. The console recognizes the Meilisearch identity and credential shape, but it cannot discover or preview indexes, create an import report or job, import data, cancel, or resume without a source adapter.

The retained job-detail route shape is shared across supported providers and preserves `source_provider` in links such as `/console/migrate/[jobId]?source_provider=meilisearch`. It does not make a Meilisearch job available before an adapter can create one. Use the manual fjcloud operations above while planning and validating your translation.

## Meilisearch import availability

`SourceImportProvider` contains `meilisearch`, while `SourceImportProvider::has_adapter` returns `false` for it. `validate_source_provider` therefore refuses Meilisearch requests that reach the handler with `source_provider_unsupported` before credential handling, repository access, or adapter work.

Do not automate against a specific discovery/create error envelope yet. Those POST handlers still deserialize Algolia-shaped request DTOs, so a real hosted-search `{host, apiKey}` body can fail JSON extraction before `validate_source_provider` runs. The customer contract is the adapter boundary: discovery, preview, report/job creation, import, cancel, and resume are not available for Meilisearch today.

`/console/migrate` itself is reachable, but the overall create flow also fails closed unless migration availability is enabled. Neither a visible source-provider option nor an eligible destination is evidence of end-to-end Meilisearch support.

## Unsupported concepts

Automated conversion is not available, so translate source behavior deliberately:

- Recreate filterable/searchable attributes, typo tolerance, ranking rules, and other search settings through fjcloud index settings. Test filters, sorting, typo behavior, and representative ranking queries before cutover.
- Recreate Meilisearch synonyms with fjcloud synonym IDs through the synonyms API. Verify asymmetric or phrase behavior rather than assuming identical evaluation.
- If a ranking rule has no direct setting equivalent, express the business intent with fjcloud rules or application-side ordering and test it against a known query set.
- Plan cutover around a separately populated fjcloud index. Keep the Meilisearch source authoritative until document counts and representative searches pass.

## Source evidence

- Meilisearch terminology: [Meilisearch indexes and settings](https://www.meilisearch.com/docs/resources/internals/indexes) and [add or replace documents](https://www.meilisearch.com/docs/reference/api/documents/add-or-replace-documents).
- Account, pricing, and shared error owners: [Customer Quickstart](./customer-quickstart.md), [Pricing FAQ](./pricing-faq.md), and [Error Reference](./error-reference.md).
- Shared fjcloud operation examples: [Migrating from Algolia](./migrating_from_algolia.md).
- Source-provider and credential owners: `web/src/lib/api/types_algolia_migration.ts` (`SOURCE_PROVIDERS`), `web/src/lib/components/migration/MigrationSourceConnection.svelte`, and `web/src/lib/components/migration/MigrationHostedSearchConnection.svelte`.
- Adapter boundary owners: `infra/api/src/models/algolia_import_job/provider.rs` (`SourceImportProvider::has_adapter`) and `infra/api/src/routes/migration.rs` (`validate_source_provider`).
- Hosted-payload extraction owners: `infra/api/src/routes/migration/source.rs` (`ListAlgoliaIndexesRequest`, `list_source_indexes`) and `infra/api/src/routes/migration/jobs.rs` (`CreateAlgoliaImportJobRequest`, `create_import_job`).
- fjcloud route owners: `infra/api/src/router/route_assembly.rs` (`add_index_lifecycle_and_replica_routes`, `add_index_configuration_routes`), plus the corresponding handlers under `infra/api/src/routes/indexes/`.
