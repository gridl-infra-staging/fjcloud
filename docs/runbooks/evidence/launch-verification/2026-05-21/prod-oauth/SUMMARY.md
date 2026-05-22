# Stage 6 — Prod OAuth Launch Proof

Date: 2026-05-21
Scope: production OAuth wiring end-to-end proof (Google + GitHub).

## Commands executed

1. Contract probe (owner: `scripts/canary/contracts/oauth_redirect_uri_contract.sh`):
   ```
   set -o pipefail
   bash scripts/canary/contracts/oauth_redirect_uri_contract.sh prod 2>&1 | tee contract_run.txt
   echo $? > contract_exit_code.txt
   ```
   Exit code: 0 (see `contract_exit_code.txt`).

2. Live deployed-API spot checks:
   ```
   curl -sS -o /dev/null -w "%{http_code}" https://api.flapjack.foo/auth/oauth/google/start
   curl -sS -o /dev/null -w "%{http_code}" https://api.flapjack.foo/auth/oauth/github/start
   ```
   Captured in `google_start_status_code.txt` and `github_start_status_code.txt`.

## Evidence (PASS lines from contract_run.txt)

```
self-test PASS: google probe correctly rejected https://NEVER-REGISTERED-WITH-PROVIDER.example.invalid/oauth-probe-self-test
self-test PASS: github probe correctly rejected https://NEVER-REGISTERED-WITH-PROVIDER.example.invalid/oauth-probe-self-test
PASS: Google OAuth env=prod accepted https://cloud.flapjack.foo/auth/oauth/google/callback (token endpoint error=invalid_grant -- expected for bogus code)
PASS: GitHub OAuth env=prod accepted https://cloud.flapjack.foo/auth/oauth/github/callback (token endpoint error=bad_verification_code -- expected for bogus code)
```

Spot-check status codes:
- `https://api.flapjack.foo/auth/oauth/google/start` → 302
- `https://api.flapjack.foo/auth/oauth/github/start` → 302

No `FAIL`, `WARN`, or `SKIP` tokens in contract output. Self-test sentinels both rejected as required (proves the discriminator is real, not a stub).

## Mapping to runtime owner behavior

`infra/api/src/main.rs::build_oauth_runtime_config` resolves per-provider OAuth runtime config (client_id + client_secret + computed `redirect_uri`) from the env supplied by `ops/scripts/lib/generate_ssm_env.sh`. When a provider's client config is missing, `/auth/oauth/<provider>/start` returns HTTP 501 (`oauth_not_implemented`). The observed 302 for both providers therefore proves:

1. SSM-sourced client credentials are present in the deployed prod API process for both Google and GitHub.
2. `redirect_uri` resolution against `APP_BASE_URL` produced provider-accepted values matching the registered callback URIs at the providers' consoles (also independently verified by the contract probe via the token endpoint discriminator).

Combined: prod OAuth is live for both providers as of 2026-05-21.
