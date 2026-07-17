# Stage 3 Live Probe Classification

Run bundle: `docs/runbooks/evidence/metrics-probe-ns-timestamp/20260711T220416Z`

Verdict: red, non-parser staging/probe gap.

Evidence:

- Live command exit: `probe.exit` contains `1`.
- Probe-owned summary copied from `docs/runbooks/evidence/customer-metrics-probe/20260711T220416Z/summary.json`.
- `probe.summary.json` reports `status == "fail"` and `exit_code == 1`.
- The seeded metrics population poll passed: `metrics_populated_ok == true`, `first_response.documents_count == 1`, and `second_response.documents_count == 1`.
- Endpoint metrics shape/cache passed: `shape_ok == true`, `cache_reuse_ok == true`, and both responses share `fetched_at == "2026-07-11T22:04:36.376630902Z"`.
- Parser context still demonstrates the operator directive input is not accepted by stock Python: `fromisoformat.exit` contains `1` for `2026-07-11T01:03:15.766682746+00:00`.

Failing owner:

- `scripts/canary/contracts/customer_metrics_endpoint_authenticated_probe.sh::assert_metrics_tab_data_surface`

Exact reason:

- `probe.summary.json` reports `failure_detail == "metrics tab __data.json response did not expose the expected metrics payload shape"`.
- `metrics_tab_data_ok == false`, and no `metrics_tab_data_response` was captured because the script only stores the body after `metrics_tab_data_shape_ok` passes.

Disposition:

- Do not close the `ROADMAP.md` parser residual from this evidence because the live probe did not exit `0`.
- The parser residual is no longer the observed red condition in this run; the remaining blocker is a Metrics-tab `__data.json` shape gap in the authenticated staging probe path.
