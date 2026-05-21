# Stage 2 Preflight Summary
captured_at_utc: 2026-05-20T21:56:27Z
bundle_rel: docs/runbooks/evidence/pipeline-propagation/20260520T215524Z_12c62ffc0ada_pipeline_propagation
frozen_candidate_sha: 12c62ffc0ada773b6a98db8b5f66885bbe443f45
current_dev_head_sha: 12c62ffc0ada773b6a98db8b5f66885bbe443f45
freeze_rule_status: head_unchanged

## Validation commands
- bash scripts/tests/ci_workflow_test.sh => exit 0
- bash scripts/tests/local_ci_gate_set_e_test.sh => exit 0
- bash scripts/local-ci.sh --full => exit 0

## local-ci --full summary excerpt
```
=== local-ci summary (wall 51s) ===
GATE                STATUS   SECS  LOG
----                ------   ----  ---
check-sizes         PASS        2  $TMPDIR/redacted-path
migration-test      PASS        0  $TMPDIR/redacted-path
publish-scripts-buildx  PASS        0  $TMPDIR/redacted-path
rust-lint           PASS       22  $TMPDIR/redacted-path
rust-test           PASS       29  $TMPDIR/redacted-path
secret-scan         PASS        0  $TMPDIR/redacted-path
validate-bootstrap-parser  PASS        0  $TMPDIR/redacted-path
web-lint            PASS       15  $TMPDIR/redacted-path
web-test            PASS       11  $TMPDIR/redacted-path

Totals: pass=9 fail=0 skip=0
Result: PASS
```

## Gate evaluation
- Required publishable gates satisfied only if rust-test, rust-lint, migration-test, web-test, check-sizes, web-lint, and secret-scan are PASS.
- Non-gating gate excluded from publishability decision: playwright.
