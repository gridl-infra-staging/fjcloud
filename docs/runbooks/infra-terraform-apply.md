# Terraform Apply Procedure

Staging and production apply procedure for fjcloud infrastructure.

Root module: `ops/terraform/_shared/main.tf`
Backend: S3 (`fjcloud-tfstate-<env>`) + DynamoDB lock (`fjcloud-tflock`)

## Guarded IAM rollout — SES send-events log-read policy

For the `fjcloud-ses-send-events-read` inline policy on the staging instance
role, **do not** use the general plan/apply/rollback steps below. That policy is
rolled out only through the guarded CLI, which binds the exact target, refuses
any plan that is not the single intended change, and proves the grant on-host
before reporting success. The manual Terraform procedure in the rest of this
runbook is the fallback for everything else and is secondary to this path for
this policy.

Canonical invocation (from the repo root, with an authorized staging credential
file already present):

```bash
scripts/launch/apply_ses_log_read_policy.sh \
  --credential-env-file=/absolute/path/to/.env.secret \
  --artifact-dir=<repo-relative-dir>

# Confirm a prior apply, or gate the live rerun, without any mutation:
scripts/launch/apply_ses_log_read_policy.sh \
  --credential-env-file=/absolute/path/to/.env.secret \
  --artifact-dir=<repo-relative-dir> --verify-only
```

`--credential-env-file` must be an **absolute** path; `--artifact-dir` must be
**repo-relative**. The CLI clears every ambient `AWS_*` selector before loading
the credential file, then requires the caller to be account `213880904778`.

**Safe-plan boundary.** Policy shape is owned only by
`ops/iam/fjcloud-instance-role.tf`; the CLI derives the intended shape from that
owner (never a second authored JSON, never an `aws iam put-role-policy`
fallback). It applies only when the saved `terraform plan` changes exactly one
resource — the `fjcloud-ses-send-events-read` inline policy — with a `create` or
`update` action. A no-change plan (rc 0) is accepted only when the live policy
already matches that exact least-privilege shape. Any broader drift, extra
resource, or destroy action is refused with no mutation.

**Exit / status contract.** Every run writes `summary.json` to the artifact dir
(source SHA, apply method, plan denominator/actions, bound instance/profile/role,
the four API-probe statuses, stream denominator, propagation attempts, and
reconciliation/cleanup disposition). Exit `0` accompanies `status` `success` or
`verify_only_complete`. Exit `1` accompanies a refusal — e.g. `wrong_account`,
`instance_count_not_one`, `profile_role_not_unique`, `onhost_role_mismatch`,
`policy_mismatch_refused`, `unsafe_plan_refused`, `state_reconciliation_failed`,
or `persistent_authorization_denial` (the policy stayed exact but the grant had
not propagated after the five-minute probe window). Exit `2` is CLI misuse
(bad flags), before any artifact dir exists.

**Rollback rule.** There is nothing to undo on a refusal — a mismatched or broad
live policy is rejected *before* any change. Reconciliation reads Terraform state
first: if `terraform state list` cannot read the state it fails closed with
`state_reconciliation_failed` and performs no import (an unreadable state is never
treated as "role absent"). If the role is bound in AWS but missing from Terraform
state, the CLI proves role identity and EC2 trust, snapshots state at chmod `0600`,
imports by role name, and rolls the imported address back out of state whenever the
run then fails closed — whether the post-import plan is not the single intended
policy change *or* `terraform apply` of the saved plan fails. The decoded prior
policy is retained at chmod `0600` in the artifact dir as evidence; the transient
derived policy JSON is deleted immediately after use. On persistent authorization
denial the least-privilege policy is left in place (never broadened) and the gap is
reported for follow-up.

**`--verify-only` transition use.** Runs every read-only proof and all four
on-host API probes with zero writes. Use it to confirm a prior apply landed and
as the transition check before the live rerun.

## Prerequisites

- Terraform installed (check with `terraform version`)
- AWS CLI configured with appropriate credentials
- Bootstrap resources created (see `ops/BOOTSTRAP.md`)
- `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ZONE_ID` loaded for the public DNS zone.
  For `flapjack.foo`, staging scripts also accept
  `CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO` and
  `CLOUDFLARE_ZONE_ID_FLAPJACK_FOO`.

## 1. Initialize

```bash
cd ops/terraform/_shared

terraform init \
  -backend-config="bucket=fjcloud-tfstate-staging" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=fjcloud-tflock"
```

For prod, use `fjcloud-tfstate-prod`:

```bash
terraform init \
  -backend-config="bucket=fjcloud-tfstate-prod" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=fjcloud-tflock"
```

Expected output:
```
Terraform has been successfully initialized!
```

**Note**: Re-run `terraform init` when switching between staging and prod, or after adding new modules/providers.

## 2. Plan

