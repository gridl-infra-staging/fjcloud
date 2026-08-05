# Migration preview live-engine evidence — 2026-08-01

## Purpose

Verify the fjcloud migration preview route against the running local Flapjack
engine, prove that preview does not mutate durable job state, and prove that
marked source credentials do not appear in the enumerated output surfaces.

The live success criterion did not pass. This bundle records the two exact
engine rejections and the smallest upstream unblocks. It does not claim that a
provider-wide source inventory is the same as the one-index preview scope.

## Runtime specimen

- UTC evidence stamp: `20260801T121856Z`
- Compose project: `fjcloud_jul30_pm_5_fjcloud_migration_preview_api_fjcloud_dev`
- API: `http://127.0.0.1:3011`; log: `.local/api.log`; PID owner:
  `.local/api.pid`
- Flapjack 1.0.10: `http://127.0.0.1:7700`; log:
  `.local/flapjack-default.log`; PID owner: `.local/flapjack-default.pid`
- Meilisearch: `http://127.0.0.1:7710`; compose health `healthy`
- Typesense: `http://127.0.0.1:8110`; compose health `healthy`
- Postgres: captured compose project on `localhost:55434`; compose health
  `healthy`
- Provider logs: `.local/source-provider-evidence/provider_container_logs.log`
- Provider redaction proof:
  `.local/source-provider-evidence/secret_redaction.json`

Startup command (the marked canary values are intentionally redacted from this
git-tracked artifact):

```bash
COMPOSE_PROFILES=source-providers \
LOCAL_MEILISEARCH_PORT=7710 LOCAL_TYPESENSE_PORT=8110 \
MEILI_MASTER_KEY='[MARKED_CANARY_REDACTED]' \
TYPESENSE_API_KEY='[MARKED_CANARY_REDACTED]' \
FLAPJACK_SINGLE_INSTANCE=1 bash scripts/local-dev-up.sh
```

The API was launched in the tracked shape owned by `scripts/local_demo.sh`:

```bash
bash -c 'set -a; source .env.local; set +a; \
DATABASE_URL="${DATABASE_URL/localhost:5432/localhost:55434}"; \
export DATABASE_URL; \
FLAPJACK_ADMIN_KEY="$(tr -d "\r\n" < .local/flapjack-data/.admin_key)"; \
export FLAPJACK_ADMIN_KEY; echo $$ > .local/api.pid; \
exec env API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=1 \
FJCLOUD_ALGOLIA_MIGRATION_ENABLED=true LISTEN_ADDR=127.0.0.1:3011 \
S3_LISTEN_ADDR=127.0.0.1:3012 scripts/api-dev.sh' \
>> .local/api.log 2>&1
```

Both `curl -fsS http://127.0.0.1:3011/health` and
`curl -fsS http://127.0.0.1:7700/health` exited 0. Creating and deleting the
disposable `stage3-node-key-warmup` index returned HTTP 201 and 204,
respectively, and initialized the API's process-local node key through the
existing public-index owner.

### Local Postgres collision found during setup

`.env.local.example` points `DATABASE_URL` to `localhost:5432`. A native host
Postgres already owned both loopback paths while the captured compose Postgres
also published 5432. Queries showed different server start timestamps and 41
versus 1 live VM rows. The compose service was republished on 55434, migrations
were applied there, and the API used that isolated port. This prevented a
successful but false proof against unrelated durable state.

Remediated in 53080f6a6: `scripts/local-dev-up.sh` now runs
`check_port_available "$DB_PORT" "postgres"` after stale-state cleanup,
`docker-compose.yml` publishes Postgres on loopback only, and
`.env.local.example` names `127.0.0.1`. The manual port workaround above is no
longer the only thing standing between a rerun and a foreign database; the
collision now stops startup with the holder diagnostics. Falsification specimen:
`scripts/tests/local_dev_up_test.sh::test_rejects_foreign_listener_on_database_url_port`
fails when the preflight is removed.

## Deterministic source seeds

The existing M3a owner seeded the fixtures under
`scripts/tests/fixtures/source-migration/` during stack startup. The live
known-answer command was:

