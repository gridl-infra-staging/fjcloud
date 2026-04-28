# fjcloud — One-Time Bootstrap

These steps are performed **once per AWS account** before the first `terraform init`.
They create the resources that Terraform itself depends on (state backend).

> **Automated alternative**: Use `ops/scripts/provision_bootstrap.sh <env>` to create all bootstrap
> resources idempotently, then `ops/scripts/validate_bootstrap.sh <env>` to verify they exist and
> are correctly configured. The manual steps below are documented for reference.

## 1. Create the S3 state bucket

One bucket per environment:

```bash
# Staging
aws s3api create-bucket \
  --bucket fjcloud-tfstate-staging \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket fjcloud-tfstate-staging \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket fjcloud-tfstate-staging \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block \
  --bucket fjcloud-tfstate-staging \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Prod — same commands with "fjcloud-tfstate-prod"
```

## 2. Create the DynamoDB lock table

Shared across environments:

```bash
aws dynamodb create-table \
  --table-name fjcloud-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

## 3. Initialize Terraform

```bash
cd ops/terraform/_shared

terraform init \
  -backend-config="bucket=fjcloud-tfstate-staging" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=fjcloud-tflock"
```

## 4. Verify

```bash
terraform plan -var="env=staging" -var="ami_id=ami-placeholder"
```

## Notes

- The S3 bucket and DynamoDB table are **not managed by Terraform** — they are
  prerequisites for Terraform's own state storage. Do not import them.
- Bucket versioning is enabled so you can recover from accidental state corruption.
- Public access is blocked on the state bucket.

## Cloudflare Public DNS Credentials (Stage 4)

The Stage 4 Terraform `dns` module publishes public DNS through Cloudflare for
`flapjack.foo`. AWS still owns ACM, ALB, target groups, and listeners.

Load the Cloudflare token and zone ID before planning:

```bash
export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-${CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO:-}}"
export CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-${CLOUDFLARE_ZONE_ID_FLAPJACK_FOO:-}}"
```

For `flapjack.foo`, the staging validators also accept
`CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO` and
`CLOUDFLARE_ZONE_ID_FLAPJACK_FOO` directly from the operator secret file.

Verify token scope and zone identity:

```bash
curl -fsS \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}"
```

Expected result: `"success":true` and `"name":"flapjack.foo"`.

Then pass the zone ID to Terraform:

```bash
cd ops/terraform/_shared

terraform plan \
  -var="env=staging" \
  -var="ami_id=ami-0123456789abcdef0" \
  -var="domain=flapjack.foo" \
  -var="cloudflare_zone_id=${CLOUDFLARE_ZONE_ID}"
```

The expected public records are:

- `flapjack.foo`, `api.flapjack.foo`, and `www.flapjack.foo` as DNS-only
  `CNAME`s to the staging ALB
- `cloud.flapjack.foo` as a proxied `CNAME` to `flapjack-cloud.pages.dev`
- AWS-generated ACM validation CNAMEs

## Cloudflare Validation (Required for ACM / HTTPS / SES)

ACM DNS validation stays pending and SES DKIM stays failed until Cloudflare has
the Terraform-managed validation records.

```bash
bash ops/terraform/tests_stage7_runtime_smoke.sh \
  --env staging \
  --domain flapjack.foo \
  --ami-id ami-0123456789abcdef0 \
  --apply
```

The smoke harness validates the canonical Cloudflare routing split, ACM status,
ALB target health, SES identity/DKIM, and `https://api.flapjack.foo/health`.

Useful direct DNS checks:

```bash
dig +short A flapjack.foo @1.1.1.1
dig +short CNAME api.flapjack.foo @1.1.1.1
dig +short CNAME www.flapjack.foo @1.1.1.1
dig +short CNAME cloud.flapjack.foo @1.1.1.1
```

Only after this propagates should you run Stage 7 runtime apply checks
(`ops/terraform/tests_stage7_runtime_smoke.sh --apply`).

## S3 Releases Bucket (Stage 5)

The deploy scripts download binaries from an S3 releases bucket. Create one per environment:

```bash
# Staging
aws s3api create-bucket \
  --bucket fjcloud-releases-staging \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket fjcloud-releases-staging \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
  --bucket fjcloud-releases-staging \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Prod — same commands with "fjcloud-releases-prod"
```

### S3 release layout

CI uploads release artifacts to:

```
s3://fjcloud-releases-<env>/<env>/<sha>/fjcloud-api             # API binary
s3://fjcloud-releases-<env>/<env>/<sha>/fjcloud-aggregation-job # aggregation binary
s3://fjcloud-releases-<env>/<env>/<sha>/fj-metering-agent       # metering agent binary
s3://fjcloud-releases-<env>/<env>/<sha>/migrations/             # SQL migration files
s3://fjcloud-releases-<env>/<env>/<sha>/scripts/migrate.sh      # migration runner
```

## sqlx-cli on EC2 (Stage 5)

The migration script requires `sqlx-cli` on the EC2 instance. Install it in the
Packer AMI build or via user-data:

```bash
# Install sqlx-cli (migrations only, no TLS features needed — DB is in same VPC)
cargo install sqlx-cli --no-default-features --features postgres
```

Ensure the resulting `sqlx` binary is on the `PATH` (e.g. `/usr/local/bin/sqlx`).

## SSM Parameter Prerequisites (Stage 5)

The deploy and migration scripts expect these SSM parameters to exist:

| Parameter | Type | Set by |
|-----------|------|--------|
| `/fjcloud/<env>/database_url` | SecureString | Terraform data module |
| `/fjcloud/<env>/last_deploy_sha` | String | deploy.sh (auto-managed) |
| `/fjcloud/<env>/canary_quiet_until` | String | deploy.sh (auto-managed control-plane key) |
