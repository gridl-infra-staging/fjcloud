# Engine TLS fleet-rebuild runbook (for FR-5)

**Owner of this document:** FR-3 (`chats/icg/aug05_2am_3_engine_tls_ami_and_first_proven_vm.md`).
**Consumer:** FR-5 (`chats/icg/aug05_2am_5_fleet_rebuild_and_public_port_removal.md`).
**Purpose:** hand FR-5 every value and command it needs to rebuild the engine fleet onto TLS and
remove the public plaintext tcp/7700 rule, without re-deriving prerequisites. FR-5 must still
**re-read every live value below at its own write time** — live state drifts and this document is an
artifact.

> **ROADMAP CORRECTION REQUIRED.** The engine-exposure ROADMAP row's "unauthenticated engine
> dashboard/docs" wording is falsified. FR-3 re-measured both live VMs: every engine path except
> `/health` returns `403` and `/dashboard` returns `404` — there is **no** unauthenticated dashboard
> or docs surface. The real defect is that the **customer data plane is plaintext HTTP on the public
> internet** (`0.0.0.0/0` tcp/7700), because fjcloud hands each customer their engine VM URL directly
> as their index endpoint (`infra/api/src/routes/indexes/mod.rs:126`). FR-9 owns correcting the
> ROADMAP wording; do not edit `ROADMAP.md` from FR-3 or FR-5.

## Live values (re-read 2026-08-05, live-state bundle `docs/live-state/20260805T124618Z/`)

All AWS reads below were performed read-only. Credential note for FR-5: the repo's active
`.secret/.env.secret` currently carries a load-test-scoped IAM user (`flapjack-loadtest`) that
**cannot** read SSM parameters or the DB; FR-3 completed the read-only reads with the `stuart-cli`
admin key at the canonical source-repo path
`/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret.bak.20260727T193111`. FR-5 needs
a key with `ssm:GetParameter`, `ec2:*` provisioning, and DB reachability; confirm the active secret
before starting.

### SSM AMI pointers (source of truth for new launches)

| env | live SSM pointer | AMI name | created | Caddy-bearing? |
| --- | --- | --- | --- | --- |
| staging | `ami-07bff4ef03ac9ad00` | `flapjack-1.0.11-20260805-0901` | 2026-08-05T09:26:01Z | **yes** (FR-3 Stage 3) |
| prod | `ami-01deed1a1e04b3276` | `flapjack-1.0.2-pl13-20260530-0343` | 2026-05-30T04:06:18Z | **no** (pre-Caddy) |

Previous / cross-check AMIs (from `docs/runbooks/evidence/engine-tls/20260805T111633Z_first_tls_vm/SUMMARY.md:24-26`):

| AMI | name | note |
| --- | --- | --- |
| `ami-070b3dfb46c944d7e` | `flapjack-1.0.2-pl13-20260529-0254` | previous staging pointer, replaced by FR-3 |
| `ami-01deed1a1e04b3276` | `flapjack-1.0.2-pl13-20260530-0343` | current prod pointer (unchanged by FR-3) |
| `ami-078228dbe86117d85` | `flapjack-0.1.0-20260408-1901` | oldest; the running shared fleet still launched from this |

Commands used (re-run at FR-5 write time):

```
aws ssm get-parameter --name /fjcloud/staging/aws_ami_id --query Parameter.Value --output text
aws ssm get-parameter --name /fjcloud/prod/aws_ami_id    --query Parameter.Value --output text
aws ec2 describe-images --image-ids <id> --query 'Images[0].{Name:Name,Created:CreationDate,State:State,Arch:Architecture}'
```

**FR-5 must bake/point a Caddy-bearing prod AMI before rebuilding prod.** Staging already points at
one; prod still points at a pre-Caddy image. Prod rebuild through the product path will render
plaintext until the prod pointer is a Caddy AMI.

### Running fleet (live `aws ec2 describe-instances`, 2026-08-05)

Engine (shared) VMs and the two API control-plane hosts:

| instance | Name tag | Env tag | ImageId | public IP | state | role |
| --- | --- | --- | --- | --- | --- | --- |
| `i-072d4333322ffd0eb` | `fj-vm-shared-1ca0d103.flapjack.foo` | (none) | `ami-01deed1a1e04b3276` | 34.228.66.185 | running | **prod floor VM — keep until replacement proven** |
| `i-0c74e2fe5fa24b116` | `fj-vm-shared-3bd2b971.flapjack.foo` | (none) | `ami-078228dbe86117d85` | 54.173.50.206 | running | shared engine (plaintext) |
| `i-00a3b28ba4c00433a` | `fj-vm-shared-f2b9c8a6.flapjack.foo` | (none) | `ami-078228dbe86117d85` | 44.220.133.5 | running | shared engine (plaintext) |
| `i-0b2188437baeeacdf` | `fj-vm-20aa6d79.flapjack.foo` | (none) | `ami-078228dbe86117d85` | 100.27.229.251 | running | shared engine (plaintext) |
| `i-019d556392acdada7` | `fj-vm-shared-480b5169.flapjack.foo` | (none) | `ami-078228dbe86117d85` | 54.163.206.24 | running | shared engine (plaintext) |
| `i-0f9b2a9bd8cbaeeec` | `fj-vm-shared-391f314f.flapjack.foo` | (none) | `ami-078228dbe86117d85` | 54.81.17.133 | running | shared engine (plaintext) |
| `i-0af0ff2e18725b6ba` | `fjcloud-api-prod` | prod | `ami-078228dbe86117d85` | (private) | running | prod API control plane |
| `i-0fbc6d6bbbc8bdc6d` | `fjcloud-api-staging` | staging | `ami-0df77f1c103ce1be7` | (private) | running | staging API control plane |

**Every serving engine VM answers plaintext `http://<ip>:7700` and none is on the Caddy AMI**
(`ami-07bff4ef03ac9ad00`). This is the fleet FR-5 replaces. The prod floor VM
`i-072d4333322ffd0eb` (`fj-vm-shared-1ca0d103`) must never be dropped until a proven TLS replacement
is serving; standing orders keep at least one running healthy prod VM at all times.

`scripts/probe_fleet_dataplane.sh` classified this fleet (via `scripts/probe_live_state.sh`) as
**`ACTION_REQUIRED`, reason `environment_attribution_ambiguous`** — the shared VMs carry no `Env`
tag and cannot be attributed to a single environment by subnet oracle. This is expected data for a
pre-inventory fleet, not a probe failure. FR-5 must attribute each shared VM by other means (SSM
`node_id`/DB `flapjack_url` correlation) before deciding staging vs prod replacement order.

### Database tenant references (read-only via `scripts/launch/ssm_exec_staging.sh`, 2026-08-05)

Queried through the in-VPC API instances (RDS has no public DNS). Schema owners:
`infra/api/src/repos/pg_vm_inventory_repo.rs:76-129` (`list_active`/`list_non_decommissioned`),
`infra/api/src/repos/pg_deployment_repo.rs:20-42` (deployment rows carry a copied `flapjack_url`),
`infra/api/src/repos/pg_tenant_repo.rs:279-299` (`find_by_customer` joins `customer_tenants` to
`customer_deployments`, excluding terminated deployments).

The closing refresh ran each query in `BEGIN READ ONLY` through the environment's running API host.
The systemd unit declares `/etc/fjcloud/env`; the earlier `/etc/fjcloud/api.env` assumption was
probed and rejected before SQL ran. Counts below are one transaction per environment, so their
denominators and reference digests are internally consistent even while load-test rows churn:

| env | transaction UTC | active / non-decommissioned `vm_inventory` | non-terminated `customer_deployments` | joined live `customer_tenants` | non-deleted `customers` |
| --- | --- | --- | --- | --- | --- |
| staging | `2026-08-05 13:28:53.353814` | 7 / 9 | 6,266 | 175 | 493 |
| prod | `2026-08-05 13:28:58.143070` | 16 / 19 | 6,676 | 27 | 129 |

#### Every non-decommissioned inventory reference

`provider VM ref` is the inventory UUID copied into ordinary shared deployments. `EC2 / ImageId`
comes from a same-time `describe-instances` join after normalizing the DB hostname `vm-*` to the EC2
Name tag `fj-vm-*`. `n/a` means a synthetic `bare_metal` fixture row, not an AWS instance.