```bash
MEILI_STATS=$(curl -fsS \
  --config .local/source-migration/credentials/meilisearch.curl.conf \
  http://127.0.0.1:7710/stats)
TYPESENSE_COLLECTIONS=$(curl -fsS \
  --config .local/source-migration/credentials/typesense.curl.conf \
  http://127.0.0.1:8110/collections)
jq -e '[.indexes | to_entries[] | .value.numberOfDocuments] | add == 6 \
  and (.indexes | length) == 3' <<<"$MEILI_STATS"
jq -e 'length == 2 and (map(.num_documents) | add) == 5' \
  <<<"$TYPESENSE_COLLECTIONS"
```

Exact observed provider inventories:

| Provider | Source owners | Indexes | Records |
| --- | --- | ---: | ---: |
| Meilisearch | `ambiguous_pk`, `configured_pk`, `inferred_pk` | 3 | 6 |
| Typesense | `fj_ts_migration_categories`, `fj_ts_migration_products` | 2 | 5 |

Per-index counts were Meilisearch `0 + 4 + 2` and Typesense `2 + 3`. The
requested preview specimens were therefore expected to return 1 index / 4
records for `configured_pk`, and 1 index / 3 records for
`fj_ts_migration_products`.

## Running-engine preview results

The Meilisearch acceptance assertion loaded its credential from the generated
curl config, posted through fjcloud, required HTTP 200, then required the exact
count and translation tuple:

```bash
TOKEN=$(jq -er '.token' .local/stage3_login.json)
MEILI_KEY=$(sed -n \
  's/^header = "Authorization: Bearer \(.*\)"$/\1/p' \
  .local/source-migration/credentials/meilisearch.curl.conf)
PAYLOAD=$(jq -cn --arg apiKey "$MEILI_KEY" \
  '{endpoint:"http://127.0.0.1:7710",apiKey:$apiKey,
    sourceIndex:"configured_pk",targetIndex:"stage3_preview_target"}')
HTTP_STATUS=$(curl -sS -o .local/stage3_meilisearch_preview.json \
  -w '%{http_code}' -X POST \
  http://127.0.0.1:3011/migration/meilisearch/preview \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data "$PAYLOAD")
test "$HTTP_STATUS" = 200
jq -e '.sourceCounts == {"indexes":1,"records":4} and
  any(.report.entries[]; .severity == "Warning" and
  .code == "MeilisearchSettingNotMigrated" and .resource == "Settings")' \
  .local/stage3_meilisearch_preview.json
```

Observed: exit 1, HTTP 400, body
`{"error":"{\"message\":\"Meilisearch Cloud endpoint is not allowed\",\"status\":400}"}`.
No `sourceCounts` or translation report was returned.

The equivalent Typesense assertion required HTTP 200 and
`sourceCounts == {"indexes":1,"records":3}`. Observed: exit 1, HTTP 400,
body
`{"error":"{\"message\":\"Source provider is not supported\",\"status\":400,\"code\":\"source_provider_unsupported\"}"}`.

### Upstream gap specifications

Meilisearch blocker: the engine's
`flapjack-http/src/handlers/migration/meilisearch_client.rs` rejects the
checklist-owned loopback harness before reading the seeded index. The smallest
unblock is an explicit local/test admission seam that preserves the cloud-host
restriction outside local/test mode, with a live loopback known-answer test
asserting 1 index / 4 records and the concrete setting warning. A proxy could
use an HTTPS Meilisearch Cloud instance, but its bias is material: it would not
exercise the repository-owned disposable fixture or its exact local data.
Conditional disposition: rerun this exact command only after that engine seam
lands; otherwise the live Meilisearch claim remains unproven.

Typesense blocker: the engine's
`flapjack-http/src/handlers/migration/preview_tests.rs` explicitly pins
Typesense preview to `source_provider_unsupported`, and the handler has no
Typesense preview reader. The smallest unblock is a Typesense preview reader,
provider-specific request schema, and live known-answer test for 1 collection /
3 records plus a concrete schema-translation entry. A proxy that calls
Typesense directly is biased because it bypasses both the engine translation
and fjcloud forwarding contracts. Conditional disposition: rerun the exact
fjcloud POST after the engine supports the provider; until then the Typesense
live claim remains unproven.

## Algolia proof method

