# Expected Seeded Record Anchors (CLI Probe)

## Why this file exists

The CLI probe writes `seeded_record_object_id` and `seeded_record_title` to
`summary.json` only when the search step retrieves a hit matching the
deterministic seed (`scripts/canary/contracts/cold_customer_journey_walkthrough.sh`,
function `cold_customer_search_index_step` lines 478-505 and the inline
extractor `cold_customer_search_seeded_result` lines 447-470). Because this
Stage 4 CLI run failed at `search_index` with detail `seeded_record_missing`,
those two fields in `cli/summary.json` are empty.

The Stage 4 checklist requires the seeded `objectID` / `title` to remain visible
in evidence as customer-correctness anchors. This sibling file preserves them by
deriving them from the deterministic payload generator
(`scripts/lib/deterministic_batch_payload.sh::deterministic_batch_payload`),
which is the authoritative source for what the batch upload contained — the
objectID and title fields are seed-independent, so they can be reconstructed
without rerunning the probe.

## Authoritative payload generator

`scripts/lib/deterministic_batch_payload.sh` lines 9-33:

```python
for i in range(count):
    doc_id = offset + i
    digest = hashlib.sha256(f"{seed}:{doc_id}".encode()).hexdigest()
    requests.append(
        {
            "action": "addObject",
            "body": {
                "objectID": f"doc-{doc_id}",
                "title": f"Document {doc_id}",
                "body": f"Deterministic content {digest[:32]}",
                "category": ["alpha","beta","gamma","delta"][doc_id % 4],
                "score": (doc_id * 17 + seed) % 1000 / 10.0,
                "tags": [f"tag{(doc_id * 3 + j) % 20}" for j in range(3)],
            },
        }
    )
```

The probe called `deterministic_batch_payload "$COLD_CUSTOMER_BATCH_SEED" 0 5`
at line 426, uploading five records with `doc_id` in `[0, 1, 2, 3, 4]`.

## Customer-correctness anchors

Seed-independent fields (these are what any reviewer should look for in the
search response — they identify the records the probe expected to retrieve):

| Position | Expected objectID | Expected title |
|----------|-------------------|----------------|
| 0        | `doc-0`           | `Document 0`   |
| 1        | `doc-1`           | `Document 1`   |
| 2        | `doc-2`           | `Document 2`   |
| 3        | `doc-3`           | `Document 3`   |
| 4        | `doc-4`           | `Document 4`   |

The primary anchor — the record the search step actually queried for — is
`objectID: doc-0`, `title: Document 0`. The search term used by the probe is the
`body` field of `doc-0`, which is `Deterministic content <sha256(seed:0)[:32]>`
and therefore seed-dependent. The probe does not currently persist the seed it
used; if a future evidence audit needs to reproduce the exact search query, the
probe would need to be extended to record `COLD_CUSTOMER_BATCH_SEED` into
`summary.json` (out of scope for Stage 4 — would be a Stage 2 probe change).

## Cross-reference to wire evidence

- The batch was accepted by staging: `cli/cli_steps.jsonl` line 5,
  `"step": "batch_write"`, `"http_status": 200`, `"body_shape_keys": ["objectIDs", "taskID"]`.
- `cli/summary.json` confirms `batch_accepted: 5`.
- The search call returned an empty hit set: `cli/cli_steps.jsonl` line 6,
  `"step": "search_index"`, `"http_status": 200`,
  `"detail": "seeded_record_missing"`, body keys include `"hits"`, `"nbHits"`,
  `"exhaustive"`, `"page"` — these confirm a well-formed empty result, not a
  malformed response.
- Because none of `doc-0`..`doc-4` appeared in the search response within the
  probe's 5 × 1s retry budget, the customer-correctness anchor evidence is
  "expected anchors known, none observed" — which is itself the load-bearing
  customer-visible defect documented in `findings.md` as F1.
