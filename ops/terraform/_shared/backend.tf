# Remote state backend: S3 + DynamoDB locking.
#
# The S3 bucket and DynamoDB table must be created manually before first use.
# See ops/BOOTSTRAP.md for one-time setup instructions.
#
# Usage:
#   terraform init \
#     -backend-config="bucket=fjcloud-tfstate-staging" \
#     -backend-config="key=terraform.tfstate" \
#     -backend-config="region=us-east-1" \
#     -backend-config="dynamodb_table=fjcloud-tflock"

terraform {
  backend "s3" {
    # Partial config — values injected via -backend-config at init time.
    # This avoids hardcoding env-specific bucket names.
    key            = "terraform.tfstate"
    dynamodb_table = "fjcloud-tflock"
    encrypt        = true
  }
}