Algolia is SaaS-only and has no local source container. Its separate method is
the generated engine contract fixture plus the fjcloud mock-engine integration
test. The fixture declares `/1/migrations/algolia/preview`, requires
`report` and `sourceCounts`, and types both count fields. The test
`algolia_preview_preserves_engine_report` supplies the deterministic engine
specimen `indexes=3`, `records=42` with exact Warning and HardRejection entries,
then asserts byte-equivalent JSON preservation and the provider-specific engine
URL. This is contract-backed deterministic forwarding evidence, not a claim
that Algolia participated in the two-provider local live proof.

## Statelessness and falsifiability

The isolated live Postgres query was:

```bash
COMPOSE_PROJECT_NAME=fjcloud_jul30_pm_5_fjcloud_migration_preview_api_fjcloud_dev \
LOCAL_DB_PORT=55434 docker compose exec -T postgres \
psql -U griddle -d fjcloud_dev -Atc \
  'SELECT COUNT(*) FROM algolia_import_jobs;'
```

Specimen result around one live request per available local provider:
`before=0 meilisearch_http=400 typesense_http=400 after=0`. Thus even the live
engine error paths wrote no durable import job. The success-path live proof
remains conditional on the upstream gaps above.

The guard's RED mutation used this exact SQL:

```sql
INSERT INTO algolia_import_jobs
  (id, customer_id, tenant_id, algolia_app_id, destination_kind,
   logical_target, destination_region, source_name, lifecycle_generation,
   idempotency_key, canonical_fingerprint, source_size_bytes, source_provider)
SELECT
  '00000000-0000-4000-8000-00000000c329', id,
  'stage3_mutation_target', 'STAGE3APP', 'create',
  'stage3_mutation_target', 'us-east-1', 'stage3_mutation_source', 1,
  'stage3-mutation-idempotency', 'stage3-mutation-fingerprint', 0, 'algolia'
FROM customers WHERE email = 'stage3-preview@example.com';
```

The identity assertion observed `before=0`, `after_insert=1`, and exited 1.
Cleanup was exact and restored the specimen:

```sql
DELETE FROM algolia_import_jobs
WHERE id = '00000000-0000-4000-8000-00000000c329';
```

Observed `after_delete=0`.

## Credential non-leakage denominator

Two distinct marked canary credentials were carried in the live Meilisearch
and Typesense requests. Their literal values are excluded from this artifact;
the generated credential input files are source material, not leak surfaces.
The exact output surfaces searched for both canaries were:

1. `.local/api.log`
2. every `.local/flapjack*.log` (one concrete file:
   `.local/flapjack-default.log`)
3. `.local/source-provider-evidence/provider_container_logs.log`
4. `.local/stage3_meilisearch_preview.json`
5. `.local/stage3_typesense_preview.json`
6. every live `algolia_import_jobs` row serialized with `row_to_json`
7. `.local/source-provider-evidence/secret_redaction.json`, whose five
   assertions were all `true`

The literal scan reported zero hits in every surface. A schema-owner grep for
`INSERT INTO|UPDATE ... algolia_import_jobs|DELETE FROM` in
`infra/api/src/routes/migration/preview.rs` returned zero matches, so there is
no second preview-path durable table owner to invent or sweep.

## Validation and teardown

Every validation command was checked and recorded through the required
`matt.validation_cache` owner. Commands used a Perl `alarm` wrapper solely to
provide the mandated bounded wall clock.

```text
/usr/bin/perl -e 'alarm 600; exec @ARGV' bash scripts/tests/local_source_providers_test.sh
RED: 95 passed, 2 failed
  stale contract expected unqualified provider ports
origin/main comparison: 98 passed, 0 failed
GREEN after applying origin/main's minimal test-only expectation:
  98 passed, 0 failed

/usr/bin/perl -e 'alarm 900; exec @ARGV' bash scripts/local-ci.sh --gate migration-test
PASS: pass=1 fail=0 skip=0 (2s)

/usr/bin/perl -e 'alarm 600; exec @ARGV' bash scripts/local-ci.sh --gate local-schema-drift-contract
PASS: pass=1 fail=0 skip=0 (45s)
```

