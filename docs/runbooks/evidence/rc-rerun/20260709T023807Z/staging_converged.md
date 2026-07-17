# Stage 1 Staging Convergence Evidence

UTC captured: 2026-07-09T02:38:07Z

## Decision

Staging is running the deployable code intended for the paid-beta RC rerun.

`RC_SHA=7125cc4db3cf3a28b4ea313b47a55c52ab4cd4bc`

Stage 2 must pass this exact SHA into:

```bash
bash scripts/launch/invoke_rc_with_env.sh --sha=7125cc4db3cf3a28b4ea313b47a55c52ab4cd4bc ...
```

Do not fall back to floating `origin/main` for the RC rerun.

## Owner Contract Read

Read before probing:

- `scripts/deploy_status.sh`: `probe_version` probes `/version`, `extract_field` maps failed probes to `unknown`, and the `jq -n` block emits `.envs.<env>.dev_sha`, `.mirror_sha`, `.synced_at`, `.build_time`, and `.commits_behind_main`.
- `.debbie.toml`: owns the dev-to-mirror sync surface. Deployable comparison used synced roots that can affect build, release, deploy, or deployed validation behavior.
- `docs/runbooks/infra-deploy.md`: documents that mirror SHAs differ from dev SHAs; the live `/version.dev_sha` is the dev-repo anchor for this proof.

## Fixed SHAs

- `MAIN_SHA=09abb8c1c807c37a7be9c32f088b5dd92b10f65b`
- Initial staging `dev_sha=7125cc4db3cf3a28b4ea313b47a55c52ab4cd4bc`
- Final staging `dev_sha=7125cc4db3cf3a28b4ea313b47a55c52ab4cd4bc`
- Initial staging `mirror_sha=c4945df224979ffcb4e7624dc3ad1349fed83001`
- Final staging `mirror_sha=c4945df224979ffcb4e7624dc3ad1349fed83001`
- `synced_at=2026-07-09T01:41:19Z`
- `build_time=2026-07-09T01:45:03Z`
- `RC_SHA=7125cc4db3cf3a28b4ea313b47a55c52ab4cd4bc`

## Live Probe

Command:

```bash
source /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret
git fetch origin
MAIN_SHA=$(git rev-parse origin/main)
bash scripts/deploy_status.sh --json --env staging
```

Output:

```json
{
  "dev_main_sha": "09abb8c1c807c37a7be9c32f088b5dd92b10f65b",
  "envs": {
    "staging": {
      "url": "https://api.staging.flapjack.foo/version",
      "dev_sha": "7125cc4db3cf3a28b4ea313b47a55c52ab4cd4bc",
      "mirror_sha": "c4945df224979ffcb4e7624dc3ad1349fed83001",
      "synced_at": "2026-07-09T01:41:19Z",
      "build_time": "2026-07-09T01:45:03Z",
      "commits_behind_main": "4"
    }
  }
}
```

## Deployable Root Set

The deployable comparison used this conservative synced-root set:

```text
.github/
infra/
web/
ops/
scripts/
Cargo.toml
Cargo.lock
Makefile
docker-compose.yml
docker-compose.override.yml.example
.nvmrc
.env.local.example
.gitleaks.toml
.gitignore
tests/
```

Notes:

- `.debbie.toml` also syncs public docs and selected docs directories, but those were treated as non-deployable for this artifact convergence gate.
- Root `Cargo.toml` and `Cargo.lock` are included in the command because the checklist names them, although this repo currently has no tracked root Cargo manifest or lockfile.

## Convergence Proof

Command:

```bash
git diff --name-only "$RC_SHA".."$MAIN_SHA" -- .github/ infra/ web/ ops/ scripts/ Cargo.toml Cargo.lock Makefile docker-compose.yml docker-compose.override.yml.example .nvmrc .env.local.example .gitleaks.toml .gitignore tests/
```

Result: empty output.

The same command was rerun after writing this evidence record against the fixed `MAIN_SHA`, and it remained empty.

## Non-Blocking Ahead Delta

Command:

```bash
git log --oneline "$RC_SHA".."$MAIN_SHA"
```

Output:

```text
09abb8c1c docs: record the honest React-vs-Svelte counter-case in console brief
0b5c7740f rc-rerun v2: anchor on deployed-code SHA, tolerate doc-only-ahead commits (fixes pm_1 unsatisfiable convergence)
4a0745bd0 docs: add console unification architecture brief
ef007060a matt: terminal progress annotation
```

Changed files:

```text
chats/icg/jul08_am_1_rc_shape_drift_investigate_and_rerun.md
chats/icg/jul08_pm_2_rc_rerun_clean_bundle_v2.md
docs/design/console_unification.md
```

These files are outside the deployable-root comparison, so the ahead delta is non-blocking for Stage 1.

## Sync And Poll Transcript

No `debbie sync staging` run was needed because the deployable diff was empty on the initial convergence check.

No polling loop was needed after the initial live staging SHA because the final deployable diff against the fixed `MAIN_SHA` was already empty.