| env | provider VM ref | provider / status | hostname | `flapjack_url` | EC2 / `ImageId` |
| --- | --- | --- | --- | --- | --- |
| staging | `792e0482-9a57-4268-aa24-34085a6b86fb` | aws / draining | `vm-shared-480b5169.flapjack.foo` | `https://vm-shared-480b5169.flapjack.foo` | `i-019d556392acdada7` / `ami-078228dbe86117d85` |
| staging | `d0c73b11-2565-4d9b-b8e2-2f4ce0fbf8b6` | aws / active | `vm-shared-f2b9c8a6.flapjack.foo` | `http://vm-shared-f2b9c8a6.flapjack.foo:7700` | `i-00a3b28ba4c00433a` / `ami-078228dbe86117d85` |
| staging | `e1a8e33c-97d2-44d8-89bc-c1693ecf464d` | bare_metal / active | `e2e-seed-ad486588` | `http://vm-shared-f2b9c8a6.flapjack.foo:7700` | n/a |
| staging | `e04c5f2a-156d-4590-a32e-fb8dd078c010` | bare_metal / active | `e2e-seed-7d730d84` | `https://api.flapjack.foo` | n/a |
| staging | `0caad9ea-39cb-409d-a150-d298cbf3c35c` | aws / draining | `vm-shared-391f314f.flapjack.foo` | `http://vm-shared-391f314f.flapjack.foo:7700` | `i-0f9b2a9bd8cbaeeec` / `ami-078228dbe86117d85` |
| staging | `3d6aa529-b8c0-4df9-887a-1928e7303619` | bare_metal / active | `e2e-seed-d5269354` | `https://api.staging.flapjack.foo` | n/a |
| staging | `7906319b-5667-4c87-9fe8-2bda3e5814aa` | bare_metal / active | `e2e-seed-d2a7eee8` | `http://localhost:7700` | n/a |
| staging | `f4334538-a08a-4749-be64-422db10fbd1a` | bare_metal / active | `e2e-seed-1e25df76` | `http://localhost:11196` | n/a |
| staging | `34815d2b-0af7-4a55-9cc5-c9980a41aedb` | bare_metal / active | `e2e-seed-8c886301` | `http://vm-shared-1ca0d103.flapjack.foo:7700` | n/a |
| prod | `055030ec-c610-4ea8-90fc-9b494de527d9` | aws / active | `vm-shared-f2b9c8a6.flapjack.foo` | `http://vm-shared-f2b9c8a6.flapjack.foo:7700` | `i-00a3b28ba4c00433a` / `ami-078228dbe86117d85` |
| prod | `d08c72b1-9357-4312-917f-0d82aa2970cc` | bare_metal / active | `e2e-seed-a3418500` | `http://vm-shared-1cc4ec8f.flapjack.foo:7700` | n/a |
| prod | `3a7e0d81-3cca-46a4-a6fc-0a061f5f9699` | bare_metal / active | `e2e-seed-7e2a3b60` | `http://vm-shared-d9dc45a6.flapjack.foo:7700` | n/a |
| prod | `a6ffdf6c-dab4-4fd9-b573-791ba31b253e` | bare_metal / active | `e2e-seed-1aa6a709` | `http://vm-shared-eb0b5c17.flapjack.foo:7700` | n/a |
| prod | `7129ebf7-d55b-4819-b927-30e672745c84` | bare_metal / active | `e2e-seed-fed9f54b` | `http://vm-shared-4d2fd397.flapjack.foo:7700` | n/a |
| prod | `39d351e0-99b1-44f5-8d56-6768b14cc0a2` | bare_metal / active | `e2e-seed-0ba695d6` | `http://vm-shared-26c8d813.flapjack.foo:7700` | n/a |
| prod | `461051de-14a9-462e-ac6f-ff1934c51dd4` | bare_metal / active | `e2e-seed-cae70db6` | `http://vm-shared-835d996d.flapjack.foo:7700` | n/a |
| prod | `da8706a8-d203-4f15-855e-0d38ea2f4ecd` | bare_metal / active | `e2e-seed-71c9a856` | `http://vm-shared-cbe1f8ee.flapjack.foo:7700` | n/a |
| prod | `df262d16-d8c1-4f34-8310-26c554e1a203` | bare_metal / active | `e2e-seed-df0d37c1` | `http://vm-shared-03ff3efa.flapjack.foo:7700` | n/a |
| prod | `48bad97e-4582-4f5e-b534-3168e62f5020` | bare_metal / active | `e2e-seed-e70ec2b4` | `http://vm-shared-e1d3b51e.flapjack.foo:7700` | n/a |
| prod | `d685c0a6-e016-4261-90fd-f5d9737aa1dd` | bare_metal / active | `e2e-seed-35c27951` | `http://vm-shared-2795f91e.flapjack.foo:7700` | n/a |
| prod | `0beb23a5-45be-492d-9fd1-bc63f546d2e4` | bare_metal / active | `e2e-seed-f9c4398c` | `http://vm-shared-dfc3d6e4.flapjack.foo:7700` | n/a |
| prod | `5abb150a-a890-4bcb-bfbe-9724b0d3b4a2` | bare_metal / active | `e2e-seed-5bdd414f` | `http://vm-shared-76672b2a.flapjack.foo:7700` | n/a |
| prod | `a480a5a2-fd89-4e85-a1da-0f5387c95a5c` | bare_metal / active | `e2e-seed-fdf833c1` | `http://vm-shared-4b34a919.flapjack.foo:7700` | n/a |
| prod | `33a687ce-c4e1-45c1-9cff-b1855c633e8d` | bare_metal / active | `e2e-seed-3a9326e3` | `http://vm-shared-f2b9c8a6.flapjack.foo:7700` | n/a |
| prod | `67b73188-86e0-4c80-b573-ec4180a6c205` | aws / draining | `vm-shared-391f314f.flapjack.foo` | `http://vm-shared-391f314f.flapjack.foo:7700` | `i-0f9b2a9bd8cbaeeec` / `ami-078228dbe86117d85` |
| prod | `84f62708-e895-4fd9-a4c6-21f01d811b36` | aws / draining | `vm-shared-480b5169.flapjack.foo` | `http://vm-shared-480b5169.flapjack.foo:7700` | `i-019d556392acdada7` / `ami-078228dbe86117d85` |
| prod | `8afff260-6795-4239-9ac8-0a963746782b` | aws / active | `vm-shared-3bd2b971.flapjack.foo` | `http://vm-shared-3bd2b971.flapjack.foo:7700` | `i-0c74e2fe5fa24b116` / `ami-078228dbe86117d85` |
| prod | `65a5751f-b1a5-43b9-b87d-ae6dec9ce4f7` | aws / draining | `vm-shared-1ca0d103.flapjack.foo` | `http://vm-shared-1ca0d103.flapjack.foo:7700` | `i-072d4333322ffd0eb` / `ami-01deed1a1e04b3276` |

