classification: parity_converged
ready: true
control_plane_ready: true
pages_ready: true
failing_leg: none

target_dev_sha: 5f32d715639f13c353b6e6e8397aa528a8903b72
staging_mirror_sha: 29658e72ad174ae546ea8e2fd05a8877330ab367
api_reported_mirror_sha: d7b13257f6c7e281639c82715260d4c7b9b821f2

final_version_fields:
- staging.dev_sha: 5f32d715639f13c353b6e6e8397aa528a8903b72
- staging.mirror_sha: d7b13257f6c7e281639c82715260d4c7b9b821f2
- staging.commits_behind_main: 0
- staging.build_time: 2026-07-08T07:42:25Z

pages_aliases:
- alias: https://cloud.staging.flapjack.foo
  ready: true
  evidence: pages_parity_cloud_staging.github_output, pages_parity_cloud_staging.err
- alias: https://cloud.flapjack.foo
  ready: true
  evidence: pages_parity_cloud_prod.github_output, pages_parity_cloud_prod.err

notes:
- The current staging mirror checkout SHA is the Pages deploy/parity target.
- The API /version leg reports the mirror SHA used by the API deploy that carried the same target dev SHA.
- No browser proof was run in this stage.
