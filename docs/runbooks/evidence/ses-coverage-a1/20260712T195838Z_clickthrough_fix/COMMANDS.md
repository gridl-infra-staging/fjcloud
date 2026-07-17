# Stage 3 Clickthrough Fix Commands

PURPOSE: Timestamped command log for Stage 3 staging clickthrough owner verification. Secret values are never printed; database receipts are endpoint plus sha256_16 only.

- UTC bundle: 20260712T195838Z_clickthrough_fix
- Secret source: /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret (loaded by commands via --env-file or FJCLOUD_SECRET_FILE; contents not copied)
- Baseline diagnosis re-read: docs/runbooks/evidence/ses-coverage-a1/20260712T185310Z_db_visibility_diagnosis/DIAGNOSIS.md
- Head at start: dd8a212223289075b7306290020ad687fcc45f19

## Commands

- `FJCLOUD_SECRET_FILE=/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret bash scripts/probe_live_state.sh` -> exit `0`; stdout/stderr captured in bundle.
- `aws ec2 describe-instances --filters Name=tag:Name,Values=fjcloud-api-staging Name=instance-state-name,Values=running ...` after loading the canonical secret file -> captured as `ec2_running_instances.json` and summarized without secrets.
- `aws ssm describe-instance-information ...` after loading the canonical secret file -> captured as `ssm_instance_information.json` and summarized without secrets.
- `aws ec2 describe-instances` with live-state literal secret parser -> exit `0`; sanitized JSON captured.
- `aws ssm describe-instance-information` with live-state literal secret parser -> exit `0`; sanitized JSON captured.
- `scripts/launch/ssm_exec_staging.sh <sanitized database fingerprint command>` with live-state literal secret parser -> exit `0`; stdout/stderr captured as remote database fingerprint receipts.
- `aws ssm get-parameter --name /fjcloud/staging/database_url --with-decryption` with live-state literal secret parser -> exit `0`; endpoint/hash only captured.
- `bash scripts/probe_verify_email_clickthrough_e2e.sh --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret` with credentials pre-exported by live-state literal parser -> exit `0`; combined output captured as `verify_email_clickthrough.log`.
- `bash scripts/probe_password_reset_clickthrough_e2e.sh --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret` with credentials pre-exported by live-state literal parser -> exit `0`; combined output captured as `password_reset_clickthrough.log`.
- First direct `aws ec2 describe-instances` attempt through `scripts/lib/env.sh::load_layered_env_files` returned `AuthFailure`; rerun used the same literal parser as `scripts/probe_live_state.sh`, which succeeded. No secret values were printed or stored.
- `cat > docs/runbooks/evidence/ses-coverage-a1/20260712T195838Z_clickthrough_fix/database_fingerprints.md` -> wrote sanitized fingerprint summary.
- `cat > docs/runbooks/evidence/ses-coverage-a1/20260712T195838Z_clickthrough_fix/SUMMARY.md` -> wrote closeout summary.
- `bash scripts/check_evidence_secret_hygiene.sh` -> exit `0`; output captured as `secret_hygiene.log`.
- `cp docs/live-state/20260712T195901Z/SUMMARY.md .../live_state_summary.md` and exact-session cleanup of `docs/live-state/20260712T195901Z/` -> retained live-state summary inside the Stage 3 bundle.