#### Every non-terminated deployment reference group

Rows are grouped only by the complete endpoint reference tuple `(vm_provider, provider_vm_id,
hostname, flapjack_url, status)`. Thus the table enumerates all 10 live reference shapes; `dep rows`
sum to the transaction denominators above. `dep digest` is MD5 of sorted deployment UUIDs. `tenant
digest` is MD5 of the sorted `customer_id/tenant_id/deployment_id` tuples, so the 202 joined tenant
references are reproducible without dumping customer UUIDs into an operator runbook.

| env | provider | provider VM id | status | hostname / `flapjack_url` | dep rows / digest | tenant refs / digest | EC2 / `ImageId` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| staging | aws | `0caad9ea-39cb-409d-a150-d298cbf3c35c` | running | `vm-shared-391f314f.flapjack.foo` / `http://vm-shared-391f314f.flapjack.foo:7700` | 1 / `4b099fd6babcc503b9001397110615b6` | 0 / none | `i-0f9b2a9bd8cbaeeec` / `ami-078228dbe86117d85` |
| staging | aws | `792e0482-9a57-4268-aa24-34085a6b86fb` | provisioning | `vm-shared-480b5169.flapjack.foo` / `https://vm-shared-480b5169.flapjack.foo` | 1 / `90a582d264b2ed22f0ed07d22411754d` | 0 / none | `i-019d556392acdada7` / `ami-078228dbe86117d85` |
| staging | aws | `aws:i-0b2188437baeeacdf` | running | `vm-20aa6d79.flapjack.foo` / `http://vm-20aa6d79.flapjack.foo:7700` | 1 / `f053eedb697bd2581f7b4fcacb7867fc` | 0 / none | `i-0b2188437baeeacdf` / `ami-078228dbe86117d85` |
| staging | aws | `d0c73b11-2565-4d9b-b8e2-2f4ce0fbf8b6` | running | `vm-shared-f2b9c8a6.flapjack.foo` / `http://vm-shared-f2b9c8a6.flapjack.foo:7700` | 6,189 / `60e7c91f404d56be3b6f09c08ef3e2c5` | 98 / `4f19cbcebdeb70839011a7a1eb2b6ea4` | `i-00a3b28ba4c00433a` / `ami-078228dbe86117d85` |
| staging | aws | null | running | null / null | 32 / `38f9a27d813986d53d6dce2eea9a537b` | 31 / `765220180453c4e7069326d9597257e4` | unresolved synthetic rows |
| staging | bare_metal | null | running | null / null | 42 / `b1d74e6e0f4e847cea202b4d81650cec` | 46 / `69de566437c67f590b726ad5632b27d1` | n/a |
| prod | aws | `055030ec-c610-4ea8-90fc-9b494de527d9` | running | `vm-shared-f2b9c8a6.flapjack.foo` / `http://vm-shared-f2b9c8a6.flapjack.foo:7700` | 6,103 / `fe9da7cf21520de18cf2f6f5b6c22af3` | 13 / `28ea1ae60d539bb13438515606b488af` | `i-00a3b28ba4c00433a` / `ami-078228dbe86117d85` |
| prod | aws | null | failed | null / null | 568 / `e745959b24409b2d8659234c2ed6d2b4` | 0 / none | unresolved failed rows |
| prod | bare_metal | `d08c72b1-9357-4312-917f-0d82aa2970cc` | provisioning | `e2e-seed-a3418500` / `http://vm-shared-1cc4ec8f.flapjack.foo:7700` | 4 / `b37eb94a10d270151c9843616737e63b` | 0 / none | n/a |
| prod | bare_metal | null | running | null / null | 1 / `db2dac5c796b1539eb87380c7846576f` | 14 / `3d49b2ca0b11d85b5a2ecbb6d1fe2c76` | n/a |