The M3a repair changes only the semantic test owner: it requires
`127.0.0.1:${LOCAL_*_PORT}:<container-port>` and includes a negative mutation
that rejects a publicly bound provider port. Product behavior is unchanged.

Teardown command:

```bash
COMPOSE_PROJECT_NAME=fjcloud_jul30_pm_5_fjcloud_migration_preview_api_fjcloud_dev \
LOCAL_DB_PORT=55434 LOCAL_MEILISEARCH_PORT=7710 \
LOCAL_TYPESENSE_PORT=8110 COMPOSE_PROFILES=source-providers \
bash scripts/local-dev-down.sh --clean
```

It exited 0. The exact tracked Flapjack and API PIDs (`266`, `48530`) were no
longer alive, both PID files were absent, and `docker compose ps -q` for the
captured project returned empty. The final residue document was:

```json
{"containerPresent":false,"tempDirPresent":false,"rawLogsPresent":false,"credentialFilesPresent":false,"producer":"scripts/local-dev-down.sh","phase":"post-local-dev-down","teardownInvocationId":""}
```

---

## Addendum 2026-08-01 — upstream re-verification and contract closeout

An earlier triage of this stage deferred three findings on the premise that the
flapjack engine published no `/preview` route for any provider. That premise was
re-verified directly against the engine and is **false**. It must not be cited
again.

```bash
cd <flapjack-checkout> && git fetch origin
git show origin/main:engine/docs2/openapi.json | python3 -c "
import json,sys; d=json.load(sys.stdin)
for p in ['/1/migrations/algolia/preview','/1/migrations/meilisearch/preview','/1/migrations/typesense/preview']:
    print(p, 'PRESENT' if p in d['paths'] else 'ABSENT')"
```

Measured at flapjack `origin/main` = `bad37fec931b631398e03a71a1a46c83b2f6d5b1`:
all three paths print `PRESENT`.

### Typesense published request shape — determination

The engine publishes `/1/migrations/typesense/preview` with its request body as
`MigrateFromAlgoliaRequest` (required `apiKey`, `appId`, `sourceIndex`), not a
Typesense-shaped request. Determined against engine source, read-only:

- `engine/flapjack-http/src/handlers/migration/mod.rs:978` — the OpenAPI path is
  emitted by `define_source_migration_openapi_lifecycle!(Typesense, ...)` with
  `preview_request: MigrateFromAlgoliaRequest` and
  `preview_source_reader: algolia_source_reader`.
- `engine/flapjack-http/src/handlers/migration/mod.rs:1019` — the handler's only
  Typesense preview arm is
  `AsyncMigrationSourceProvider::Typesense => Err(source_provider_unsupported())`.
- `engine/flapjack-http/src/handlers/migration/mod.rs:268-270` —
  `supports_preview()` returns `matches!(self, Self::Algolia | Self::Meilisearch)`.

Verdict: **engine contract defect, not a real Typesense request shape.** The
published Algolia-shaped body is a macro placeholder on a path whose handler
rejects every request before the declared reader is reached. Typesense preview is
unimplemented upstream. No Typesense request schema was invented here to satisfy
a test; the fixture pins the Algolia-shaped body *as measured*, and this
determination records why that pin is a defect rather than a contract.

Cross-repo follow-up (consumed read-only from this lane; no flapjack edit made):
correct `/1/migrations/typesense/preview` so the published request schema and the
handler agree — either implement the Typesense preview reader with a
Typesense-shaped request, or stop publishing the path while `supports_preview()`
excludes the provider.

### Meilisearch loopback blocker — upstream owner confirmed

The Meilisearch gap spec above is confirmed by an upstream plan already committed
to flapjack `main` at `283d9fd5b`, file
`chats/icg/aug01_9am_1_meilisearch_preview_loopback_override.md`. It states the
preview path "currently feeds that endpoint into the production Meilisearch
Cloud-only validator and therefore returns HTTP 400 before reading the fixture",
and scopes exactly the seam this bundle named: a debug-only preview seam
accepting a literal loopback IP, owned by
`engine/flapjack-http/src/handlers/migration/meilisearch_client.rs`. That plan
also lists "implementing Typesense preview" as explicitly out of scope,
independently corroborating the determination above.

