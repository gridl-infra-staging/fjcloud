# Stage 4 Soak Verdict — 20260528T135027Z_NONGREEN

- Command: `bash scripts/launch/multi_tenant_isolation_probe.sh --env staging --tenants A,B,C --duration-minutes 30 --restart-api-once --assert --out docs/runbooks/evidence/ha_coverage_a5/20260528T135027Z_GREEN`
- Terminal artifacts present: `soak_exit_code.txt` + `summary.json` + `soak_stdout_stderr.log`
- Probe exit: `1` (assertion failure, no crash)

## Measured summary (`summary.json`)
- `restart_invoked=true`
- `restart_window_start_epoch=1779976270`
- `restart_window_end_epoch=1779976282`
- `writes_attempted=144`
- `writes_attempted_total=33300`
- `fail_fast_responses_during_window=0`
- `visible_in_search_after=0`
- `silent_drops=144`
- `cross_tenant_leaks=0`
- `noisy_neighbor_violations=0`

## Direct log/counter checks
- Restart-window write events: `B|200=144` (no non-200 in window)
- Restart-window search events: `total=0`
- Post-run recheck with owner callback still returns `NOW_VISIBLE=0` for tenant B window writes.
- Exact-doc probe example: `doc-1100008` => hit count `0` after run completion.

## Decision
- Verdict: **NON-GREEN**
- Reason: `silent_drops` assertion fails (`144 > 0`).
- Cross-tenant isolation and noisy-neighbor assertions are green (`0` each), but Stage 4 gate remains blocked until restart-window visibility/durability failure is resolved.