The tenant IDs behind those tuple digests are synthetic canary, `e2e-*`, `cold-customer-*`,
`demo-*`, `stage*`, and debug identifiers. The active-customer domain census was also re-run in the
same read-only lane: staging's only `flapjack.foo` address is `e2e-vlm-test@flapjack.foo`; all other
domains are test-owned (`test.flapjack.foo`, `e2e.griddle.test`, `example.*`, `*.invalid`, or
single-letter junk). Prod contains only `test.flapjack.foo`, `e2e.griddle.test`, and `example.*`.

**These are not real customers.** Every non-test-pattern customer email resolves to a synthetic
domain (`test.flapjack.foo`, `example.com`, `example.test`, `playwright.flapjack.foo`,
`diagtest.flapjack.foo`, `synthetic-seed.invalid`, single-letter junk like `a.a`). There are **zero
genuine paying tenants** — consistent with the lane's stated posture ("fjcloud has no customers").

**Two facts that change how FR-5 must treat the DB:**

1. **`vm_inventory` partially tracks the live serving fleet, but does not own environment
   attribution.** Normalizing `vm-*` to the EC2 tag prefix `fj-vm-*` correlates five serving VMs.
   Three (`f2b9c8a6`, `391f314f`, `480b5169`) appear in *both* environment databases, while
   `3bd2b971` and the prod floor `1ca0d103` appear only in prod. The sixth live VM (`20aa6d79`) is a
   direct staging deployment reference with no inventory row. FR-5 therefore cannot drive the
   rebuild from either environment's `vm_inventory` alone; it must join both databases to live EC2.
2. **The DB is dominated by load-test churn.** Deployment/inventory counts change between reads.
   FR-5 must not treat a single `vm_inventory` snapshot as a stable work-list; take the live EC2
   fleet as the authoritative set of endpoints to preserve.

Stored `flapjack_url` scheme distribution (non-decommissioned/non-terminated snapshot): staging
inventory is 6×http/3×https and deployments are 6,191×http/1×https/74×null; prod inventory is
19×http/0×https and deployments are 6,107×http/0×https/569×null. No genuine tenant depends on a
stored `https` URL.

## Replacement order FR-5 must follow

1. **Product-path provisioning is FR-5 Stage 1 and has never been exercised.** FR-3 launched its
   proof instance **directly** (see next section) and **never provisioned through the deployed
   product path**. FR-5's first act is the first product-path proof against the freshly-deployed API.