Both live-count gaps therefore remain **external-unreachable in flapjack_dev**,
with a named upstream owner file and a named upstream plan. The conditional
dispositions recorded earlier stand unchanged.

### Engine contract fixture regenerated through its owner

`infra/api/tests/fixtures/algolia_migration_engine_contract.json` was never
regenerated after preview request-field guards were added, leaving two committed
contract tests RED. Regenerated through the owner script — never hand-edited:

```bash
FLAPJACK_DEV_DIR=<flapjack-checkout> \
  bash scripts/update_algolia_migration_engine_contract.sh --update
# -> "Algolia migration engine contract updated"
```

Fixture delta: `pinned_engine_sha` `8c78f527b...` -> `bad37fec9...`, both
`openapi_artifacts` sha256 values repinned, and a new `preview.request_fields`
object. The engine OpenAPI diff between those two shas is a single `ReportCode`
description string, so no contract semantics moved.

The pinned Meilisearch preview request now matches the upstream schema exactly —
required `apiKey`, `endpoint`, `sourceIndex`; optional `overwrite`,
`targetIndex`. `endpoint` is the required upstream field that was previously
absent from the fixture and is the surface the live Meilisearch run was rejected
on.

```text
cd infra && cargo test -p api --test platform algolia_migration_engine_contract_test
PASS: 13 passed, 0 failed
```

### Preview error envelope normalized

Preview published `ErrorResponse` for 400/500/503 while its gating paths served
the migration family's coded `{error, code}` body, and `map_flapjack_error` let
engine 404/409 statuses escape on a route that publishes neither. Preview now
maps its transport failures onto the coded envelope in
`infra/api/src/routes/migration/preview.rs::map_preview_proxy_error`, matching
the sibling migration routes, and publishes `MigrationErrorResponse` for
400/500/503 (401 stays bare, since the shared auth layer owns it). Engine 4xx
collapses to a 400 whose `error` preserves the engine's verbatim diagnostic; the
`code` is deliberately coarse because fjcloud does not re-derive a finer
classification from an engine-owned body it does not define. The 500 path returns
`migration_preview_failed` and logs the underlying cause instead of returning it.

The guard `assert_preview_error_matches_published_schema` previously checked only
that each published required field was *present*, so it passed a served body
carrying the undocumented `code`. It now compares exact field sets. Falsifiability
probe — the published 400 schema was temporarily reverted to `ErrorResponse` and
the guard went RED on the real divergence:

```text
assertion `left == right` failed: served preview 400 Bad Request body fields
must match published ErrorResponse exactly:
{"code":"source_provider_unsupported","error":"source_provider_unsupported"}
  left: ["code", "error"]
 right: ["error"]
```

The probe edit was reverted immediately; the guard is falsifiable, not vacuous.

### Addendum validation

```text
cd infra && cargo test -p api --test platform --no-fail-fast openapi
PASS: 44 passed, 0 failed

cd infra && DATABASE_URL=<local> cargo test -p api --test platform \
  --no-fail-fast migration_routes_test::preview
PASS: 10 passed, 0 failed  (includes algolia_preview_does_not_create_import_job_row)

cd infra && DATABASE_URL=<local> cargo test -p api --test platform --no-fail-fast
PASS: 1604 passed, 0 failed, 9 ignored

cd infra && UPDATE_OPENAPI_ARTIFACT=1 cargo test -p api \
  openapi_spec_matches_committed_artifact -- --nocapture
PASS: docs/reference/openapi.json regenerated to match the served spec

bash scripts/local-ci.sh --gate migration-test               PASS (1s)
bash scripts/local-ci.sh --gate local-schema-drift-contract   PASS (45s)
bash scripts/local-ci.sh --gate check-sizes                   PASS (6s)
bash scripts/local-ci.sh --gate rust-lint                     PASS (244s)
cd infra && cargo fmt --check                                 PASS
```

Without `DATABASE_URL`, `algolia_preview_does_not_create_import_job_row` panics
with "DATABASE_URL must be set" by design; the `migration-test` gate covers SQL
migration application, not that Rust test, so the statelessness backstop must be
run with the variable set.

---

## Stage 4 console handoff — 2026-08-01

