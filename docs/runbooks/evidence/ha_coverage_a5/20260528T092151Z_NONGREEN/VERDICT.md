# Stage 4 A5 soak — VERDICT: NON-GREEN (probe-measurement defects, not a system isolation failure)

Run: 2026-05-28T09:21:51Z → 10:23:15Z (probe_exit=1), `--env staging --tenants A,B,C
--duration-minutes 30 --restart-api-once --assert`. Session s74.

> NOTE on directory name: the path carries the literal `_GREEN` suffix only because
> the Stage 4 checklist hard-codes that suffix in the soak command (items 17–18). The
> verdict is **NON-GREEN**. Do not trust the directory name — read this file.

## summary.json (raw)
```
writes_attempted=33300  fail_fast_responses_during_window=0  visible_in_search_after=1830
silent_drops=31470  cross_tenant_leaks=3  noisy_neighbor_violations=0  restart_invoked=true
restart_window=[1779960149,1779960165] (16s, END>START)
```
Two assertions failed: `silent_drops != 0` and `cross_tenant_leaks != 0`.

## What the SYSTEM actually did (verified against live staging, not against artifacts)

The underlying multi-tenant system behaved correctly. The failing assertions are
**probe measurement-methodology defects**, each verified by direct probes:

### 1. Restart-window write durability: PASS (the actual Stage-4 claim)
`awk` over `probe_owner_write_events.log` for epochs in [1779960149,1779960165]:
**184 in-flight writes during the 16s API restart window, all HTTP 200, 0 failures.**
The restart was probe-owned (`systemctl restart fjcloud-api`, confirmed `active`) and
fired mid-tenant-B as designed. This is the durability proof the stage exists to get.

### 2. `silent_drops=31470` is a FALSE FAILURE (formula artifact + saturation)
Formula: `silent_drops = writes_attempted − (fail_fast_during_window + visible_in_search_after)`
            = 33300 − (0 + 1830) = 31470.
- `visible_in_search_after=1830` is **exactly the number of searches issued**
  (A30+B300+C1500). `run_direct_search_loop` (seed_synthetic_traffic.sh:593) writes
  `sent` (searches performed) to the count file; the probe (multi_tenant_isolation_probe.sh:456)
  uses that as the "writes confirmed visible" term. Since write-rate >> search-rate
  always, this formula can **never** reach 0. This is a probe metric bug.
- Real write outcomes (from event log, by tenant/status):
  `A_200=300  B_200=3000  C_200=24050  C_429=5950`. The only failures are tenant C's
  5950 **steady-state 429 rate-limit backpressure** (C drives 1000 writes/min against
  the node's limit) — expected backpressure, NOT data loss, NOT restart-related.
  This is the scenario already filed as `pl10-saturation-swamps-restart-proof`.

### 3. `cross_tenant_leaks=3` is a FALSE POSITIVE (loose full-text match)
`probe_owner_cross_tenant_leak_count` (seed_synthetic_traffic.sh:406) queries each peer
index for full-text `"Document <source_offset_base>"`. Reproduced live against the
surviving indexes: querying peer B for tenant A's `"Document 100000"` returns B's **own**
`doc-1100000` (title "Document 1100000"), matched via the shared "document" token plus
typo-tolerant `100000`≈`1100000` (`matchedWords:["100000","document"]`). Gibernish
`"zzzznomatch"` returns 0 hits, so the index is not returning everything. Every one of the
6 peer queries returns a hit → all are own-document false positives. **No actual
cross-tenant data leakage exists.** The detector must use exact objectID/filter matching
(e.g. fetch `doc-<offset>` by id, or `filter`), not loose full-text search.

### 4. noisy_neighbor_violations=0 : PASS (all peer + active /health = 200)

## Cleanup (item 22)
- `cleanup_manifest.json` = `{"created_tenants_this_run":[]}` — the 3 demo tenants
  pre-existed in staging (POST returned 409), so the probe correctly did not mark them
  created-this-run and auto-teardown skipped them.
- Manual reap via owner path `probe_teardown_tenant_letters A,B,C` → 204 for all 3
  (customer_ids 0a65f0b7…, 3048552a…, d6e4dc27…). DELETE `/admin/tenants/{id}` is a
  **soft delete** (`customer_repo.soft_delete`, admin/tenants.rs:397); soft-deleted rows
  still appear in `/admin/tenants`, which is why they remained listed. Working as designed.
- Staging has 1329 tenants total, dominated by unrelated suites ("Staging Customer
  Canary" ×796, "Stage2 Verify Probe" ×27, …). Out of this stage's scope.

## Decision
NON-GREEN. Matrix §5 stays `pending`. The system isolation/durability behavior looks
correct, but the probe cannot prove it until the measurement defects (#2 visibility metric,
#3 leak query) are fixed and the silent_drops assertion is scoped to the restart window
(per `pl10-saturation-swamps-restart-proof` / `restart-trigger-ownership`). These are
repo-owned fixes requiring a measurement re-plan — not an external blocker.