2. **Gate on deployed-API freshness before any product-path launch.** Confirm the deployed staging
   API renderer is current: `curl -fsS https://api.staging.flapjack.foo/version`, read `dev_sha`,
   require `git merge-base --is-ancestor "$dev_sha" origin/main` to exit `0` **and** `$dev_sha` to
   differ from `a384a42e6375dcfe04ef8360d9f566f62dfe301f` (the renderer that was deployed during
   FR-3). Rebuilding through a stale control plane proves the wrong binary.
3. **Staging first.** Prove one staging VM through the product path serves customer search over
   public TLS, then replace the staging shared fleet, keeping at least one reachable staging endpoint
   at every step.
4. **Prod second, and only after a Caddy prod AMI exists.** Point `/fjcloud/prod/aws_ami_id` at a
   Caddy-bearing AMI, then replace prod VMs one at a time, **preserving the prod floor VM
   `i-072d4333322ffd0eb` until a replacement is proven** and never dropping below one running healthy
   prod VM.
5. **Remove `flapjack_public_data_plane` (tcp/7700 `0.0.0.0/0`) last**, in the same commit that
   inverts the three static guards (below). Removing it before every serving VM answers on 443 takes
   the only customer data plane offline.

## Canonical Stage 3 proof recipe (single owner — do not duplicate the transcript)

The full command transcript for direct launch, render, TLS/ACME proof, authenticated HTTPS search,
and teardown lives in **`docs/runbooks/evidence/engine-tls/20260805T111633Z_first_tls_vm/SUMMARY.md:40-203`**.
That file is the single owner of the proof recipe; FR-5 reuses the *operator steps and parameters*,
not a second copy. The reusable steps and their live inputs:

- **Render user-data from the owner** `infra/api/src/services/provisioning/auto_provision.rs`
  (`build_user_data`), driven by the ignored owner test
  `cargo test -p api --lib emit_aws_user_data_for_operator -- --ignored` with
  `FJCLOUD_USER_DATA_*` env inputs (customer id, node id, region, hostname). FR-3 used
  `FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED=true` so the renderer selects `https`.
- **Launch inputs read live from SSM** (staging): subnet `subnet-03e3357684f12dcc8`, security group
  `sg-047734af5235c69af`, key pair `fjcloud-api-staging`, instance profile
  `fjcloud-instance-profile`, DNS domain `staging.flapjack.foo`.
- **DNS**: create a Cloudflare A record for the instance hostname so ACME HTTP-01 completes; verify
  `dig +short <hostname> A @1.1.1.1` returns the instance IP.
- **TLS acceptance oracle** (from outside AWS, no `-k`): `curl https://<hostname>/health` → `200`;
  `openssl s_client` shows a Let's Encrypt issuer and a SAN matching the hostname; an authenticated
  search against an index created directly on the engine returns the exact expected document.
- **Plaintext still answers** (`http://<ip>:7700/health` → `200`) until FR-5 removes the rule.
- **Teardown**: terminate the instance, delete the DNS A record, delete any SSM parameter the
  cloud-init wrote (`/fjcloud/<node_id>/api-key`), and confirm no `vm_inventory` row was created.

Note the direct-launch reason and the AMI-pointer owner: `scripts/tests/set_flapjack_ami_pointer_test.sh`
pins the guarded pointer-move owner FR-5 reuses for the prod pointer; FR-3's Stage 3 also fixed a
restart-readiness race in that owner (commit `f6d33f5ac`).

## Terraform static guards FR-5 must invert (same commit as the rule removal)

These currently assert the public rule **exists** and will go red the instant it is removed. FR-5
must flip them so the contract becomes "no public tcp/7700 ingress rule exists outside fixtures, and
a reintroduced one is rejected."

- `ops/terraform/tests_stage1_static.sh:35-41` — asserts exactly one
  `aws_vpc_security_group_ingress_rule.flapjack_public_data_plane` with `0.0.0.0/0`, `7700`, `tcp`,
  unconditional (no `count`/`for_each`/`var.env`).
- `ops/terraform/tests_stage1_static.sh:54` — the repo-wide resource-count assertion (must be exactly
  one today; must become zero).
- `ops/terraform/tests_iac_validation_static.sh:123` — requires `validate_all.sh` to *name* the
  public data-plane exception; after removal it must instead reject a reintroduced rule.