Written for the console lane. Everything below is readable without opening a
Rust file; each claim names the owner that enforces it. Measured at fjcloud
`batman/jul30_pm_5_fjcloud_migration_preview_api` HEAD `41a6a95dd`, against
fjcloud `origin/main` `a817f7892432`.

### Route shape — one path, three providers

```
POST /migration/{source_provider}/preview
```

`{source_provider}` takes exactly `algolia`, `meilisearch`, or `typesense`.
That is the published `SourceImportProvider` enum, and it equals the engine
contract fixture's `/provider_discriminator/values`.

There is **no** `/migration/algolia/preview` alias. Preview differs from the
stateful job routes here: `infra/api/src/router/route_assembly.rs` mounts the
legacy concrete `/migration/algolia/...` alias for availability, list-indexes,
destination-eligibility and jobs, but mounts preview **only** on the
parameterized segment. The console must build the concrete provider into the
path segment.

Auth is the same bearer JWT as the rest of the migration family. When
`FJCLOUD_ALGOLIA_MIGRATION_ENABLED` is off the route answers 503 before any
engine call.

Published responses (`docs/reference/openapi.json`):

| Status | Body schema | Meaning |
| --- | --- | --- |
| 200 | `MigrationPreviewResponse` | source counts + translation report |
| 400 | `MigrationErrorResponse` | unsupported provider, invalid request, or engine rejection |
| 401 | `ErrorResponse` | authentication required (shared auth layer owns this shape) |
| 500 | `MigrationErrorResponse` | `migration_preview_failed` |
| 503 | `MigrationErrorResponse` | preview unavailable / backend unavailable |

`MigrationErrorResponse` is `{error, code}`; `ErrorResponse` is `{error}`. Both
field sets are asserted exactly, so the console can switch on `code` for every
status except 401.

### Request body

`MigrationPreviewRequest` is an untagged union of two published shapes. Field
names are engine-pinned, so these are exactly what the engine requires:

| Provider | Required | Optional | Published schema |
| --- | --- | --- | --- |
| `algolia` | `apiKey`, `appId`, `sourceIndex` | `overwrite`, `targetIndex` | `AlgoliaMigrationPreviewRequest` |
| `meilisearch` | `apiKey`, `endpoint`, `sourceIndex` | `overwrite`, `targetIndex` | `MeilisearchMigrationPreviewRequest` |
| `typesense` | `apiKey`, `appId`, `sourceIndex` | `overwrite`, `targetIndex` | `AlgoliaMigrationPreviewRequest` |

Typesense has no schema of its own because the engine publishes an
Algolia-shaped body for it — see the determination in the preceding addendum,
which classifies that as an upstream contract defect, not a Typesense contract.

### Response fields the console renders

`MigrationPreviewResponse` requires both `report` and `sourceCounts`.

- `sourceCounts.indexes` — integer, minimum 0, required.
- `sourceCounts.records` — integer, minimum 0, required.
- `report.summary` — all four counters required: `totalEntries`,
  `hardRejections`, `warnings`, `scopeGaps`.
- `report.entries[]` — required on every entry: `severity`, `code`, `resource`,
  `jsonPath`. Optional: `pageIndex`, `itemIndex` (present only for per-item
  findings).
- `report.reportDigest` — optional.

Entry vocabulary, published from the engine contract fixture and asserted
against it:

- `severity`: `ScopeGap`, `Warning`, `HardRejection`.
- `resource`: `Analytics`, `ApiKeys`, `Document`, `Events`, `Experiments`,
  `Recommend`, `Rule`, `Settings`, `Synonym`.
- `code` (23 values): `ProductNotMigrated`, `PersistedNoBehaviorSetting`,
  `ReadOnlySourceField`, `ReplicaTopologyNotMigrated`, `UnsupportedSourceField`,
  `UnsupportedRuleSchema`, `UnsupportedSynonymSchema`, `InvalidObjectId`,
  `DuplicateObjectId`, `MalformedSettingsPayload`, `MalformedDocumentPayload`,
  `MalformedRulePayload`, `MalformedSynonymPayload`,
  `ReplicaUnknownRankingToken`, `ReplicaExhaustiveSortApproximated`,
  `ReplicaPrimaryRelevancyStrictnessDropped`,
  `ReplicaRelevancyStrictnessSemanticMismatch`,
  `ReplicaMatchingCriticalFieldDiverges`,
  `MeilisearchDocumentOrderNotContractual`,
  `MeilisearchSearchPaginationNotExportBound`, `MeilisearchSettingNotMigrated`,
  `MeilisearchSettingValueNormalized`, `TypesenseSettingNotMigrated`.

