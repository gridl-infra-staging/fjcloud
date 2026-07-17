# Stage 2 Preflight Summary
captured_at_utc: 2026-05-20T22:04:18Z
bundle_rel: docs/runbooks/evidence/pipeline-propagation/20260520T220316Z_45cd313f1927_pipeline_propagation
frozen_candidate_sha: 45cd313f192796900501a0e7ab92728a6c37ed98
current_dev_head_sha: 45cd313f192796900501a0e7ab92728a6c37ed98
freeze_rule_status: head_unchanged

## Validation commands
- bash scripts/tests/ci_workflow_test.sh => exit 0
- bash scripts/tests/local_ci_gate_set_e_test.sh => exit 0
- bash scripts/local-ci.sh --full => exit 0

## local-ci --full summary excerpt
```
=== local-ci summary (wall 50s) ===
GATE                STATUS   SECS  LOG
----                ------   ----  ---
check-sizes         PASS        2  $TMPDIR/redacted-path
migration-test      PASS        0  $TMPDIR/redacted-path
publish-scripts-buildx  PASS        0  $TMPDIR/redacted-path
rust-lint           PASS       21  $TMPDIR/redacted-path
rust-test           PASS       29  $TMPDIR/redacted-path
secret-scan         PASS        0  $TMPDIR/redacted-path
validate-bootstrap-parser  PASS        0  $TMPDIR/redacted-path
web-lint            PASS       14  $TMPDIR/redacted-path
web-test            PASS       10  $TMPDIR/redacted-path

Totals: pass=9 fail=0 skip=0
Result: PASS

[exit_code]=0
```

## Gate evaluation
- Required publishable gates satisfied only if rust-test, rust-lint, migration-test, web-test, check-sizes, web-lint, and secret-scan are PASS.
- Non-gating gate excluded from publishability decision: playwright.