- Fixtures under `ops/terraform/fixtures/` drive the detector and must flip:
  `ops/terraform/fixtures/safe/named_public_data_plane.tf` (flips from "safe" to "must be rejected"),
  reusing the existing negative fixtures `wrong_name_public_7700/`, `wrong_protocol_public_data_plane/`,
  and `wrong_range_public_data_plane/` which already prove the detector sees variants.

Do **not** touch the tcp/80 (`flapjack_acme_http`) or tcp/443 (`flapjack_customer_https`) rules, or
the sg-to-sg `flapjack_from_api` 7700 rule — only `flapjack_public_data_plane` is removed.

## `flapjack_url` scheme decision

Ownership today:

- `infra/api/src/services/provisioning/auto_provision.rs:335-355` — `shared_vm_draft` mints the draft
  URL via `engine_base_url`.
- `infra/api/src/services/provisioning/auto_provision.rs:700-720` — `engine_base_url` chooses
  `https://<served_hostname>` **only** when `FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED` is true, the
  provider is supported, and `caddy_runtime_for_provider` resolves `Available`; otherwise it returns
  `http://<hostname>:7700`.
- `infra/api/src/services/provisioning/auto_provision.rs:217-229` — `register_shared_vm_inventory`
  persists that `flapjack_url` into `vm_inventory`.
- `infra/api/src/repos/pg_deployment_repo.rs:20-42` — the deployment row copies `vm.flapjack_url`.
- `infra/api/src/routes/admin/indexes.rs:40-79` — seed-index validation accepts **either** `http` or
  `https` (`:51`), so both schemes are already legal at the read boundary.

**Decision the evidence supports: do NOT run a data migration to rewrite stored `flapjack_url` rows.**
Rationale: (1) there are zero genuine tenants — every stored row is synthetic load-test/e2e data, so
there is nothing customer-facing to preserve or rewrite; (2) `vm_inventory` only partially tracks
the live serving fleet and does not own environment attribution, so a bulk row-rewrite would edit
cross-environment churn rows rather than an authoritative endpoint list; (3) the correct
long-term behavior is that new TLS-capable VMs are *derived* as `https` at mint time by the existing
owner (`engine_base_url`) when `FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED=true` and Caddy is available —
the derivation owner is already correct, so the fix is to ensure the deployed API runs with that flag
and Caddy AMIs, not to add a second migration path. FR-5 should confirm
`FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED` is set in the deployed API environment and that new rows mint
`https`; the old synthetic rows can be left to decommission naturally. If FR-5 finds any genuine
tenant row at its write time (re-run the domain characterization), revisit this decision.

## SSH `authorized_keys` credential-rotation residual

`docs/launch/deployed_proof_refresh_spec.md:258-305` records the open residual: instances launched
before **2026-07-17T20:29Z** may still carry the superseded SSH public key in `authorized_keys`, and
**no repo-owned command performs the per-instance absence proof today** — `scripts/probe_fleet_dataplane.sh`
classifies network posture, not host key contents. A full fleet rebuild replaces every such instance,
but FR-5 must **prove** it, not assume it.

FR-5 creates a single owner for this check: a read-only `scripts/security/probe_authorized_keys_absence.sh`
(SSM `send-command` reading `authorized_keys` fingerprints against the superseded public key) or an
equivalent replacement-manifest check, and proves per pre-cutoff instance either (a) the superseded
key is absent, or (b) the instance was replaced by the rebuild. Then rerun the canonical mirror-leak
credential scan to confirm no `LIVE_CREDENTIALS_PRESENT`.

## Renderer-delta / product-path caveat (do not skip)

FR-3 **never provisioned through the deployed product path.** It rendered user-data with *this
worktree's* `cloud_init.rs` and launched the proof instance directly, because the deployed staging
renderer differs materially from `main`. Measured at this stage:

```
$ git diff --stat a384a42e6..origin/main -- infra/api/src/provisioner/cloud_init.rs
 infra/api/src/provisioner/cloud_init.rs | 116 +++++++++++++++++++++++++++-----
 1 file changed, 100 insertions(+), 16 deletions(-)
```

100 insertions, 16 deletions between the deployed staging binary
(`a384a42e6375dcfe04ef8360d9f566f62dfe301f`) and `origin/main`. A product-path proof taken during
FR-3 would have proven a renderer that FR-6 is about to replace. Therefore **FR-5 Stage 1 owns the
first product-path provisioning proof against the freshly-deployed API**; a successor that assumes
FR-3 already proved the product path would skip the only test of the code that actually ships.