Treat these three as closed sets. If the engine adds a value, the fixture
regenerates and `migration_preview_openapi_surface_is_schema_bound` goes red
before the console can be handed a value it does not render.

### What enforces the above

`infra/api/tests/integration/openapi_spec_final_test.rs::migration_preview_openapi_surface_is_schema_bound`
is the single contract owner. Stage 4 added four guards to it, each proven red
by an intentional mutation that was reverted immediately:

| Guard | Intentional mutation | Observed red |
| --- | --- | --- |
| Spec publishes exactly the one mounted preview path | `preview.rs` path changed to `/migration/algolia/preview` | `left: ["/migration/algolia/preview"]` vs `right: ["/migration/{source_provider}/preview"]` |
| Path parameter is named `source_provider` | (covered by the same owner; no separate mutation) | — |
| Published provider enum equals the fixture's provider vocabulary | added an `Opensearch` variant to `SourceImportProvider` | `left: [... "typesense", "opensearch"]` vs `right: [... "typesense"]` |
| Every provider resolves to exactly one published request variant with its pinned fields | renamed `MeilisearchMigrationPreviewRequest.endpoint` to `host` | `provider meilisearch must resolve to exactly one published preview request variant`, `left: 0` / `right: 1` |

The last guard is the only assertion anywhere that covers Typesense's pinned
request fields. If the engine ever gives Typesense a distinct request shape, the
existing `oneOf` and per-schema field assertions would all still pass while the
console silently lost its Typesense contract; this guard catches that.

### Statelessness — the proof and its specimen

Preview never writes `algolia_import_jobs`. The Stage 3 owner section above
holds the full commands; the load-bearing numbers:

- **Specimen**: `before=0 meilisearch_http=400 typesense_http=400 after=0`
  — two live requests, one per locally available provider, against an isolated
  local Postgres. Both took the live engine **error** path and still wrote zero
  durable rows. The success-path live claim is not made; see per-provider proof
  method below.
- **Intentional mutation that proved the guard can fail**: an exact
  `INSERT INTO algolia_import_jobs` of the sentinel row
  `id = '00000000-0000-4000-8000-00000000c329'` (full statement in the
  Statelessness and falsifiability section). The identity assertion then
  observed `before=0`, `after_insert=1`, and exited 1. Cleanup was the exact
  `DELETE FROM algolia_import_jobs WHERE id = '00000000-0000-4000-8000-00000000c329'`
  and observed `after_delete=0`.
- **Committed backstop**:
  `migration_routes_test::preview::algolia_preview_does_not_create_import_job_row`.
  It requires `DATABASE_URL`; without it the test panics with
  "DATABASE_URL must be set" by design. The `migration-test` gate does **not**
  cover it — that gate covers SQL migration application only.

### Credential non-leakage — the exact denominator

Two marked canary credentials were carried in the live Meilisearch and Typesense
requests. The searched surfaces were exactly these seven, not a general
"logs and store" sweep:

1. `.local/api.log`
2. every `.local/flapjack*.log` — one concrete file, `.local/flapjack-default.log`
3. `.local/source-provider-evidence/provider_container_logs.log`
4. `.local/stage3_meilisearch_preview.json` (saved preview response body)
5. `.local/stage3_typesense_preview.json` (saved preview response body)
6. every live `algolia_import_jobs` row serialized with `row_to_json`
7. `.local/source-provider-evidence/secret_redaction.json`, whose five
   assertions were all `true`

Zero literal hits in all seven. A schema-owner grep for
`INSERT INTO|UPDATE ... algolia_import_jobs|DELETE FROM` in
`infra/api/src/routes/migration/preview.rs` returned zero matches, so there is
no second durable owner on the preview path that the denominator could miss.

### Per-provider proof method — do not merge these into one claim

