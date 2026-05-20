# Stage 6 Root Note

Shared preflight gate artifacts for Stage 7:
- `gh_run_list_staging_ci_latest.json`
- `gh_run_list_prod_ci_latest.json`
- `staging_ci_latest_run_id.txt`, `prod_ci_latest_run_id.txt`
- `staging_ci_latest_log_failed_tail60.txt`, `prod_ci_latest_log_failed_tail60.txt`

Stage 7 consumption directories:
- `run_a/` (completed raw AWS + DB teardown bundle)
- `run_b/` (attempt history + latest in-progress PM-backed rerun diagnostics)

Preflight classification summary:
- Both mirror CI latest runs were `failure` at Stage 6 start due `secret-scan` findings in legacy browser evidence JSON files.
- Classified and captured before touching prod reruns.
