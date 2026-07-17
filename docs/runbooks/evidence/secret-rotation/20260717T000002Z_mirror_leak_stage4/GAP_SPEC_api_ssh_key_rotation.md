# API SSH Key Rotation Gap Specification

## Status and scope

Status: open; escalation recorded 2026-07-17. No key was rotated by this
decision package.

The pinned source is
`docs/runbooks/evidence/mirror-leak-scan/20260716T233251Z_credential_scan/`.
The two private-key findings resolve to the leaked-plan resource address
`module.compute.tls_private_key.api_ssh`. They are EC2 emergency-SSH keys, not
TLS certificate keys. This lane does not retrieve private material from the
leaked plans or Git history, mutate AWS or an instance, replace a certificate,
or restart a fleet.

## Canonical ownership and attachment graph

- `ops/terraform/compute/main.tf::tls_private_key.api_ssh` issues the ED25519
  key material.
- `ops/terraform/compute/main.tf::aws_key_pair.api_ssh` registers the public key
  as `fjcloud-api-<env>` in EC2.
- `ops/terraform/compute/main.tf::aws_instance.api` attaches that key-pair name
  to the staging or prod control-plane instance.
- `ops/terraform/_shared/main.tf` passes the same key-pair name to the runtime
  parameter owner. `infra/api/src/provisioner/aws.rs` uses
  `AWS_KEY_PAIR_NAME` when launching customer EC2 instances, so every running
  customer instance with that `KeyName` is also in the authorization-path
  inventory.
- `ops/iam/fjcloud-instance-role.tf` attaches
  `AmazonSSMManagedInstanceCore`; normal access and the safe mutation channel
  are SSM Session Manager, while SSH is emergency access only.

Replacing the EC2 key-pair object does not rewrite an existing instance's
`authorized_keys`. Rotation is incomplete until the old public key is absent
from every attached control-plane and customer instance as well as EC2.

ACM certificate resources and `ops/terraform/dns/main.tf` are unrelated. Do not
reissue certificates and do not introduce a second SSH-key store.

## Exact blocker and dispatch contract

The canonical rotation needs an authorized environment-mutation operator to
replace the Terraform-managed key pair and update the authorization path of
every attached instance while preserving SSM access. This documentation-only
lane cannot perform those mutations.

Dispatch to the authorized Terraform and fleet environment-mutation operator
for `ops/terraform/_shared`, staging first and prod only after staging closes.
For each environment, that operator must:

1. Enumerate the control-plane instance and every running customer EC2 instance
   whose `KeyName` is `fjcloud-api-<env>`. Record a redacted instance inventory
   and fail closed if any attached instance is omitted.
2. Prove SSM command/session access to every inventoried instance before
   touching the key. An SSM-unmanaged or unreachable instance blocks the
   rotation until its access seam is repaired.
3. Obtain the old public-key fingerprint only from the authorized live EC2,
   Terraform, or instance authorization source. Never recover either key from
   committed/public history. Keep any private material in the existing
   Terraform protected-state boundary; do not commit or copy it into evidence.
4. Create a mode-`0600`, non-repository saved plan using
   `-replace=module.compute.tls_private_key.api_ssh`. Reject it unless the
   complete change set is limited to replacement of
   `module.compute.tls_private_key.api_ssh` and
   `module.compute.aws_key_pair.api_ssh`. No instance replacement, ACM change,
   DNS change, unrelated drift, or additional key store is allowed. Apply
   exactly that reviewed saved plan.
5. Through the existing SSM channel, install the new public key and remove the
   old public key from every inventoried instance's actual SSH authorization
   path. Preserve file ownership, mode, unrelated authorized keys, and a live
   SSM session throughout. Do not assume the EC2 key-pair replacement performs
   this step.
6. Verify the new-key emergency-access canary through a protected operator
   channel, then prove SSM still works. Private keys, public-key bodies, and
   shell commands containing key material must not enter the evidence bundle.
7. Finish the absence and rollback checks below before proceeding from staging
   to prod.

If the plan contains a wider change or the instance inventory cannot be closed,
stop and return to the canonical Terraform/fleet owner rather than improvising
a direct EC2 key-pair mutation.

## Verification and evidence

The environment-mutation owner must return a dated, redacted evidence bundle
for each environment that proves:

- the saved-plan resource/action set matched the allowlist and the exact saved
  plan was applied;
- the EC2 key pair has the new fingerprint and not the old fingerprint;
- every inventoried control-plane and customer instance reports the new public-
  key fingerprint present and the old fingerprint absent from its effective
  SSH authorization path;
- the new emergency SSH key authenticates through an approved canary without
  exposing key material;
- SSM Session Manager/Run Command access succeeds before, during, and after the
  authorization update; and
- the evidence contains only fingerprints, counts, resource addresses, redacted
  instance identifiers, outcomes, and timestamps.

Issuing-system deactivation remains open until EC2 absence and instance-path
absence are both proven for staging and prod. Terraform apply success alone is
not sufficient.

## Rollback criteria

Before applying, retain the old public key and rollback inputs only from an
authorized live source in a protected, non-repository channel. Roll back the
current environment if any instance loses SSM access, the new key cannot pass
the emergency-access canary, any attached instance cannot be updated, or an
unrelated resource changes.

Rollback must use SSM to restore the prior authorized key on every touched
instance and the reviewed Terraform path to restore the prior EC2 key-pair
registration. Re-prove SSM and old-key access afterward. Because rollback
restores a known-exposed key, keep the incident open and do not advance to prod.