| Provider | Method | What is proven | What is **not** proven |
| --- | --- | --- | --- |
| `algolia` | Contract-backed deterministic fixture + mock-engine integration test `algolia_preview_preserves_engine_report` | fjcloud forwards the engine's report byte-equivalently and hits the provider-specific engine URL, for the specimen `indexes=3`, `records=42` with exact Warning and HardRejection entries | Nothing live. Algolia is SaaS-only with no local source container; no live Algolia run was performed |
| `meilisearch` | Stage 3 live local run against a seeded container, then gap spec | the route is reachable, forwards, and writes no durable row on the engine error path | The live success path. Observed HTTP 400 `Meilisearch Cloud endpoint is not allowed`; no `sourceCounts` returned |
| `typesense` | Stage 3 live local run, then gap spec | same as Meilisearch | The live success path. Observed HTTP 400 `source_provider_unsupported`; Typesense preview is unimplemented upstream |

Both live gaps are **external-unreachable in flapjack_dev**, each with a named
upstream owner: `meilisearch_client.rs` for the loopback validator (upstream
plan already committed at flapjack `283d9fd5b`), and the missing Typesense
preview reader at `handlers/migration/mod.rs:1019`. Conditional dispositions in
the Upstream gap specifications section stand unchanged. The console lane should
present Meilisearch and Typesense preview as engine-blocked, not as proven.

### ROADMAP status — no correction required

Checked against `origin/main` at `a817f7892432`, without editing `ROADMAP.md`.
Both relevant rows are already accurate; their titles quoted verbatim:

- `Provisioning, placement, replicas, discovery, and Algolia migration` — its
  2026-08-01 update correctly records the three-identity closed union, the
  Algolia-only adapter, and `SourceImportProvider::has_adapter()` returning
  false for Meilisearch and Typesense as the remaining model-boundary block.
- `Refugee conversion depth — migration preview and full warning detail are authored and undispatched`
  — its 2026-08-01 remeasurement already retracts the stale "the flapjack engine
  publishes no preview route at all" premise and records all three preview paths
  as present upstream. That retracted premise must not be cited again.

No `ROADMAP CORRECTION REQUIRED` note is raised by Stage 4.

### One integration note for whoever merges this

This branch's `docs/reference/openapi.json` still carries the merge-base-era
concrete `/migration/algolia/...` paths for the six stateful migration routes,
while `origin/main` has since republished those six as `{source_provider}`
paths. Preview itself is already neutral on both sides. After merging `main`,
regenerate the artifact through its owner —
`cd infra && UPDATE_OPENAPI_ARTIFACT=1 cargo test -p api --test platform openapi_spec_matches_committed_artifact -- --nocapture`
— so the committed spec carries all seven neutral paths plus preview. This is
branch staleness, not a regression introduced here: the Stage 4 diff against the
merge base adds 319 lines to that artifact and deletes none.

### Stage 4 gates at HEAD

```text
cd infra && cargo test -p api --test platform migration_preview_openapi_surface_is_schema_bound
PASS: 1 passed, 0 failed

cd infra && UPDATE_OPENAPI_ARTIFACT=1 cargo test -p api --test platform \
  openapi_spec_matches_committed_artifact -- --nocapture
PASS: artifact already current — git status --porcelain reported no change

cd infra && cargo test -p api --test platform openapi_spec_matches_committed_artifact
PASS: 1 passed, 0 failed

bash scripts/local-ci.sh --gate migration-test      PASS: pass=1 fail=0 skip=0
bash scripts/local-ci.sh --gate rust-lint           PASS: pass=1 fail=0 skip=0 (267s)
```

Scope guards, run at HEAD `41a6a95dd` with a clean tree:

```text
git diff --name-only origin/main...HEAD -- ROADMAP.md   -> (no output)
git diff --name-only origin/main...HEAD -- web/         -> (no output)
git diff --check                                        -> (no output)
git status --porcelain --untracked-files=all            -> (no output)
```

Stage 4 therefore stayed out of `ROADMAP.md` and `web/**`, introduced no
whitespace errors, and left no uncommitted or untracked residue.

Re-verified after this closeout was committed: all four guards above produced
no output again at `37e29723d`, the commit that added this Stage 4 section. The
only change between `41a6a95dd` and `37e29723d` is this file.
