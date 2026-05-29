# Deploy surfaces — the two deploy planes

> **Created:** 2026-05-29. **Why this doc exists:** "how does a change reach customers?" has *two
> different answers* in this repo depending on which surface the change touches, and conflating them
> has bitten more than one agent (a prior agent built a wrong `/version`-based engine-detection gate;
> a later agent mis-classified an AMI bake as env-only-restart instead of rebuild+redeploy). This is
> the stable home for that distinction — previously it lived only inside a launch-orchestration
> `CORRECTED` block.

fjcloud ships two independently-deployed surfaces. A single feature/fix usually lives in exactly one
of them; know which before you reason about "is it deployed?".

| | **Control plane** | **Engine plane** |
|---|---|---|
| What it is | `fjcloud-api` (axum) + the SvelteKit `web/` dashboard — the billing/metering/admin app customers log into | The per-tenant **flapjack** search instances (one EC2 VM per tenant index region) that actually serve search |
| Source | this repo (`infra/`, `web/`) | upstream **flapjack** binary, baked into an AMI |
| How it's built | `cargo build` (api) + `npm run build` (web), in mirror CI | Packer image build — [`ops/packer/flapjack-ami.pkr.hcl`](../../ops/packer/flapjack-ami.pkr.hcl) |
| How it ships | dev repo → `debbie sync` → public mirror → mirror CI → `ops/scripts/deploy.sh` → SSM → live EC2. See [`infra-deploy.md`](infra-deploy.md). | bake AMI → set SSM `/fjcloud/<env>/aws_ami_id` → `fjcloud-api` launches new tenant VMs from that AMI. Per-VM lifecycle in [`deployment-lifecycle.md`](deployment-lifecycle.md). |
| Version readout | `GET /version` → `dev_sha` / `mirror_sha` (a **fjcloud_dev** commit) | the baked flapjack version inside the AMI; **not** exposed by `/version` |
| "Is the fix live?" check | `bash scripts/deploy_status.sh` (diffs deployed `/version.dev_sha` vs dev `origin/main`) | provision a throwaway tenant and assert its EC2 `ImageId == <new AMI id>` |

## The gotcha that keeps biting

**`api.<env>/version.dev_sha` is the control-plane SHA only.** It is a `fjcloud_dev` commit and never
reports the flapjack engine version. Do **not** use `/version` to decide whether an *engine* (AMI)
change shipped — they are different planes built from different source trees.

## Shipping an engine-AMI change is not just "repoint SSM"

The provisioner reads the AMI id **once at process start**: `AwsProvisionerConfig::from_env()` calls
`required_env("AWS_AMI_ID")` at [`infra/api/src/provisioner/aws.rs:57`](../../infra/api/src/provisioner/aws.rs#L57),
the value is mapped from SSM `aws_ami_id` by [`ops/scripts/lib/generate_ssm_env.sh:54`](../../ops/scripts/lib/generate_ssm_env.sh#L54),
and the provisioner is built once in `main()` and shared as `Arc<dyn VmProvisioner>`. So:

1. **Repointing SSM `/fjcloud/<env>/aws_ami_id` alone does nothing** to a running `fjcloud-api` — it has
   the old value cached. You must regenerate `/etc/fjcloud/env` and **restart** `fjcloud-api` for the
   new AMI to take effect.
2. **Classify the change before you pick the propagation:**
   - *AMI-only* (new flapjack AMI, no `fjcloud-api` code delta) → regenerate env + `systemctl restart fjcloud-api`.
   - *AMI bake that also carried a `fjcloud-api` code change* (e.g. a `provisioner/` fix compiled into the
     api binary) → a bare restart reuses the **old binary** and silently drops the code fix; you must
     **rebuild + redeploy** the control plane (the `debbie sync` path above), not just restart.
3. **Verify with a known-answer probe** before any costly dependent step: provision one throwaway tenant
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
