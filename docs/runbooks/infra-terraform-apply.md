# Terraform Apply Procedure

Staging and production apply procedure for fjcloud infrastructure.

Root module: `ops/terraform/_shared/main.tf`
Backend: S3 (`fjcloud-tfstate-<env>`) + DynamoDB lock (`fjcloud-tflock`)

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

```bash
terraform plan \
  -var="env=staging" \
  -var="ami_id=ami-0123456789abcdef0" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}"
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

Expected output:
```
Plan: X to add, Y to change, Z to destroy.
```

## 3. Apply

```bash
terraform apply \
  -var="env=staging" \
  -var="ami_id=ami-0123456789abcdef0" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}"
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
  -var="ami_id=ami-0123456789abcdef0" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}" \
  module.data.aws_cloudwatch_log_group.rds_postgresql \
  /aws/rds/instance/fjcloud-staging/postgresql

# Prod
terraform import \
  -var="env=prod" \
  -var="ami_id=ami-0123456789abcdef0" \
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
  --ami-id ami-0123456789abcdef0

# With apply verification
bash ops/terraform/tests_stage7_runtime_smoke.sh \
  --env staging \
  --domain flapjack.foo \
  --ami-id ami-0123456789abcdef0 \
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
     -var="ami_id=ami-0123456789abcdef0" \
     -var="domain=flapjack.foo" \
     -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}"
   ```

### Remove a specific problematic resource

Use `terraform destroy -target` to remove only the resource causing issues:

```bash
terraform destroy -target="module.compute.aws_instance.api" \
  -var="env=staging" \
  -var="ami_id=ami-0123456789abcdef0" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}"
```

Then re-apply to recreate it:

```bash
terraform apply \
  -var="env=staging" \
  -var="ami_id=ami-0123456789abcdef0" \
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
  -var="ami_id=ami-0123456789abcdef0" \
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
- **Always** apply to staging first and verify before touching prod
- Review the plan extra carefully — prod changes are higher risk
