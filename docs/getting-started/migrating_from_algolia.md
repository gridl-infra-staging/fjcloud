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

## Algolia import availability

Customer-facing Algolia discovery and import are temporarily unavailable while the importer is replaced. `/console/migrate` remains reachable for authenticated customers, but it is a read-only explanation page and does not collect Algolia credentials or start imports.

The only customer migration route currently exposed is the authenticated availability read path:

```bash
curl -X GET "$API_BASE_URL/migration/algolia/availability" \
  -H "Authorization: Bearer $AUTH_TOKEN"
```

The retired `POST /migration/algolia/list-indexes` and `POST /migration/algolia/migrate` routes are not available customer functionality. Do not build new customer flows against them.

## Source evidence

- Mapping source of truth: [Algolia to fjcloud Route Mapping and Gaps](../runbooks/evidence/algolia_api_mapping/20260603T180703Z/gaps.md).
- Account prerequisite owner: [Customer Quickstart](./customer-quickstart.md).
- Route assembly owners: `infra/api/src/router/route_assembly.rs` (`add_index_lifecycle_and_replica_routes`, `add_index_configuration_routes`, `add_migration_routes`).
- Index route owners: `infra/api/src/routes/indexes/lifecycle.rs` (`create_index`, `list_indexes`), `infra/api/src/routes/indexes/documents.rs` (`batch_documents`, `get_document`, `delete_document`), `infra/api/src/routes/indexes/search.rs` (`test_search`), `infra/api/src/routes/indexes/synonyms.rs` (`save_synonym`), and `infra/api/src/routes/indexes/rules.rs` (`save_rule`).
- Migration availability owner: `infra/api/src/routes/migration.rs` (`algolia_availability`).
- Payload-shape owners: `infra/api/tests/integration/indexes_test.rs` for batch, get/delete, synonym, and rule examples, plus `infra/api/tests/integration/migration_routes_test.rs` for migration availability and retired POST-route rejection.
