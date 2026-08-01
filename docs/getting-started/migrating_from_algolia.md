# Migrating from Algolia

This guide maps common Algolia record, search, synonym, and rule operations to the fjcloud JWT control-plane routes. It is not a second source of truth for route behavior; every route claim below is anchored to the Stage 1 mapping evidence and the route owners listed in [Source evidence](#source-evidence).

## Before you start

Complete signup, email verification, and JWT setup in [Customer Quickstart](./customer-quickstart.md). That guide owns the account-creation and verification curls; this guide starts after you have a verified account and an `AUTH_TOKEN`.

Use the same environment variable names as the quickstart so examples stay aligned:

```bash
export API_BASE_URL="https://api.flapjack.foo"
export AUTH_TOKEN="<jwt-from-registration-or-login>"
export INDEX_NAME="products"
export INDEX_REGION="us-east-1"
export OBJECT_ID_PRIMARY="obj-1"
export OBJECT_ID_SECONDARY="obj-2"
export SYNONYM_ID="laptop-syn"
export RULE_ID="boost-shoes"
```

All executable snippets use fjcloud routes and `Authorization: Bearer $AUTH_TOKEN`. They do not use Algolia application/API-key headers.

## Operation mapping

| Algolia operation | fjcloud route and owner                                               | Parity seam                                                                                                             |
| ----------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Create index      | `POST /indexes` -> `create_index`                                     | fjcloud requires explicit index creation; Algolia can create an index implicitly on first write.                        |
| Push records      | `POST /indexes/{name}/batch` -> `batch_documents` with `addObject`    | fjcloud uses a JWT control-plane path and a `requests[]` envelope.                                                      |
| Search            | `POST /indexes/{name}/search` -> `test_search`                        | fjcloud uses `/search`; Algolia REST uses `/query` under its index path.                                                |
| Get object        | `GET /indexes/{name}/objects/{object_id}` -> `get_document`           | fjcloud includes an `/objects/` path segment; Algolia puts the object ID directly under the index path.                 |
| Update record     | `POST /indexes/{name}/batch` -> `batch_documents` with `updateObject` | fjcloud currently updates through batch; there is no dedicated partial-update object route in the cited route assembly. |
| Delete record     | `DELETE /indexes/{name}/objects/{object_id}` -> `delete_document`     | fjcloud single-record delete uses the `/objects/` path segment.                                                         |
| Save synonym      | `PUT /indexes/{name}/synonyms/{object_id}` -> `save_synonym`          | Operation type is close, but fjcloud uses JWT auth and the fjcloud control-plane path.                                  |
| Save rule         | `PUT /indexes/{name}/rules/{object_id}` -> `save_rule`                | Operation type is close, but fjcloud uses JWT auth and the fjcloud control-plane path.                                  |

## fjcloud workflow differences

fjcloud separates account verification from index operations. Use the quickstart for registration and email verification, then use the JWT-backed routes here for index work.

Index creation is explicit. `POST /indexes` creates a named index in a requested region, and `GET /indexes` lists indexes for the authenticated customer. Those route claims are owned by `infra/api/src/routes/indexes/lifecycle.rs::{create_index,list_indexes}`.

Authentication differs from Algolia. fjcloud customer operations use `Authorization: Bearer $AUTH_TOKEN`; they do not use Algolia application/API-key request headers.

Record updates go through the batch route. Use `updateObject` inside `requests[]` for updates instead of looking for a dedicated partial-update object endpoint.

<!-- validate_customer_quickstart: migration_indexes_list -->

```bash
curl -X GET "$API_BASE_URL/indexes" \
  -H "Authorization: Bearer $AUTH_TOKEN"
```

<!-- validate_customer_quickstart: migration_indexes_create -->

```bash
curl -X POST "$API_BASE_URL/indexes" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$INDEX_NAME\",\"region\":\"$INDEX_REGION\"}"
```

<!-- validate_customer_quickstart: migration_indexes_batch_add_object -->

```bash
curl -X POST "$API_BASE_URL/indexes/$INDEX_NAME/batch" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "requests": [
      {"action": "addObject", "body": {"objectID": "'"$OBJECT_ID_PRIMARY"'", "title": "First"}},
      {"action": "addObject", "body": {"objectID": "'"$OBJECT_ID_SECONDARY"'", "title": "Second"}}
    ]
  }'
```

<!-- validate_customer_quickstart: migration_indexes_search -->

```bash
curl -X POST "$API_BASE_URL/indexes/$INDEX_NAME/search" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"query":"First"}'
```

<!-- validate_customer_quickstart: migration_indexes_get_object -->

```bash
curl -X GET "$API_BASE_URL/indexes/$INDEX_NAME/objects/$OBJECT_ID_PRIMARY" \
  -H "Authorization: Bearer $AUTH_TOKEN"
```

<!-- validate_customer_quickstart: migration_indexes_batch_update_object -->

```bash
curl -X POST "$API_BASE_URL/indexes/$INDEX_NAME/batch" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "requests": [
      {"action": "updateObject", "body": {"objectID": "'"$OBJECT_ID_PRIMARY"'", "title": "First updated"}}
    ]
  }'
```

<!-- validate_customer_quickstart: migration_indexes_delete_object -->

```bash
curl -X DELETE "$API_BASE_URL/indexes/$INDEX_NAME/objects/$OBJECT_ID_SECONDARY" \
  -H "Authorization: Bearer $AUTH_TOKEN"
```

<!-- validate_customer_quickstart: migration_indexes_save_synonym -->

```bash
curl -X PUT "$API_BASE_URL/indexes/$INDEX_NAME/synonyms/$SYNONYM_ID" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "objectID": "'"$SYNONYM_ID"'",
    "type": "synonym",
    "synonyms": ["laptop", "notebook"]
  }'
```

<!-- validate_customer_quickstart: migration_indexes_save_rule -->

```bash
curl -X PUT "$API_BASE_URL/indexes/$INDEX_NAME/rules/$RULE_ID" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "objectID": "'"$RULE_ID"'",
    "conditions": [{"pattern": "shoes", "anchoring": "contains"}],
    "consequence": {"promote": [{"objectID": "'"$OBJECT_ID_PRIMARY"'", "position": 0}]},
    "description": "Boost shoes to top"
  }'
```

## Data migration with the console

The examples above are the manual fjcloud operation path. When migration availability reports that imports can start, [open the migration console](/console/migrate) to move one Algolia primary index through the retained-job workflow:

1. Choose whether to create a destination index or, when the advertised `replace` capability allows it, select an existing destination. Confirm the destination provider, region, and index name before connecting to Algolia.
2. Select Algolia as the source provider. Enter the Algolia Application ID and a temporary API key with `listIndexes`, `browse`, and `settings`; add `seeUnretrievableAttributes` only when the source uses unretrievable attributes.
3. Connect and preview the source indexes. Select a primary index. Replica rows cannot be selected directly; importing a primary reconstructs supported replicas as fjcloud virtual replicas.
4. Review the source, destination, scope, and admission result, then select **Start import**. The scope covers primary records, settings, synonyms, and rules. A failed replica reconstruction leaves the imported primary in place.
5. Follow the retained job-detail link for status, imported-versus-expected document counts, settings and synonym/rule summaries, warnings, and the final publication result. You can leave or reload the detail page without stopping a running import.
6. After a successful import, use **View index** and **Test search** from the detail page. Compare representative searches, document counts, settings, synonyms, and rules with the source before moving application traffic.
7. If **Cancel import** is visible, the availability response and current job state allow cancellation. Cancel from the detail page and wait for its retained status to become terminal.
8. If an import fails or is interrupted, use **Start a new import**. Do not plan around resume: customer-advertised capabilities force `resume` to `false` even though internal resume route code exists.

Delete the temporary API key in Algolia after the import completes or fails. fjcloud clears its in-memory credential copy but cannot revoke the key at Algolia.

For pricing, account setup, and shared error-envelope behavior, use [Pricing FAQ](./pricing-faq.md), [Customer Quickstart](./customer-quickstart.md), and [Error Reference](./error-reference.md) instead of duplicating those contracts here.

## Algolia import availability

`/console/migrate` is reachable for authenticated customers, but the create flow fails closed. `FJCLOUD_ALGOLIA_MIGRATION_ENABLED` defaults to `false`; when it is not enabled, the page shows the unavailable explanation and does not mount credential or import controls. Enabling the flag is necessary, but the availability response remains the final authority because `current_migration_availability` also intersects route and engine capabilities.

Check the authenticated availability path before starting an import:

```bash
curl -X GET "$API_BASE_URL/migration/algolia/availability" \
  -H "Authorization: Bearer $AUTH_TOKEN"
```

Do not infer availability for any deployed environment from this guide. Treat `available: false` and any absent or false capability as unavailable. In particular, start a new import after a failed attempt instead of calling the mounted resume route while the response advertises `resume: false`.

## Unsupported concepts

The import scope is intentionally bounded to primary records, settings, synonyms, rules, and supported replica reconstruction. Treat Algolia resources outside that list as not included in the import contract.

- Recreate fjcloud API keys after verifying the destination; never copy an Algolia key into fjcloud application authentication.
- Rebuild analytics integrations and experiments against the destination after cutover instead of expecting historical state to move with the index.
- Review settings and rule behavior with representative searches. When an Algolia option has no direct fjcloud payload equivalent, express the intent through fjcloud settings, synonyms, or rules and test the result before routing production traffic.

## Source evidence

- Mapping source of truth: [Algolia to fjcloud Route Mapping and Gaps](../runbooks/evidence/algolia_api_mapping/20260603T180703Z/gaps.md).
- Account prerequisite owner: [Customer Quickstart](./customer-quickstart.md).
- Route assembly owners: `infra/api/src/router/route_assembly.rs` (`add_index_lifecycle_and_replica_routes`, `add_index_configuration_routes`, `add_migration_routes`).
- Index route owners: `infra/api/src/routes/indexes/lifecycle.rs` (`create_index`, `list_indexes`), `infra/api/src/routes/indexes/documents.rs` (`batch_documents`, `get_document`, `delete_document`), `infra/api/src/routes/indexes/search.rs` (`test_search`), `infra/api/src/routes/indexes/synonyms.rs` (`save_synonym`), and `infra/api/src/routes/indexes/rules.rs` (`save_rule`).
- Migration availability owners: `infra/api/src/config.rs` (`FJCLOUD_ALGOLIA_MIGRATION_ENABLED`) and `infra/api/src/routes/migration.rs` (`current_migration_availability`, `compute_availability`).
- Console contract and credential owners: `docs/screen_specs/migrate.md`, `web/src/lib/components/migration/MigrationAlgoliaConnection.svelte`, and `web/src/lib/components/migration/MigrationSourceConnection.svelte`.
- Review and retained-detail owners: `web/src/lib/components/migration/MigrationCreateReview.svelte` and `web/src/lib/components/migration/ImportJobDetail.svelte`.
- Migration handler owners: `infra/api/src/routes/migration/source.rs`, `infra/api/src/routes/migration/eligibility.rs`, `infra/api/src/routes/migration/jobs.rs`, and `infra/api/src/routes/migration/retained_jobs.rs`.
- Payload-shape owners: `infra/api/tests/integration/indexes_test.rs` for batch, get/delete, synonym, and rule examples, plus `infra/api/tests/integration/migration_routes_test.rs` for migration availability and job lifecycle coverage.
