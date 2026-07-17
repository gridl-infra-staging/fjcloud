# RDS Password Rotation Gap Specification

## Status and scope

Status: open; escalation recorded 2026-07-17. No credential was rotated by this
decision package.

The pinned producer is
`docs/runbooks/evidence/mirror-leak-scan/20260716T233251Z_credential_scan/`.
Its tracked `verdict.txt` is `LIVE_CREDENTIALS_PRESENT`; its 37 audit sites have
a one-to-one closed-set classification; and its live set contains exactly the
prod and staging RDS password rows plus the prod and staging API SSH private-key
rows. The live set contains no `aws-access-token` rule and no
`AWS_ACCESS_KEY_ID` inventory reference. If that producer changes, return to the
classification and inventory owner before using this specification.

This lane does not retrieve a leaked value from committed or public history. It
also does not run Terraform, change RDS or SSM directly, or restart a runtime.

## Exact blocker

The canonical password rotation requires an authorized environment-mutation
operator to claim each environment's Terraform backend, apply an environment-
specific saved plan, and coordinate the refresh of every database consumer.
This documentation-only lane cannot perform those environment mutations. A
direct `aws rds modify-db-instance` or `aws ssm put-parameter` would fork the
live system from Terraform and is prohibited.

## Canonical ownership and consumer graph

- `ops/terraform/data/main.tf::random_password.db` issues the password.
- `ops/terraform/data/main.tf::aws_db_instance.main` installs it in RDS.
- `ops/terraform/data/main.tf::aws_ssm_parameter.db_password` and
  `ops/terraform/data/main.tf::aws_ssm_parameter.database_url` publish the
  derived runtime values at `/fjcloud/<env>/db_password` and
  `/fjcloud/<env>/database_url`.
- `ops/scripts/lib/generate_ssm_env.sh` maps `database_url` to `DATABASE_URL` in
  `/etc/fjcloud/env`. The API, aggregation job, and retention job consume that
  file through their units under `ops/systemd/`.
- Customer EC2 instances hydrate `/etc/flapjack/env` and
  `/etc/fjcloud/metering-env` from `/fjcloud/<env>/database_url` through
  `ops/user-data/bootstrap.sh`; these are the Flapjack and metering consumers.
  Updating only the control-plane API host is therefore an incomplete cutover.

ACM certificate resources and `ops/terraform/dns/main.tf` do not issue or
consume this database credential and are unrelated to this rotation.

## Dispatch contract

Dispatch to the authorized Terraform environment-mutation operator responsible
for `ops/terraform/_shared`, using
`docs/runbooks/infra-terraform-apply.md` as the backend and variable contract.
That operator must execute staging to completion before starting prod.

For each environment, the operator must:

1. Establish the expected AWS account, backend bucket, state key, and lock
   table; capture only redacted identity and state metadata.
2. Confirm no aggregation or retention invocation is in flight and enumerate
   every running control-plane and customer EC2 consumer before mutation.
3. Obtain the current password only from the authorized live SSM/Terraform
   source into a mode-`0600`, non-repository temporary channel for rollback and
   old-password rejection proof. Never read the leaked plans or Git history.
4. Create a saved plan with `-replace=module.data.random_password.db` and
   `-out=<protected-plan>`. Saved plans and JSON renderings can contain secrets:
   keep them outside the repository at mode `0600`, parse them without logging
   sensitive values, and remove them after the evidence result is reduced to
   metadata.
5. Reject the plan unless its complete resource-change set is limited to:
   `module.data.random_password.db` replacement,
   `module.data.aws_db_instance.main` in-place update,
   `module.data.aws_ssm_parameter.db_password` in-place update, and
   `module.data.aws_ssm_parameter.database_url` in-place update. The random
   password is the only allowed delete/create action. No other replacement,
   deletion, or unrelated drift is allowed.
6. Apply exactly the reviewed saved plan, never an unreviewed regenerated plan.
7. Regenerate `/etc/fjcloud/env` and restart or re-invoke the API, aggregation,
   and retention units under their normal deploy ownership. Refresh both
   `/etc/flapjack/env` and `/etc/fjcloud/metering-env` on every customer VM,
   then restart the Flapjack and metering services. Do not assume
   `generate_ssm_env.sh` alone refreshes `/etc/flapjack/env`.
8. Complete all verification below before discarding the protected rollback
   material or proceeding from staging to prod.

If the allowlist cannot accommodate the actual plan, stop and amend the
Terraform owner or this reviewed specification; do not widen the allowlist at
the apply prompt.

## Verification and evidence

The environment-mutation owner must return a dated, redacted evidence bundle
that proves:

- the saved-plan resource/action set matched the allowlist and the exact saved
  plan was applied;
- RDS is available and both SSM parameters advanced consistently;
- a new-credential connection succeeds from the API host, an aggregation-job
  invocation, a retention-job invocation, and every customer-VM
  Flapjack/metering locality;
- the old password, loaded from the authorized pre-cutover source without
  echoing or placing it in repository artifacts, is rejected by RDS while the
  new password succeeds;
- API health, aggregation output, retention dry-run/read behavior, Flapjack
  health, and metering freshness remain green; and
- no evidence file contains a connection string, password, Terraform sensitive
  value, or unredacted command output.

Issuing-system deactivation remains open until this proof exists for both
environments. An SSM version change or successful Terraform apply alone is not
deactivation proof.

## Rollback criteria

Before applying, the operator must have a Terraform-owned rollback path to the
authorized pre-cutover value and must prove it also has a closed saved-plan
allowlist. Do not apply if Terraform cannot express that rollback without a
direct RDS/SSM mutation.

Rollback the current environment immediately if RDS fails to become available,
the RDS and SSM values diverge, any named consumer cannot authenticate, the
focused health/freshness gates fail, or old-password rejection cannot be proven.
After rollback, regenerate every named consumer environment again and prove the
previous credential works. Keep the incident open because rollback restores a
known-exposed credential; do not proceed to prod until staging has a completed
green cutover.
