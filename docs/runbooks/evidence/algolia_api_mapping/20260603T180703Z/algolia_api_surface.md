# Algolia API Surface Evidence

UTC evidence directory: `docs/runbooks/evidence/algolia_api_mapping/20260603T180703Z`

Discovery started from `https://algolia.com/llms.txt`.

Fetch log:

| Source | UTC fetched | HTTP result | Final URL / observation |
| --- | --- | --- | --- |
| `https://algolia.com/llms.txt` | 2026-06-03T18:08:36Z | 200 | `https://www.algolia.com/llms.txt`; points to `https://www.algolia.com/doc/llms.txt` for the documentation index. |
| `https://www.algolia.com/doc/llms.txt` | 2026-06-03T18:08:45Z | 200 | Operation slugs were not directly discoverable by exact slug search; used official REST and SDK URLs below. |
| `https://www.algolia.com/doc/api-client/methods/indexing/` | 2026-06-03T18:09:15Z | 200 after 2 redirects | Final URL `https://www.algolia.com/doc/libraries/sdk/methods/search`. |
| `https://www.algolia.com/doc/libraries/sdk/methods/search.md` | 2026-06-03T18:13:49Z | 200 | Markdown source for indexing overview. |
| `https://support.algolia.com/hc/en-us/articles/15009736834577-Can-I-create-an-empty-index-from-the-API` | 2026-06-03T18:09:15Z | 403 | Body was a Cloudflare "Just a moment..." challenge; support-article content not used for shape claims. |
| `https://www.algolia.com/doc/api-reference/api-methods/search-single-index` | 2026-06-03T18:09:15Z | 404 | Old slug no longer resolves. |
| `https://www.algolia.com/doc/api-reference/api-methods/get-object` | 2026-06-03T18:09:15Z | 404 | Old slug no longer resolves. |
| `https://www.algolia.com/doc/api-reference/api-methods/partial-update-object` | 2026-06-03T18:09:15Z | 404 | Old slug no longer resolves. |
| `https://www.algolia.com/doc/api-reference/api-methods/delete-object` | 2026-06-03T18:09:15Z | 404 | Old slug no longer resolves. |

## Create index

Official source: `https://www.algolia.com/doc/libraries/sdk/methods/search.md`, fetched 2026-06-03T18:13:49Z, HTTP 200.

Evidence:

- The indexing overview says Algolia automatically creates a new index when records, rules, synonyms, or settings are added to an index that does not yet exist; it also says explicit index creation is unnecessary.
- The support article named in the checklist was not reachable from this environment: `curl -L https://support.algolia.com/hc/en-us/articles/15009736834577-Can-I-create-an-empty-index-from-the-API` returned HTTP 403 with a Cloudflare challenge body at 2026-06-03T18:09:15Z.

Surface shape:

- No standalone create-index REST endpoint was established from reachable official sources.
- Create-on-write behavior is the official nuance to carry forward.

Open questions:

- Whether the blocked support article still states the same create-empty-index limitation; current run could not verify it directly.

## Push records

Official source: `https://www.algolia.com/doc/libraries/sdk/methods/search/save-objects.md`, fetched 2026-06-03T18:13:17Z, HTTP 200.

Fetch observations:

- `https://www.algolia.com/doc/api-reference/api-methods/save-objects/` fetched at 2026-06-03T18:10:23Z returned HTTP 200 after 2 redirects to `https://www.algolia.com/doc/libraries/sdk/methods/search/save-objects`.
- The first markdown attempt timed out: `curl --max-time 20 ... save-objects.md` returned `curl: (28) Operation timed out after 20004 milliseconds with 0 bytes received` and HTTP `000` at 2026-06-03T18:11:53Z. Retried with HTTP/1.1, user agent, and 60 seconds; result was HTTP 200.

Surface shape:

- Helper operation: save records / `saveObjects`.
- Underlying REST operation: batch write on one index.
- Batch action: `addObject`.
- Request body shape: list/array of record objects, each usually carrying `objectID`; SDK helper sends records in batches of 1,000 by default.
- Response envelope notes: helper returns task-oriented batch response; older/current docs expose `taskID` and object ID list semantics for saved records.

Open questions:

- None for the Stage 1 route mapping.

## Search

Official source: `https://www.algolia.com/doc/rest-api/search/search-single-index.md`, fetched 2026-06-03T18:11:53Z, HTTP 200.

Fetch observations:

- `https://www.algolia.com/doc/rest-api/search/search-single-index` fetched at 2026-06-03T18:10:23Z returned HTTP 200 directly.
- The older `api-reference/api-methods/search-single-index` URL returned HTTP 404.

Surface shape:

- Method: `POST`.
- Path shape: `/1/indexes/{indexName}/query`.
- Request body shape: search parameters as `params` URL-encoded query string or as a JSON object.
- Response envelope notes: `hits` is required in the 200 response, with pagination and query metadata such as `nbHits`, `page`, `params`, and `query`.

Open questions:

- None for the Stage 1 route mapping.

## Get object

Official source: `https://www.algolia.com/doc/rest-api/search/get-object.md`, fetched 2026-06-03T18:11:53Z, HTTP 200.

Fetch observations:

- First direct REST HTML fetch at 2026-06-03T18:10:23Z timed out: `curl: (28) Operation timed out after 30006 milliseconds with 0 bytes received`, HTTP `000`.
- Retry with `--http1.1`, user agent, and 45 second timeout at 2026-06-03T18:11:30Z returned HTTP 200 for both `https://www.algolia.com/doc/libraries/sdk/methods/search/get-object` and `https://www.algolia.com/doc/rest-api/search/get-object`.
- The older `api-reference/api-methods/get-object` URL returned HTTP 404.

