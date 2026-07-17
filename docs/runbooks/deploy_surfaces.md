# Deploy surfaces — the two deploy planes

> **Created:** 2026-05-29. **Why this doc exists:** "how does a change reach customers?" has *two
> different answers* in this repo depending on which surface the change touches, and conflating them
> has bitten more than one agent (a prior agent built a wrong `/version`-based engine-detection gate;
> a later agent mis-classified an AMI bake as env-only-restart instead of rebuild+redeploy). This is
> the stable home for that distinction — previously it lived only inside a launch-orchestration
> `CORRECTED` block.

fjcloud ships **three** independently-deployed surfaces. The control plane is itself split into two
deploy planes — the **API plane** (`fjcloud-api`, SSM → EC2) and the **web plane** (SvelteKit
dashboard, Cloudflare Pages) — that share a source repo but ship through *entirely different*
pipelines and reach customers by different mechanisms. A single feature/fix usually lives in exactly
one of them; know which before you reason about "is it deployed?".

| | **Control plane — API** | **Control plane — web** | **Engine plane** |
|---|---|---|---|
| What it is | `fjcloud-api` (axum) — the billing/metering/admin backend | the SvelteKit `web/` dashboard customers log into at `cloud.{staging.,}flapjack.foo` | The per-tenant **flapjack** search instances (one EC2 VM per tenant index region) that actually serve search |
| Source | this repo (`infra/`) | this repo (`web/`) | upstream **flapjack** binary, baked into an AMI |
| How it's built | `cargo build`, in mirror CI | `npm run build` (Vite → `.svelte-kit/cloudflare`), in mirror CI | Packer image build — [`ops/packer/flapjack-ami.pkr.hcl`](../../ops/packer/flapjack-ami.pkr.hcl) |
| How it ships | dev repo → `debbie sync` → public mirror → mirror CI `deploy-staging` → `ops/scripts/deploy.sh` → SSM → live EC2. See [`infra-deploy.md`](infra-deploy.md). | dev repo → `debbie sync` → public mirror → mirror CI `deploy-staging`'s **`deploy-web` step** → **two** `wrangler pages deploy` runs from one build: `--branch=main` publishes the `flapjack-cloud` Pages **production alias** serving `cloud.flapjack.foo`, then `--branch=staging` publishes the **`staging` branch alias** (`staging.flapjack-cloud.pages.dev`) that `cloud.staging.flapjack.foo` CNAMEs to (single deployer, staging mirror only — see below). | bake AMI → set SSM `/fjcloud/<env>/aws_ami_id` → `fjcloud-api` launches new tenant VMs from that AMI. Per-VM lifecycle in [`deployment-lifecycle.md`](deployment-lifecycle.md). |
| Version readout | `GET /version` → `dev_sha` / `mirror_sha` (a **fjcloud_dev** commit) | the Pages deployment's `canonical_deployment.deployment_trigger.metadata.commit_hash` (the `--commit-hash=$GITHUB_SHA` the `deploy-web` step stamps) | the baked flapjack version inside the AMI; **not** exposed by `/version` |
| "Is the fix live?" check | `bash scripts/deploy_status.sh` (diffs deployed `/version.dev_sha` vs dev `origin/main`) | `bash scripts/launch/wait_for_pages_parity.sh` (polls the Pages API `commit_hash` for the deployment owning the cloud alias) — staging parity now depends on the `--branch=staging` deploy refreshing the staging branch alias | provision a throwaway tenant and assert its EC2 `ImageId == <new AMI id>` |

## The web plane deploys itself now — but it did not for a month (2026-06-05 → 07-07)

The `flapjack-cloud` Cloudflare Pages project has **no git integration** (`source: null` in the Pages
API — Cloudflare is not watching any repo). Before the jul07 web-deploy lane, a web deploy happened
**only** when a human ran `wrangler pages deploy` by hand (`.debbie.toml` marked this
`downstream = "wrangler-manual"`). Mirror CI's `deploy-staging`/`deploy-prod` jobs deployed the
**API plane only**, and `e2e-deployed`'s Pages-parity poll (`scripts/launch/wait_for_pages_parity.sh`)
deliberately exits 0 and *skips* the browser tests on lag rather than red-failing. Net effect: the web
app served at `cloud.{staging.,}flapjack.foo` went **stale for a month** while every pipeline signal
stayed green, and a later verify ran browser lanes against month-old markup and misdiagnosed product bugs.

The fix is the **`deploy-web` step** in `ci.yml`'s `deploy-staging` job: on every staging-mirror CI pass
it builds `web/` once, then runs `wrangler pages deploy .svelte-kit/cloudflare
--project-name=flapjack-cloud` **twice from that one build** — first `--branch=main
--commit-hash=$GITHUB_SHA` (the production alias), then `--branch=staging --commit-hash=$GITHUB_SHA`
(the staging branch alias), each in its own retry loop so a staging-branch hiccup can never regress the
already-live production deploy. Served-commit == mirror-CI-commit for both aliases, so web staleness is
structurally impossible. Once it exists, the parity poll finally has something to bite on: it converges
instead of skipping. Pinned by `scripts/tests/ci_deploy_web_contract_test.sh`.

