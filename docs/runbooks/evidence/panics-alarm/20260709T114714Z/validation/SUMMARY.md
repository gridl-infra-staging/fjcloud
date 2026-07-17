# Validation command evidence

HEAD: `1018be16f3e1f94c0db7d2ac496d70f3094546e2`
Session: `s25_build_stage5-validation-readback`

- PASS `cd infra && cargo test -p api panics_publisher` :: exit 0; log `docs/runbooks/evidence/panics-alarm/20260709T114714Z/validation/01_cargo_test_api_panics_publisher.log`
- PASS `cd infra && cargo test -p api` :: exit 0; log `docs/runbooks/evidence/panics-alarm/20260709T114714Z/validation/02_cargo_test_api.log`
- PASS `cd infra && cargo clippy -p api` :: exit 0; log `docs/runbooks/evidence/panics-alarm/20260709T114714Z/validation/03_cargo_clippy_api.log`
- PASS `terraform -chdir=ops/terraform/monitoring validate` :: exit 0; log `docs/runbooks/evidence/panics-alarm/20260709T114714Z/validation/04_terraform_monitoring_validate.log`
- PASS `bash ops/terraform/tests_stage7_static.sh` :: exit 0; log `docs/runbooks/evidence/panics-alarm/20260709T114714Z/validation/05_tests_stage7_static.log`
- PASS `git diff --check -- docs/runbooks/alerting.md ROADMAP.md` :: exit 0; log `docs/runbooks/evidence/panics-alarm/20260709T114714Z/validation/06_git_diff_check_docs.log`
- PASS `bash scripts/check_roadmap_v2_shape.sh` :: exit 0; log `docs/runbooks/evidence/panics-alarm/20260709T114714Z/validation/07_check_roadmap_v2_shape.log`
- FAIL `bash scripts/local-ci.sh --fast` :: exit 1; log `docs/runbooks/evidence/panics-alarm/20260709T114714Z/validation/08_local_ci_fast.log`
- PASS `cd web && pnpm install --frozen-lockfile` :: restored missing local web dependencies; log `docs/runbooks/evidence/panics-alarm/20260709T114714Z/validation/09_web_pnpm_install_frozen_lockfile.log`
- PASS `bash scripts/local-ci.sh --fast` :: rerun after dependency restoration; log `docs/runbooks/evidence/panics-alarm/20260709T114714Z/validation/10_local_ci_fast_after_pnpm_install.log`

The first `local-ci --fast` failure was an environment prerequisite failure:
`web-lint` and `web-test` both reported `web/node_modules missing`. No product
code was changed.
