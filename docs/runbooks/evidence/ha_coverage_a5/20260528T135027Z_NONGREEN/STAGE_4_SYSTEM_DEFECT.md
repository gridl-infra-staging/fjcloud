# Stage 4 System Defect (Case 1d): Restart-Window Durability Failure

## Summary

The latest terminal asserted soak bundle is non-green because restart-window writes were acknowledged with HTTP 200 but were not retrievable after the run. This is a system defect signal, not a closeout-doc measurement gap.

Bundle: `docs/runbooks/evidence/ha_coverage_a5/20260528T135027Z_NONGREEN/`

## Raw Artifact Evidence

1. `summary.json` shows restart-window durability failure with no fail-fast responses:
   - `restart_invoked=true`
   - `writes_attempted=144`
   - `fail_fast_responses_during_window=0`
   - `visible_in_search_after=0`
   - `silent_drops=144`
2. `soak_exit_code.txt` is `1` (asserted non-green terminal run).
3. `probe_owner_write_events.log` records restart-window writes for tenant `B` as HTTP 200, including:
   - `1779976270|B|doc-1100008|200`
4. `VERDICT.md` records post-run invisibility from the Stage 4 exact-doc probe:
   - `Exact-doc probe example: doc-1100008 => hit count 0 after run completion.`

## Request/Query Contract and Deterministic Payload

The Stage 4 bundle wrote through the probe owner seam and then checked the
exact-document route for readback:

- Write path: `POST ${flapjack_url}/1/indexes/${flapjack_uid}/batch`
- Exact-ID read path: `GET ${flapjack_url}/1/indexes/${flapjack_uid}/documents/${object_id}`

For `doc-1100008`, the deterministic single-write payload is:

```json
{"requests":[{"action":"addObject","body":{"objectID":"doc-1100008","title":"Document 1100008","body":"Deterministic content 375361714a7d4e11e7e6e83b60669cc8","category":"alpha","score":17.8,"tags":["tag4","tag5","tag6"]}}]}
```

Source-of-truth owner files used for this derivation:
- `scripts/launch/seed_synthetic_traffic.sh` (`run_direct_write_loop`)
- `scripts/lib/deterministic_batch_payload.sh` (`deterministic_batch_payload`)

## 404 Interpretation and Current Owner Drift

During Stage 5 disambiguation, the same owner-auth exact-document route was
re-queried directly for `doc-1100008` and returned HTTP `404`, which matches
the non-green bundle's exact-doc invisibility signal.

After this bundle was produced, `scripts/launch/seed_synthetic_traffic.sh`
changed `probe_owner_query_exact_object_hit_count` to reconstruct the
deterministic body token and query `/query` instead of relying on the unstable
`/documents/<id>` route at `HEAD`. This artifact therefore records the
bundle-time exact-doc evidence and the direct follow-up `404`, not a claim
about the current callback implementation.

## Closeout Consequence

Section 5 in `docs/launch_verification_matrix.md` must remain `pending` and point to this defect artifact until a newer asserted terminal `*_GREEN` soak bundle supersedes this failure mode.
