# Stage 2 Preflight Summary
captured_at_utc: 2026-05-20T21:27:43Z
bundle_rel: docs/runbooks/evidence/pipeline-propagation/20260520T212504Z_326238b98c67_pipeline_propagation
frozen_candidate_sha: 326238b98c67aa8f7ecc90c010cdb930087e50ec
current_dev_head_sha: 326238b98c67aa8f7ecc90c010cdb930087e50ec
freeze_rule_status: head_unchanged

## Validation commands
- bash scripts/tests/ci_workflow_test.sh => exit 0 (validated this session; recorded in validation_cache)
- bash scripts/tests/local_ci_gate_set_e_test.sh => exit 0 (validated this session; recorded in validation_cache)
- bash scripts/local-ci.sh --full => exit 0 (preflight_logs/*.log copied from ${TMPDIR:-/tmp}/local-ci-last-logs)

## local-ci --full summary excerpt
=== local-ci summary (wall 64s) ===
GATE                STATUS   SECS  LOG
----                ------   ----  ---
check-sizes         PASS        2  $TMPDIR/redacted-path
migration-test      PASS        1  $TMPDIR/redacted-path
publish-scripts-buildx  PASS        0  $TMPDIR/redacted-path
rust-lint           PASS       22  $TMPDIR/redacted-path
rust-test           PASS       42  $TMPDIR/redacted-path
secret-scan         PASS        0  $TMPDIR/redacted-path
validate-bootstrap-parser  PASS        0  $TMPDIR/redacted-path
web-lint            PASS       15  $TMPDIR/redacted-path
web-test            PASS       11  $TMPDIR/redacted-path

Totals: pass=9 fail=0 skip=0
Result: PASS

## Gate evaluation
- Required publishable gates satisfied: rust-test, rust-lint, migration-test, web-test, check-sizes, web-lint, secret-scan.
- Non-gating gate kept out of publishability decision: playwright.