Source the two AMI values independently: `api_ami_id` is the running control-plane
instance's `ImageId`, while `flapjack_ami_id` is the current
`/fjcloud/<env>/aws_ami_id` value.

```bash
terraform plan \
  -var="env=staging" \
  -var="api_ami_id=ami-0123456789abcdef0" \
  -var="flapjack_ami_id=ami-0fedcba9876543210" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}" \
  -var='alert_emails=["ops@flapjack.foo"]'
```

Review the plan output carefully:
- Check resource additions, changes, and destructions
- Verify no unexpected deletions
- Confirm environment-specific values are correct

Canary runtime contract notes (post-Stage-5 handoff boundary):
- Keep `canary_schedule.enabled = false` during initial `terraform plan/apply` until the canary image has been published and operators are ready to activate runtime execution.
- Publish the canary image to the monitoring-owned ECR repository first, then set `canary_image.tag` to the published tag in your plan/apply inputs.
- Example var overrides for initial rollout prep:
  ```bash
  -var='canary_image={tag="pending-publication"}' \
  -var='canary_schedule={expression="rate(15 minutes)",enabled=false}'
  ```
- Runtime activation (setting `canary_schedule.enabled=true`) is a separate operator action after image publication and post-apply verification.

Stage 6 rollout caveats (observed during initial heartbeat-alarm landing):
- AWS Lambda with `package_type = "Image"` validates `image_uri` at create time. When the Lambda resource does not yet exist in state, run a **targeted apply** that includes only the ECR repository, lifecycle policy, and the heartbeat alarm — skip the Lambda — so the apply does not fail on the not-yet-published image:
  ```bash
  terraform apply <vars> \
    -target=module.monitoring.aws_ecr_repository.customer_loop_canary \
    -target=module.monitoring.aws_ecr_lifecycle_policy.customer_loop_canary \
    -target=module.monitoring.aws_cloudwatch_metric_alarm.api_heartbeat_missing
  ```
  Then publish the image (`ops/terraform/publish_customer_loop_canary_image.sh staging`) and re-run a full `terraform apply` with the published `canary_image.tag`.
- Lambda only accepts **docker schema-2 manifests**. Modern Docker (BuildKit, ≥25) emits OCI-index manifests by default; loading those into Lambda fails with `InvalidParameterValueException: image manifest, config or layer media type ... is not supported`. The publish helpers (`publish_customer_loop_canary_image.sh`, `publish_support_email_canary_image.sh`) build with `docker buildx --platform linux/arm64 --provenance=false --push` to produce the required manifest format.
- `alert_emails` is forwarded to the monitoring module via `local.alert_emails_normalized` (a static `trimspace` over `var.alert_emails`), so the `for_each = toset(var.alert_emails)` planning path on `aws_sns_topic_subscription.email` resolves at plan time. The earlier workaround (`terraform apply -target=terraform_data.prod_alert_emails_guard`) is no longer required: the `terraform_data.prod_alert_emails_guard` resource still runs the prod-non-empty `precondition`, but its `output` is no longer wired into module inputs. Pass `-var='alert_emails=[…]'` directly on the first apply.

Expected output:
```
Plan: X to add, Y to change, Z to destroy.
```

## 3. Apply

```bash
terraform apply \
  -var="env=staging" \
  -var="api_ami_id=ami-0123456789abcdef0" \
  -var="flapjack_ami_id=ami-0fedcba9876543210" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}" \
  -var='alert_emails=["ops@flapjack.foo"]'
```

Type `yes` when prompted to confirm.

Expected output:
```
Apply complete! Resources: X added, Y changed, Z destroyed.
```

## 4. Adopt Existing RDS PostgreSQL Log Group (Before Apply)

When `enabled_cloudwatch_logs_exports = ["postgresql"]` is active, RDS can create
the CloudWatch log group before Terraform manages it. Terraform now owns:
`module.data.aws_cloudwatch_log_group.rds_postgresql`.

If the log group already exists, import it before `terraform apply`.
Expected naming shape: `/aws/rds/instance/fjcloud-<env>/postgresql`.

Run from `ops/terraform/_shared`:

```bash
# Staging
terraform import \
  -var="env=staging" \
  -var="api_ami_id=ami-0123456789abcdef0" \
  -var="flapjack_ami_id=ami-0fedcba9876543210" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}" \
  module.data.aws_cloudwatch_log_group.rds_postgresql \
  /aws/rds/instance/fjcloud-staging/postgresql

# Prod
terraform import \
  -var="env=prod" \
  -var="api_ami_id=ami-0123456789abcdef0" \
  -var="flapjack_ami_id=ami-0fedcba9876543210" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}" \
  module.data.aws_cloudwatch_log_group.rds_postgresql \
  /aws/rds/instance/fjcloud-prod/postgresql
```

