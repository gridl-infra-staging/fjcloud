# Stage 5 Evidence Manifest

## Prior Stage Artifacts (authoritative)

### Stage 1: Pages/DNS baseline
- `docs/runbooks/evidence/staging-isolation/20260521T171011Z_stage1_baseline/stage1_item1_pages_dns_baseline.md` — project GET, DNS readback, deployment list
- `docs/runbooks/evidence/staging-isolation/20260521T171011Z_stage1_baseline/stage1_item2_prereqs_mutation_matrix.md` — prereqs and mutation matrix

### Stage 2: Preview env merge + SSM owner-chain patch
- `docs/runbooks/evidence/staging-isolation/20260521T173423Z_stage2_preview_env_merge/stage2_item1_preview_env_patch.md` — CF Pages preview env PATCH proof
- `docs/runbooks/evidence/staging-isolation/20260521T175214Z_stage2_ssm_owner_chain_patch_proof/stage2_item1_ssm_owner_chain_patch_proof.md` — SSM owner-chain patch proof

### Stage 3: Preview deploy verification
- `docs/runbooks/evidence/staging-isolation/20260521T182659Z_stage3_preview_deploy_verification/stage3_item1_preview_deploy_verification.md` — deployment publish verification

### Stage 4: Domain reattach execution
- `docs/runbooks/evidence/staging-isolation/20260521T183854Z_stage4_reattach_execution/01_project_get.json` — project GET (pre-mutation)
- `docs/runbooks/evidence/staging-isolation/20260521T183854Z_stage4_reattach_execution/07b_domain_delete_by_name.json` — domain delete
- `docs/runbooks/evidence/staging-isolation/20260521T183854Z_stage4_reattach_execution/08f_add_with_bearer.txt` — domain add (reattach)
- `docs/runbooks/evidence/staging-isolation/20260521T183854Z_stage4_reattach_execution/16b_project_after_wait.json` — project GET (post-mutation)
- `docs/runbooks/evidence/staging-isolation/20260521T183854Z_stage4_reattach_execution/17e_domains_after_wait.json` — domain list (post-mutation)
- `docs/runbooks/evidence/staging-isolation/20260521T183854Z_stage4_reattach_execution/21_final_assertions.json` — final assertions
- `docs/runbooks/evidence/staging-isolation/20260521T183854Z_stage4_reattach_execution/stage4_evidence_note.md` — Stage 4 evidence note

## Stage 5 Artifact Bundle

### Contract reruns
- `contract_web_api_staging.{stdout,stderr,meta}.txt` — `web_api_base_url_contract.sh staging` transcript
- `contract_web_api_prod.{stdout,stderr,meta}.txt` — `web_api_base_url_contract.sh prod` transcript
- `direct_signup_html.{stdout,stderr,meta}.txt` — staging /signup HTML probe
- `direct_signup_oauth_hrefs.{stdout,stderr,meta}.txt` — OAuth href origin extraction
- `local_ci_with_contracts.{stdout,stderr,meta}.txt` — `local-ci.sh --with-contracts` summary

### Auth-session proof
- `auth_login.body.sanitized.json` — staging API login response (token redacted)
- `auth_login.headers.txt` — login response headers
- `dashboard_probe.meta.txt`, `dashboard_probe.headers.txt`, `dashboard_probe.body.html` — `/dashboard` probe with staging-issued cookie
- `auth_probe_replay_commands.sh` — reproducible replay script (derives AUTH_COOKIE from canonical owner)

### Final sanity reruns
- `final_sanity_contract_staging.{stdout,stderr,meta}.txt` — contract rerun at HEAD
- `final_sanity_auth_login.{body.sanitized.json,headers,meta}.txt` — auth login rerun
- `final_sanity_dashboard.body.html`, `final_sanity_dashboard.headers.txt`, `final_sanity_dashboard.meta.txt` — dashboard probe rerun
- `final_sanity_dashboard_probe.{stdout,stderr,meta}.txt` — dashboard probe transcript metadata
