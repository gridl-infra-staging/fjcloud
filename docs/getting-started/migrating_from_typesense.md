# Migrating from Typesense

This guide maps common Typesense collection, document, search, synonym, and curation operations to fjcloud JWT control-plane routes. It also states the current automated-import boundary: Typesense is a recognized source identity in the console and API, but fjcloud does not yet have a Typesense source adapter.

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

The runnable fjcloud curl patterns for create, batch, search, get, delete, synonym, and rule operations remain in [Migrating from Algolia](./migrating_from_algolia.md). Those examples target fjcloud routes and are reusable even when Typesense automated import is unavailable.

## Data migration with the console

[Open the migration console](/console/migrate) only to inspect the current availability and plan the shared workflow:

1. The console first presents destination provider and region eligibility, then source-provider selection. Destination eligibility does not imply that a source adapter exists.
2. Selecting Typesense mounts the shared hosted-search credential panel with **Typesense host URL** and **Typesense API key** fields. Its guidance calls for an HTTPS host and a temporary, source-restricted read key.
3. Stop at that boundary today. The console recognizes the Typesense identity and credential shape, but it cannot discover or preview collections, create an import report or job, import data, cancel, or resume without a source adapter.

The retained job-detail route shape is shared across supported providers and preserves `source_provider` in links such as `/console/migrate/[jobId]?source_provider=typesense`. It does not make a Typesense job available before an adapter can create one. Use the manual fjcloud operations above while planning and validating your translation.

## Typesense import availability

`SourceImportProvider` contains `typesense`, while `SourceImportProvider::has_adapter` returns `false` for it. `validate_source_provider` therefore refuses Typesense requests that reach the handler with `source_provider_unsupported` before credential handling, repository access, or adapter work.

Do not automate against a specific discovery/create error envelope yet. Those POST handlers still deserialize Algolia-shaped request DTOs, so a real hosted-search `{host, apiKey}` body can fail JSON extraction before `validate_source_provider` runs. The customer contract is the adapter boundary: discovery, preview, report/job creation, import, cancel, and resume are not available for Typesense today.

`/console/migrate` itself is reachable, but the overall create flow also fails closed unless migration availability is enabled. Neither a visible source-provider option nor an eligible destination is evidence of end-to-end Typesense support.

## Unsupported concepts

Automated conversion is not available, so translate source behavior deliberately:

- Recreate collection field types, facets, filters, sort fields, and ranking behavior through fjcloud settings. Test representative filters, facets, sorting, and ranking before cutover.
- Current Typesense synonym sets can be shared across collections, while fjcloud synonym entries are index-scoped. Create equivalent fjcloud entries in every destination index that needs them.
- Rebuild Typesense curations or overrides with fjcloud rules. Verify pinned, hidden, promoted, and demoted result behavior with a known query set rather than forwarding the source payload.
- Treat joins, aliases, and other collection-level behavior outside documents, settings, synonyms, and curations as a separate application migration. Rebuild the required behavior and validate it before routing production traffic.

## Source evidence

- Typesense terminology: [Typesense API reference](https://typesense.org/docs/latest/api/) and [collection concepts](https://typesense.org/docs/30.0/api/collections.html).
- Account, pricing, and shared error owners: [Customer Quickstart](./customer-quickstart.md), [Pricing FAQ](./pricing-faq.md), and [Error Reference](./error-reference.md).
- Shared fjcloud operation examples: [Migrating from Algolia](./migrating_from_algolia.md).
- Source-provider and credential owners: `web/src/lib/api/types_algolia_migration.ts` (`SOURCE_PROVIDERS`), `web/src/lib/components/migration/MigrationSourceConnection.svelte`, and `web/src/lib/components/migration/MigrationHostedSearchConnection.svelte`.
- Adapter boundary owners: `infra/api/src/models/algolia_import_job/provider.rs` (`SourceImportProvider::has_adapter`) and `infra/api/src/routes/migration.rs` (`validate_source_provider`).
- Hosted-payload extraction owners: `infra/api/src/routes/migration/source.rs` (`ListAlgoliaIndexesRequest`, `list_source_indexes`) and `infra/api/src/routes/migration/jobs.rs` (`CreateAlgoliaImportJobRequest`, `create_import_job`).
- fjcloud route owners: `infra/api/src/router/route_assembly.rs` (`add_index_lifecycle_and_replica_routes`, `add_index_configuration_routes`), plus the corresponding handlers under `infra/api/src/routes/indexes/`.
