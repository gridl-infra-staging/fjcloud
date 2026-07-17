# Section-3 Security Coverage Evidence Bundle

- Stage goal: refresh all existing Section-3 owners/probes into one reproducible evidence bundle.
- Bundle directory: /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/docs/runbooks/evidence/security-coverage-a3/20260526T154027Z_GREEN
- UTC timestamp (summary finalized): 2026-05-26T15:40:30Z
- Git HEAD: f4996ac1483fece2975bb2e91ee19acd55b6b5d1

## Invocation Contract
- `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/docs/runbooks/evidence/security-coverage-a3/20260526T154027Z_GREEN/commands.sh`
- Env-loading seam for staging commands: `source scripts/lib/env.sh`, `load_env_file "$FJCLOUD_SECRET_FILE"`, `APP_BASE_URL_STAGING=https://cloud.staging.flapjack.foo`

## Owner Manifest
- `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/docs/runbooks/evidence/security-coverage-a3/20260526T154027Z_GREEN/owner_manifest.txt`

## Coverage Results
| Coverage | Owner | Artifact(s) | Verdict |
| --- | --- | --- | --- |
| Rust test boundary | `cargo test -p api --test stripe_webhook_signature_test --test security_test --test noisy_neighbor_test --test auth_lockout_test --test api_key_auth_test --test internal_auth_test --test auth_test` | `cargo_api_section3.log` | PASS |
| Staging OAuth redirect URI contract | `oauth_redirect_uri_contract.sh staging` | `oauth_redirect_uri_contract_staging.log` | PASS |
| EC2 firewalld contract | `ec2_firewalld_contract.sh` | `ec2_firewalld_contract.log` | PASS |
| Live prod reject probe | `stripe_webhook_bad_signature_reject_contract.sh` | `stripe_webhook_bad_signature_reject_contract.log`, `live_prod_stripe_webhook_bad_signature_reject.response` | PASS (HTTP 400) |
| Live prod reject probe | `stripe_webhook_stale_timestamp_reject_contract.sh` | `stripe_webhook_stale_timestamp_reject_contract.log`, `live_prod_stripe_webhook_stale_timestamp_reject.response` | PASS (HTTP 400) |
| Live prod reject probe | `tenant_jwt_wrong_secret_reject_contract.sh` | `tenant_jwt_wrong_secret_reject_contract.log`, `live_prod_tenant_jwt_wrong_secret_reject.response` | PASS (HTTP 401) |
| Live prod status assertion roll-up | status lines per artifact first line | `live_prod_status_lines.txt`, `live_prod_status_assertions.log` | PASS |

## Notes
- The three live-prod probes write full HTTP transcripts to `live_prod_*.response`; status verification is based on the status code in each artifact first line.
- EC2 contract verdict is PASS only when the shell owner exits 0; credential auth failures are explicitly reported as BLOCKED.
