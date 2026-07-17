# Stage 1 Item 2 Deliverable: Prerequisites and Minimal Mutation Matrix (2026-05-21T17:10:11Z)

## Sources consulted
- Runtime SSOT owners:
  - `web/src/lib/config.ts:9-12`
  - `web/src/routes/signup/+page.server.ts:17-19`
  - `web/src/routes/login/+page.server.ts:14-16`
- Secret and SSM ownership:
  - `docs/design/secret_sources.md:36-45`
  - `ops/scripts/lib/generate_ssm_env.sh:33-47,90-124`
- Staging host derivation consumer:
  - `scripts/launch/hydrate_seeder_env_from_ssm.sh:40-49,71-107`
- Staging API health prerequisite:
  - `docs/runbooks/staging-access.md:30-33,63-69`
- Minimal expected preview env set:
  - `web/wrangler.toml:19-36`
  - `ops/scripts/lib/generate_ssm_env.sh:43-47`

## Evidence
1. Runtime SSOT is unchanged and still env var driven.
- `getApiBaseUrl()` remains `API_BASE_URL || API_URL || localhost` in `web/src/lib/config.ts:9-12`.
- Signup and login server loads still pass `getApiBaseUrl()` in `signup/+page.server.ts:17-19` and `login/+page.server.ts:14-16`.

2. Staging SSM prerequisites exist for required secrets.
- `raw/ssm_staging_jwt_secret_metadata.json`: `/fjcloud/staging/jwt_secret` exists as `SecureString`.
- `raw/ssm_staging_admin_key_metadata.json`: `/fjcloud/staging/admin_key` exists as `SecureString`.
- Mapping owner still maps `jwt_secret -> JWT_SECRET` and `admin_key -> ADMIN_KEY` in `ops/scripts/lib/generate_ssm_env.sh`.

3. `hydrate_seeder_env_from_ssm.sh` is a consumer and deriver, not an owner.
- It reads `dns_domain` from SSM and derives `API_URL` and `STAGING_CLOUD_URL`. This does not conflict with Pages env ownership.

4. Staging API health prerequisite is satisfied.
- `raw/staging_api_health_headers.txt` shows HTTP 200 on `https://api.staging.flapjack.foo/health`.
- `raw/staging_api_health_body.txt` returns `{"status":"ok"}`.

5. Live preview env map vs minimal expected set.
- Required set: `API_BASE_URL=https://api.staging.flapjack.foo`, `ENVIRONMENT=staging`, secret `JWT_SECRET`, secret `ADMIN_KEY`.
- Live preview map in `raw/cf_pages_extracted_fields.json` still has `API_BASE_URL=https://api.flapjack.foo`.
- Extra preview key that Stage 2 must preserve during merge: `WEB_DEV_LOG_RAW_ERRORS`.

## Minimal mutation matrix
- Stage 2 allowed:
  - Merge and do not replace `deployment_configs.preview.env_vars` on existing `flapjack-cloud`.
  - Set preview `API_BASE_URL=https://api.staging.flapjack.foo`.
  - Preserve preview `ENVIRONMENT=staging`, secret `JWT_SECRET`, secret `ADMIN_KEY`, and extra `WEB_DEV_LOG_RAW_ERRORS`.
- Stage 4 conditionally allowed:
  - Reattach `cloud.staging.flapjack.foo` only if post Stage 2 readbacks still show wrong deployment binding.
  - Correct DNS only if Cloudflare zone readback diverges from Pages managed staging target.
- Explicitly not allowed in this lane:
  - No host derived runtime fallback.
  - No second config source.
  - No broader runtime or routing redesign.

## Open questions
- Stage 2 should verify whether `production.env_vars.ENVIRONMENT=staging` is intentional or accidental, while keeping the same scope boundaries.
