# Owner notes

- Runtime smoke is captured through the existing owner script: `ops/terraform/tests_stage7_runtime_smoke.sh`.
- AMI resolution remains owned by `ops/terraform/tests_stage7_runtime_smoke.sh:139-169`.
- No wrapper, duplicate AMI resolution, `--apply`, `--run-deploy`, `--run-migrate`, or `--run-rollback` path is used by this evidence capture.
