# Pipeline Propagation Contract (Stage 1 Owner)

## Stage 1 Objective And Out Of Scope

Objective: freeze one propagation contract before any mirror publication starts, so Stages 2-5 publish and prove one exact candidate instead of drifting with dev `main`.

Out of scope for Stage 1:
- No `debbie sync` execution.
- No staging/prod mirror reset, commit, or push.
- No live `/health` or `/version` runtime proof capture.
- No edits to contract-owner surfaces (`.debbie.toml`, `.github/workflows/ci.yml`, `scripts/local-ci.sh`, API route files).

Source anchors:
- Stage plan objective and freeze intent: `/Users/stuart/.matt/projects/fjcloud_dev-1fe8889e/may20_3pm_2_pipeline_propagation.md-f61151cc/stages.md:1-23`
- Stage 0 freeze/closeout constraints: `/Users/stuart/.matt/projects/fjcloud_dev-1fe8889e/may20_3pm_2_pipeline_propagation.md-f61151cc/session_handoffs/stage_00/s04_review_plan_stages_tightened_freeze_closeout.md:12-24`

## Contract Owners (Do Not Fork)

1. Mirror scope owner: `.debbie.toml`
- Dev/staging/prod checkout paths are fixed in `[repos.*].path`.
- Public sync surface is the strict `sync.files` + `sync.dirs` whitelist.
- Staging and prod both use the same post-sync hook owner (`.debbie/post-sync.sh`).
- Evidence: `.debbie.toml:4-85`.

2. Scaffolding-strip owner: `.debbie/post-sync.sh::run_scrai_strip()`
- Canonical strip execution is `run_scrai_strip "${DEBBIE_TARGET_ROOT:?}"`.
- Runtime resolution order is: explicit `MATT_REPO_ROOT`, known mike_dev paths, `matt` on PATH, `python3 -m matt`.
- Fallback rule for later stages: if runtime resolution fails, keep ownership on this same seam by rerunning `matt scrai strip` directly; do not redefine ownership. If residue is comment-only, record it as evidence rather than inventing a new deploy gate.
- Evidence: `.debbie/post-sync.sh:5-43`.

3. Publication gate owner: `.github/workflows/ci.yml`
- `deploy-staging.needs[]` and `deploy-prod.needs[]` are identical:
  `rust-test`, `rust-lint`, `migration-test`, `web-test`, `check-sizes`, `web-lint`, `secret-scan`.
- `playwright` is intentionally advisory and omitted from deploy `needs[]`.
- Evidence: `.github/workflows/ci.yml:328-351,434-457`.

4. Local preflight owner: `scripts/local-ci.sh` mirrored by `docs/runbooks/local-ci.md`
- `scripts/local-ci.sh` explicitly declares it mirrors deploy `needs[]` from CI.
- Stage 2 pre-push gate is `bash scripts/local-ci.sh --full`.
- `docs/runbooks/local-ci.md` documents the same gate set and mapping.
- Evidence: `scripts/local-ci.sh:3-20,33-37,151-277`; `docs/runbooks/local-ci.md:1-40`.

5. Runtime proof owner chain: build provenance + `/health` + `/version`
- Build provenance env vars are forwarded into the binary in `infra/api/build.rs`.
- `/health` is liveness-only (`{"status":"ok"}`).
- `/version` is identity-only (`dev_sha`, `mirror_sha`, `synced_at`, `build_time`).
- `route_assembly` registers both endpoints as unauthenticated proof surfaces.
- Evidence: `infra/api/build.rs:4-19`; `infra/api/src/routes/health.rs:4-5`; `infra/api/src/routes/version.rs:7-24`; `infra/api/src/router/route_assembly.rs:105-110`.

## Freeze Rule (Run-Scoped)

Once Stage 2 records the publication candidate dev SHA, Stages 3-5 must publish and prove that exact dev SHA even if dev `main` advances later. If a newer dev `main` commit appears mid-lane, that newer commit starts a separate propagation run; it does not retarget the active run.

Source anchors:
- `/Users/stuart/.matt/projects/fjcloud_dev-1fe8889e/may20_3pm_2_pipeline_propagation.md-f61151cc/stages.md:1-23`
- `/Users/stuart/.matt/projects/fjcloud_dev-1fe8889e/may20_3pm_2_pipeline_propagation.md-f61151cc/stages.md:24-33`

## Cross-Repo SHA Contract

- Dev SHA and mirror SHA are different by design in debbie-synced repos.
- CI injects `FJCLOUD_DEV_SHA` from `.debbie/sync_manifest.json` (when present) and always injects `FJCLOUD_MIRROR_SHA` from `GITHUB_SHA`.
- `/health` cannot prove deploy identity.
- `/version` is the only runtime surface that can prove `dev_sha` plus `mirror_sha`.
- `scripts/deploy_status.sh` is the existing operator seam for comparing deployed `/version.dev_sha` to dev `origin/main`.

Evidence:
- `.github/workflows/ci.yml:366-390,474-498`
- `docs/runbooks/infra-deploy.md:7-27`
- `scripts/deploy_status.sh:2-25,32-53`

## Evidence Layout (Single Bundle Per Run)

Evidence root owner: `docs/runbooks/evidence/pipeline-propagation/`.

Per run, create exactly one bundle keyed to the Stage 2 dev SHA:
- Suggested basename: `<UTCSTAMP>_<devsha12>_pipeline_propagation`
- Example: `20260520T210000Z_abcd1234ef56_pipeline_propagation`

Required sections within that one bundle:
1. Candidate preflight (Stage 2)
2. Staging publication (Stage 3)
3. Prod publication (Stage 4)
4. Prod runtime proof (Stage 5)

Rationale and vocabulary reuse:
- Timestamped bundle naming and sectioned summaries are consistent with existing evidence bundles under `docs/runbooks/evidence/staging-deploy/`.
- Prior lane guidance on `.current_bundle` exists in `chats/icg/may04_pm_5_deploy_proof.md:42-44`.

## `.current_bundle` Decision For This Lane

Yes: this lane uses `docs/runbooks/evidence/pipeline-propagation/.current_bundle` as the only shared-doc pointer to the active bundle.

Pointer format for this repo:
- Use a plain text file containing the bundle path (current local convention), not a symlink.
- Existing examples: `docs/runbooks/evidence/alert-delivery/.current_bundle` and `docs/runbooks/evidence/canary-customer-loop/.current_bundle`.

Stage timing:
- Stage 1 defines this convention.
- Stage 2 initializes `.current_bundle` once the candidate bundle exists.
- Stages 3-5 update the same bundle only; do not create a second active pointer.

## Closeout Identity Key

Final closeout must remain keyed to both:
- Stage 2 candidate dev SHA
- Stage 4 published prod mirror SHA

Any Stage 5 evidence-only dev-repo commit and any `LAUNCH.md` status line are closeout metadata only; they must not be described as the propagated application commit.

## Open Questions

- Should legacy docs that still describe `.current_bundle` as a symlink be normalized to the current repo convention (plain text pointer file), or preserved as historical lane-local guidance?
