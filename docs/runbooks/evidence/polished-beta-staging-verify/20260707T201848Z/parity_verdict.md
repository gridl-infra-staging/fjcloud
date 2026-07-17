classification: parity_unconvergeable
ready: false
control_plane_ready: false
pages_ready: false
failing_leg: control_plane_version

# Stage 1 Parity Verdict

The Stage 1 control-plane `/version` leg did not converge within the 45-minute lane cap.

## Target

- target_dev_sha: `bdcad5a1aaf21ed6bb93cba5265db9a6b4ef5b1e`
- staging_mirror_after_sync: `bd028555600247fc5efa1f7de1a6930bdfdcb949`

## Final Control-Plane Status

Source command:

```bash
bash scripts/deploy_status.sh --json --env staging
```

Final staging fields from `deploy_status_final.json`:

- dev_main_sha: `bdcad5a1aaf21ed6bb93cba5265db9a6b4ef5b1e`
- envs.staging.url: `https://api.staging.flapjack.foo/version`
- envs.staging.dev_sha: `e20c52c337da5af10defd250ce1339118d5db8c6`
- envs.staging.mirror_sha: `d6d9be4c81567f0104cb7fbcd21fa32a9b7185e1`
- envs.staging.synced_at: `2026-07-07T15:19:52Z`
- envs.staging.build_time: `2026-07-07T15:24:12Z`
- envs.staging.commits_behind_main: `70`

## Evidence Files

- `head_sha.txt`
- `deploy_status_before.json`
- `debbie_sync_staging.stdout`
- `debbie_sync_staging.stderr`
- `deploy_status_poll.jsonl`
- `deploy_status_poll_attempt_91.json`
- `deploy_status_final.json`
- `parity_verdict.md`

## Blocking Stub

- `chats/icg/stubs/jun11_pm_9_parity_unconvergeable_control_plane_timeout.md`

The Cloudflare Pages web-plane leg was not started because Stage 1 requires the API `/version` leg to be ready before Pages verification begins.
