# Stage 2 Devalue Fix Classification

Run bundle: `docs/runbooks/evidence/metrics-probe-ns-timestamp/20260712T190558Z_devalue_fix`

Verdict: green for the authenticated Metrics-tab probe contract; the devalue parser residual is closed.

Evidence:

- Live command exit: `probe.exit` contains `0`.
- `probe.summary.json` reports `status == "pass"` and `exit_code == 0`.
- Endpoint metrics checks remain green: `shape_ok == true`, `cache_reuse_ok == true`, `metrics_populated_ok == true`.
- The Metrics-tab proof is now green: `metrics_tab_data_ok == true`, `metrics_tab_data_response_type == "data"`, and the captured `metrics_tab_data_response.nodes[2].data[88]` object preserves the devalue-indexed metrics slot that the updated parser resolves.
- Focused regression coverage is green at `scripts/tests/customer_metrics_authenticated_probe_test.sh` (80 passed), including the Stage-1 captured fixture plus negative cases for a missing metrics field and an unresolved `fetched_at` reference.

Validation context:

- `local-ci-fast.stdout` records `rust-lint PASS`, which includes the newly registered `scripts/tests/customer_metrics_authenticated_probe_test.sh`.
- `local-ci-fast.exit` contains `1`, but the remaining failures are outside this lane's scope:
  - `source-pollution`: pre-existing worktree-path leak in `chats/icg/jul12_pm_6_repo_gc_manifest_and_receipts.md`
  - `web-lint` / `web-test`: `web/node_modules` missing on this host

Disposition:

- Close `chats/icg/stubs/jul11_pm_3_metrics_tab_data_shape_gap.md` as a resolved probe-contract defect.
- Close the `ROADMAP.md` metrics-parser residual while leaving the separate `verify_email` inbox follow-up open.