**Single deployer, two branch deploys — do not add a second deployer.** The two customer domains ride
two different Pages branch aliases: `cloud.flapjack.foo` is served by the `--branch=main` production
alias, and `cloud.staging.flapjack.foo` is a CNAME to the `staging` branch alias
(`staging.flapjack-cloud.pages.dev`), which only refreshes on a `--branch=staging` deploy. Staging/prod
mirrors carry byte-identical synced content, so one deployer running both branch deploys suffices; the
**staging mirror** owns it, and `deploy-prod` must never gain a Pages deploy (a second deployer would
race this one for the same two branch aliases).

**Credential note.** The `deploy-web` step authenticates with a least-privilege, Pages-scoped API
token (Account → Cloudflare Pages → Edit) as `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` — the
Cloudflare-documented auth for `wrangler pages deploy`. The separate `e2e-deployed` parity poll still
uses the legacy global API key; consolidating those two Cloudflare auth surfaces is future work. The
deploy-currency drift alarm's breach rule is API-plane; with `deploy-web` in place, web staleness now
requires the same CI-red condition the alarm already pages on, so no separate web-plane alarm is needed.

## The gotcha that keeps biting

**`api.<env>/version.dev_sha` is the control-plane SHA only.** It is a `fjcloud_dev` commit and never
reports the flapjack engine version. Do **not** use `/version` to decide whether an *engine* (AMI)
change shipped — they are different planes built from different source trees.

## Shipping an engine-AMI change is not just "repoint SSM"

The provisioner reads the AMI id **once at process start**: `AwsProvisionerConfig::from_env()` calls
`required_env("AWS_AMI_ID")` at [`infra/api/src/provisioner/aws.rs:57`](../../infra/api/src/provisioner/aws.rs#L57),
the value is mapped from SSM `aws_ami_id` by [`ops/scripts/lib/generate_ssm_env.sh:54`](../../ops/scripts/lib/generate_ssm_env.sh#L54),
and the provisioner is built once in `main()` and shared as `Arc<dyn VmProvisioner>`. So:

1. **Keep the two AMI facts independent.** Terraform root `api_ami_id` selects the control-plane
   `aws_instance.api` image. Root `flapjack_ami_id` seeds `/fjcloud/<env>/aws_ami_id` only when that
   parameter is created. Terraform owns the parameter's existence/schema and deliberately preserves
   operational value drift with `lifecycle { ignore_changes = [value] }`.
2. **Use the guarded live-value owner.** `ops/scripts/set_flapjack_ami_pointer.sh` is the sole entrypoint
   for changing `/fjcloud/<env>/aws_ami_id`. It validates the AMI identity and compare-and-swap value,
   regenerates `/etc/fjcloud/env`, restarts `fjcloud-api`, and proves the served SHA. Run it without a
   mutation flag first:

   ```bash
   bash ops/scripts/set_flapjack_ami_pointer.sh \
     --env "$ENVIRONMENT" \
     --ami-id "$NEW_FLAPJACK_AMI" \
     --expected-old-ami-id "$CURRENT_FLAPJACK_AMI"
   ```

   Add `--execute` only after this dry-run proves the exact parameter, selected API instance, and
   old-to-new transition. Directly repointing SSM does nothing to a running API because it has the old
   value cached.
3. **Classify the change before you pick the propagation:**
   - *AMI-only* (new flapjack AMI, no `fjcloud-api` code delta) → regenerate env + `systemctl restart fjcloud-api`.
   - *AMI bake that also carried a `fjcloud-api` code change* (e.g. a `provisioner/` fix compiled into the
     api binary) → a bare restart reuses the **old binary** and silently drops the code fix; you must
     **rebuild + redeploy** the control plane (the `debbie sync` path above), not just restart.
4. **Verify with a known-answer probe** before any costly dependent step: provision one throwaway tenant
   and assert the launched instance's `ImageId` equals the new AMI id. (This is the check that
   commit `2cbfb217c` added after a bare-restart mis-classification.)

## Environments

There are two live environments, each with both planes:

- **prod** — `cloud.flapjack.foo` (web) / `api.flapjack.foo` (api); SSM under `/fjcloud/prod/`.
- **staging** — `cloud.staging.flapjack.foo` / `api.staging.flapjack.foo`; SSM under `/fjcloud/staging/`.

(Note: [`infra-deploy.md`](infra-deploy.md)'s older "ONE live environment / no separate prod yet"
topology note predates the 2026-05-13/14 prod provision and is stale on that point; its **SHA model**
section is still accurate and canonical for the control plane.)

## See also

- [`infra-deploy.md`](infra-deploy.md) — canonical control-plane deploy/rollback + cross-repo SHA model.
- [`deployment-lifecycle.md`](deployment-lifecycle.md) — per-tenant VM (engine) provision/stop/terminate.
- [`git_push_with_sync.md`](git_push_with_sync.md) — the dev-repo push-and-sync operator contract.
