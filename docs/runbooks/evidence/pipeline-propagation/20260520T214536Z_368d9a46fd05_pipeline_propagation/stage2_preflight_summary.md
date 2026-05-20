# Stage 2 Preflight Summary
captured_at_utc: 2026-05-20T21:46:51Z
bundle_rel: docs/runbooks/evidence/pipeline-propagation/20260520T214536Z_368d9a46fd05_pipeline_propagation
frozen_candidate_sha: 368d9a46fd052cce41544968f1f08a598b0656a7
current_dev_head_sha: 368d9a46fd052cce41544968f1f08a598b0656a7
freeze_rule_status: head_unchanged

## Validation commands
- bash scripts/tests/ci_workflow_test.sh => exit 0
- bash scripts/tests/local_ci_gate_set_e_test.sh => exit 0
- bash scripts/local-ci.sh --full => exit 0

## local-ci --full summary excerpt
```
=== local-ci summary (wall 63s) ===
GATE                STATUS   SECS  LOG
----                ------   ----  ---
check-sizes         PASS        2  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/check-sizes.log
migration-test      PASS        1  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/migration-test.log
publish-scripts-buildx  PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/publish-scripts-buildx.log
rust-lint           PASS       22  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/rust-lint.log
rust-test           PASS       41  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/rust-test.log
secret-scan         PASS        1  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/secret-scan.log
validate-bootstrap-parser  PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/validate-bootstrap-parser.log
web-lint            PASS       15  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/web-lint.log
web-test            PASS       11  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/web-test.log

Totals: pass=9 fail=0 skip=0
Result: PASS
```

## Gate evaluation
- Required publishable gates satisfied only if rust-test, rust-lint, migration-test, web-test, check-sizes, web-lint, and secret-scan are PASS.
- Non-gating gate excluded from publishability decision: playwright.
