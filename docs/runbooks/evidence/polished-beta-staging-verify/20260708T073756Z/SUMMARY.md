# Stage 1 Deploy Parity Summary

classification: parity_converged
ready: true
control_plane_ready: true
pages_ready: true

target_dev_sha: 5f32d715639f13c353b6e6e8397aa528a8903b72
staging_mirror_sha: 29658e72ad174ae546ea8e2fd05a8877330ab367

control_plane:
- final_status: deploy_status_final.json
- staging.dev_sha: 5f32d715639f13c353b6e6e8397aa528a8903b72
- staging.mirror_sha: d7b13257f6c7e281639c82715260d4c7b9b821f2
- staging.commits_behind_main: 0
- staging.build_time: 2026-07-08T07:42:25Z

web_plane:
- build_log: pages_build.log
- deploy_log: pages_deploy.log
- cloud_staging_alias_output: pages_parity_cloud_staging.github_output
- cloud_prod_alias_output: pages_parity_cloud_prod.github_output
- cloud_staging_ready: true
- cloud_prod_ready: true

No browser-lane claims are made in this Stage 1 bundle.
