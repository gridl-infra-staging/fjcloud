# Stage 2 Preflight Summary
captured_at_utc: 2026-05-20T21:15:15Z
bundle_rel: docs/runbooks/evidence/pipeline-propagation/20260520T210651Z_790c9cda817c_pipeline_propagation
frozen_candidate_sha: 790c9cda817c2bcee42e1b0219f9d8b43ff81bcf
current_dev_head_sha: 790c9cda817c2bcee42e1b0219f9d8b43ff81bcf
freeze_rule_status: head_unchanged

## Validation commands
- bash scripts/tests/ci_workflow_test.sh => exit 0 (preflight_logs/ci_workflow_test.log)
- bash scripts/tests/local_ci_gate_set_e_test.sh => exit 0 (preflight_logs/local_ci_gate_set_e_test.log)
- bash scripts/local-ci.sh --full => exit 1 (preflight_logs/local_ci_full.log)
- bash scripts/local-ci.sh --gate web-lint => exit 1 (preflight_logs/local_ci_gate_web_lint.log)
- cd web && npm run check => exit 127 (preflight_logs/web_npm_run_check.log)
- bash scripts/local-ci.sh --gate web-test => exit 1 (preflight_logs/local_ci_gate_web_test.log)
- cd web && npm test => exit 127 (preflight_logs/web_npm_test.log)

## local-ci --full summary excerpt
=== local-ci summary (wall 299s) ===
GATE                STATUS   SECS  LOG
----                ------   ----  ---
check-sizes         PASS        2  $TMPDIR/redacted-path
migration-test      PASS        1  $TMPDIR/redacted-path
publish-scripts-buildx  PASS        0  $TMPDIR/redacted-path
rust-lint           PASS       69  $TMPDIR/redacted-path
rust-test           PASS      230  $TMPDIR/redacted-path
secret-scan         PASS        1  $TMPDIR/redacted-path
validate-bootstrap-parser  PASS        0  $TMPDIR/redacted-path
web-lint            FAIL        0  $TMPDIR/redacted-path
web-test            FAIL        0  $TMPDIR/redacted-path

=== FAIL tails ===

--- web-lint (0s) ---
ERROR: web/node_modules missing — run 'cd web && npm install' first

--- web-test (0s) ---
ERROR: web/node_modules missing — run 'cd web && npm install' first

Totals: pass=7 fail=2 skip=0
Result: FAIL

## Failure classification
- local-ci failing gates: web-lint, web-test
- root cause from gate tails: web/node_modules missing
- stage failed pending env prereq remediation and fresh Stage 2 rerun