## 5. Post-Apply Validation

Run the runtime smoke tests to verify infrastructure health:

```bash
# Full smoke test (requires DNS delegation + running instance)
bash ops/terraform/tests_stage7_runtime_smoke.sh \
  --env staging \
  --domain flapjack.foo \
  --api-ami-id ami-0123456789abcdef0 \
  --flapjack-ami-id ami-0fedcba9876543210

# With apply verification
bash ops/terraform/tests_stage7_runtime_smoke.sh \
  --env staging \
  --domain flapjack.foo \
  --api-ami-id ami-0123456789abcdef0 \
  --flapjack-ami-id ami-0fedcba9876543210 \
  --apply
```

## Rollback Procedure

Terraform does not have a native "rollback" command. Recovery depends on the failure type:

### Failed apply (partial) — revert config and re-apply

1. Revert the `.tf` file changes that caused the failure:
   ```bash
   git diff ops/terraform/
   git checkout -- ops/terraform/
   ```
2. Re-apply with the previous known-good configuration:
   ```bash
   terraform apply \
     -var="env=staging" \
     -var="api_ami_id=ami-0123456789abcdef0" \
     -var="flapjack_ami_id=ami-0fedcba9876543210" \
     -var="domain=flapjack.foo" \
     -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}"
   ```

### Remove a specific problematic resource

Use `terraform destroy -target` to remove only the resource causing issues:

```bash
terraform destroy -target="module.compute.aws_instance.api" \
  -var="env=staging" \
  -var="api_ami_id=ami-0123456789abcdef0" \
  -var="flapjack_ami_id=ami-0fedcba9876543210" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}"
```

Then re-apply to recreate it:

```bash
terraform apply \
  -var="env=staging" \
  -var="api_ami_id=ami-0123456789abcdef0" \
  -var="flapjack_ami_id=ami-0fedcba9876543210" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}"
```

### State corruption recovery

If state becomes inconsistent with actual AWS resources:

```bash
# List resources in state
terraform state list

# Show details of a specific Cloudflare DNS resource
terraform state show 'module.dns.cloudflare_dns_record.public["api"]'

# Remove a resource from state (resource still exists in AWS, will be re-imported)
terraform state rm 'module.compute.aws_instance.api'

# Re-import an existing AWS resource into state
terraform import \
  -var="env=staging" \
  -var="api_ami_id=ami-0123456789abcdef0" \
  -var="flapjack_ami_id=ami-0fedcba9876543210" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}" \
  'module.dns.cloudflare_dns_record.public["api"]' "${CLOUDFLARE_ZONE_ID}/<record_id>"
```

## Module Inventory

The root module (`_shared/main.tf`) composes 6 modules:

| Module | Path | Purpose |
|--------|------|---------|
| networking | `ops/terraform/networking/` | VPC, subnets, security groups |
| compute | `ops/terraform/compute/` | EC2 instance, instance profile |
| data | `ops/terraform/data/` | RDS PostgreSQL, SSM params |
| dns | `ops/terraform/dns/` | Cloudflare DNS, ACM, ALB, listeners |
| monitoring | `ops/terraform/monitoring/` | CloudWatch alarms, SNS |
| _shared | `ops/terraform/_shared/` | Root module, backend config |

## Production Apply

Production follows the same procedure with these differences:

- Use `fjcloud-tfstate-prod` for backend
- Use `env=prod` for all `-var` flags
- Production rejects empty `alert_emails`; pass at least one valid email address
- **Always** apply to staging first and verify before touching prod
- Review the plan extra carefully — prod changes are higher risk
- After sourcing the authorized secret environment, normalize the Cloudflare
  aliases used by the prod secret file before running Terraform. Terraform gets
  the DNS zone through the explicit `cloudflare_zone_id` variable, while the
  Cloudflare provider reads API credentials from environment variables.

```bash
export CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-${CLOUDFLARE_ZONE_ID_FLAPJACK_FOO:-}}"
export CLOUDFLARE_API_KEY="${CLOUDFLARE_API_KEY:-${CLOUDFLARE_GLOBAL_API_KEY:-}}"
export CLOUDFLARE_EMAIL="${CLOUDFLARE_EMAIL:-${CLOUDFLARE_X_Auth_Email:-}}"
```

```bash
terraform plan \
  -var="env=prod" \
  -var="api_ami_id=ami-0123456789abcdef0" \
  -var="flapjack_ami_id=ami-0fedcba9876543210" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}" \
  -var='alert_emails=["stuart.clifford@gmail.com"]'

terraform apply \
  -var="env=prod" \
  -var="api_ami_id=ami-0123456789abcdef0" \
  -var="flapjack_ami_id=ami-0fedcba9876543210" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}" \
  -var='alert_emails=["stuart.clifford@gmail.com"]'
```
