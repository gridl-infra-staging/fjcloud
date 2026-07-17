# Stage 5 Evidence Note

## Gate-to-Artifact Mapping

1. Create timestamped Stage 5 evidence dir + transcript capture
- Directory: `docs/runbooks/evidence/staging-isolation/20260521T192648Z_stage5_closeout/`
- Path record: `_evidence_dir_path.txt`

2. Re-run `web_api_base_url_contract` for staging + prod
- Command: `bash scripts/canary/contracts/web_api_base_url_contract.sh staging`
  - Artifacts: `contract_web_api_staging.stdout.txt`, `.stderr.txt`, `.meta.txt`, `.cache_check.txt`
  - Result: `exit_code=0` (PASS)
- Command: `bash scripts/canary/contracts/web_api_base_url_contract.sh prod`
  - Artifacts: `contract_web_api_prod.stdout.txt`, `.stderr.txt`, `.meta.txt`, `.cache_check.txt`
  - Result: `exit_code=0` (PASS)

3. Direct `/signup` probe + OAuth href extraction
- Command: `curl -sS --max-time 20 https://cloud.staging.flapjack.foo/signup`
  - Artifacts: `direct_signup_html.stdout.txt`, `.stderr.txt`, `.meta.txt`, `.cache_check.txt`
  - Result: `exit_code=0`
- Command: `grep -oE 'href="[^"]*/auth/oauth/(google|github)/start"'` against captured HTML
  - Artifacts: `direct_signup_oauth_hrefs.stdout.txt`, `.stderr.txt`, `.meta.txt`, `.cache_check.txt`
  - Result: `exit_code=0`

4. Run local CI with contracts
- Command: `FJCLOUD_SECRET_FILE=/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret bash scripts/local-ci.sh --with-contracts`
- Artifacts: `local_ci_with_contracts.stdout.txt`, `.stderr.txt`, `.meta.txt`, `.cache_check.txt`
- Result: `exit_code=0` (all gates pass)

5. Staging auth-session acceptance proof (staging-issued token -> staging dashboard)
- Auth constants owner: `web/src/lib/auth-session-contracts.ts` (`AUTH_COOKIE`, `DASHBOARD_SESSION_EXPIRED_REDIRECT`)
- Saved replay path uses: `POST https://api.staging.flapjack.foo/auth/login` (see `auth_probe_replay_commands.sh` and `final_sanity_auth_login.meta.txt`)
- Saved dashboard artifacts do not prove acceptance:
  - `dashboard_probe.meta.txt` records `final_url=https://cloud.staging.flapjack.foo/login` with `redirects=1`
  - `final_sanity_dashboard.meta.txt` records `final_url=https://cloud.staging.flapjack.foo/dashboard` with `redirects=0`
  - `final_sanity_dashboard_probe.stdout.txt` records `final_url=https://cloud.staging.flapjack.foo/login` with `redirects=1`
- Result: **NOT PROVEN** by this bundle; the dashboard replay needs a single coherent PASS transcript.

6. OAuth href isolation verification (post-deriveApiBaseUrl deploy)
- `cloud.staging.flapjack.foo/login` OAuth hrefs: `https://api.staging.flapjack.foo/auth/oauth/{google,github}/start`
- `cloud.flapjack.foo/login` OAuth hrefs: `https://api.flapjack.foo/auth/oauth/{google,github}/start`
- Result: **PASS** — each domain routes to its matching API origin

7. Known anomaly claim: CF Pages JWT_SECRET cross-env acceptance
- This bundle does not include a matching prod-dashboard probe transcript proving cross-env acceptance.
- Treat any JWT-secret drift as an open follow-up, not as a pass-closing fact for this bundle.

## Status
- Stage 5 is **not pass-closed**.
- Earlier routing-contract artifacts passed, but the saved final-sanity contract rerun in `final_sanity_contract_staging.meta.txt` exited `1`.
- The auth-session acceptance artifacts also disagree on whether `/dashboard` accepted the staging-issued session, so the bundle does not yet meet the stage gate.
