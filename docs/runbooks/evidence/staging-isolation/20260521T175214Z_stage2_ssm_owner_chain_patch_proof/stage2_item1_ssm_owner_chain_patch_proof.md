# Stage 2 Item 1 SSM owner-chain patch proof (20260521T175214Z)

## Scope
- Re-issued preview-only Pages PATCH for project flapjack-cloud.
- Sourced JWT_SECRET and ADMIN_KEY from staging SSM in the same command flow immediately before payload build.
- Kept production env map unchanged; validated by structured assertions.
- Did not save decrypted secret values in committed artifacts.

## Owner-chain proof steps
1. Loaded repo-local auth/config from .secret/.env.secret.
2. Verified AWS identity from raw/aws_sts_get_caller_identity.json.
3. Verified staging SSM parameter types from raw/ssm_jwt_secret_type.txt and raw/ssm_admin_key_type.txt (both SecureString).
4. Read decrypted values in-memory via aws ssm get-parameter for /fjcloud/staging/jwt_secret and /fjcloud/staging/admin_key.
5. Built the PATCH body by merging the live preview env map and injecting those in-memory values as secret_text entries, then removed the temporary request-body file after PATCH.
6. Ran ops/scripts/lib/generate_ssm_env.sh staging with temporary output files and FJCLOUD_SKIP_METERING_ENV_GENERATION=1; log at raw/generate_ssm_env_staging_owner_chain.log proves the owner-chain script now executes under local Bash 3.2.

## Results
- PATCH request success is recorded in raw/cf_pages_patch_response.json.
- Post-PATCH readback confirms preview map retains keys and Cloudflare types; API_BASE_URL and ENVIRONMENT are staging values.
- Production env_vars remained unchanged from the pre-PATCH snapshot.
- Assertions passed in raw/assertions_stage2_ssm_owner_chain.txt.

## Artifact index
- Pre-PATCH GET: raw/cf_pages_project_pre_patch.json
- PATCH response: raw/cf_pages_patch_response.json
- Post-PATCH GET: raw/cf_pages_project_post_patch.json
- Sanitized payload (no secret values): raw/patch_payload_sanitized.json
- Assertions: raw/assertions_stage2_ssm_owner_chain.txt
- AWS/SSM probe evidence: raw/aws_sts_get_caller_identity.json, raw/ssm_jwt_secret_type.txt, raw/ssm_admin_key_type.txt
- Owner script execution proof: raw/generate_ssm_env_staging_owner_chain.log

## Stage sequencing note
- Live /signup behavior is still expected to remain unchanged until Stage 3 publishes a fresh staging preview deployment.