Surface shape:

- Method: `GET`.
- Path shape: `/1/indexes/{indexName}/{objectID}`.
- Request body shape: none; optional query parameter `attributesToRetrieve`.
- Response envelope notes: response is the requested record; `objectID` is always retrieved.

Open questions:

- None for the Stage 1 route mapping.

## Update record

Official sources:

- `https://www.algolia.com/doc/rest-api/search/partial-update-object.md`, fetched 2026-06-03T18:11:53Z, HTTP 200.
- `https://www.algolia.com/doc/libraries/sdk/methods/search/partial-update-objects.md`, fetched 2026-06-03T18:13:17Z, HTTP 200.

Fetch observations:

- `https://www.algolia.com/doc/rest-api/search/partial-update-object` fetched at 2026-06-03T18:10:23Z returned HTTP 200 directly.
- `https://www.algolia.com/doc/api-reference/api-methods/partial-update-objects/` fetched at 2026-06-03T18:10:23Z returned HTTP 200 after 2 redirects to `https://www.algolia.com/doc/libraries/sdk/methods/search/partial-update-objects`.
- The first SDK markdown attempt timed out: `curl --max-time 20 ... partial-update-objects.md` returned HTTP `000`; retry returned HTTP 200.
- The older singular `api-reference/api-methods/partial-update-object` URL returned HTTP 404.

Surface shape:

- Single-record method: `POST`.
- Single-record path shape: `/1/indexes/{indexName}/{objectID}/partial`.
- Single-record request body shape: first-level attributes to update, optionally with operations such as increment/decrement/add/remove; query parameter `createIfNotExists` controls creation.
- Single-record response envelope notes: `taskID`, `updatedAt`, and `objectID`.
- Multi-record helper: builds a batch request using `partialUpdateObject` or `partialUpdateObjectNoCreate`, depending on `createIfNotExists`; sends records in batches up to 1,000.

Open questions:

- None for the Stage 1 route mapping.

## Delete record

Official sources:

- `https://www.algolia.com/doc/rest-api/search/delete-object.md`, fetched 2026-06-03T18:11:53Z, HTTP 200.
- `https://www.algolia.com/doc/libraries/sdk/methods/search/delete-objects.md`, fetched 2026-06-03T18:11:53Z, HTTP 200.

Fetch observations:

- `https://www.algolia.com/doc/rest-api/search/delete-object` fetched at 2026-06-03T18:10:23Z returned HTTP 200 directly.
- `https://www.algolia.com/doc/api-reference/api-methods/delete-objects/` fetched at 2026-06-03T18:10:23Z returned HTTP 200 after 2 redirects to `https://www.algolia.com/doc/libraries/sdk/methods/search/delete-objects`.
- The older singular `api-reference/api-methods/delete-object` URL returned HTTP 404.

Surface shape:

- Single-record method: `DELETE`.
- Single-record path shape: `/1/indexes/{indexName}/{objectID}`.
- Request body shape: none.
- Response envelope notes: `taskID` and `deletedAt`.
- Multi-record helper: constructs a batch request with the `deleteObject` action and sends object IDs in batches of 1,000.

Open questions:

- None for the Stage 1 route mapping.

## Save synonym

Official source: `https://www.algolia.com/doc/rest-api/search/save-synonym.md`, fetched 2026-06-03T18:11:53Z, HTTP 200.

Fetch observations:

- `https://www.algolia.com/doc/rest-api/search/save-synonym` fetched at 2026-06-03T18:10:23Z returned HTTP 200 directly.
- `https://www.algolia.com/doc/api-reference/api-methods/save-synonym` fetched at 2026-06-03T18:09:15Z returned HTTP 200 after 1 redirect to `https://www.algolia.com/doc/libraries/sdk/methods/search/save-synonym`.

Surface shape:

- Method: `PUT`.
- Path shape: `/1/indexes/{indexName}/synonyms/{objectID}`.
- Request body shape: synonym object with `objectID`, synonym `type`, and type-specific fields such as `synonyms`, `input`, `corrections`, `placeholder`, or `replacements`; optional `forwardToReplicas` query parameter.
- Response envelope notes: `taskID` and `updatedAt`.

Open questions:

- None for the Stage 1 route mapping.

## Save rule

Official source: `https://www.algolia.com/doc/rest-api/search/save-rule.md`, fetched 2026-06-03T18:11:53Z, HTTP 200.

Fetch observations:

- `https://www.algolia.com/doc/rest-api/search/save-rule` fetched at 2026-06-03T18:10:23Z returned HTTP 200 directly.
- `https://www.algolia.com/doc/api-reference/api-methods/save-rule` fetched at 2026-06-03T18:09:15Z returned HTTP 200 after 1 redirect to `https://www.algolia.com/doc/libraries/sdk/methods/search/save-rule`.

Surface shape:

- Method: `PUT`.
- Path shape: `/1/indexes/{indexName}/rules/{objectID}`.
- Request body shape: rule object with `objectID`, `conditions`, and `consequence`; optional fields include `description`, `enabled`, `validity`, `tags`, and `scope`; optional `forwardToReplicas` query parameter.
- Response envelope notes: `taskID` and `updatedAt`.

Open questions:

- None for the Stage 1 route mapping.
