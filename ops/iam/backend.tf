# Remote state backend: S3 + DynamoDB locking.
#
# Usage:
#   terraform init \
#     -backend-config="bucket=fjcloud-tfstate-staging" \
#     -backend-config="key=iam/terraform.tfstate" \
#     -backend-config="region=us-east-1" \
#     -backend-config="dynamodb_table=fjcloud-tflock"

terraform {
  backend "s3" {
    key            = "iam/terraform.tfstate"
    dynamodb_table = "fjcloud-tflock"
    encrypt        = true
  }
}
