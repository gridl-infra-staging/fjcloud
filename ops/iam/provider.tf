# why: Stage 2 account guard must come from the runbook/discovery SSOT
# (staging account 213880904778), not from whichever account STS happens to
# return in the caller session.
provider "aws" {
  region              = "us-east-1"
  allowed_account_ids = ["213880904778"]
}

# why: Inline IAM policies should derive account-scoped ARNs from the verified
# caller account instead of duplicating account IDs or widening to "*".
data "aws_caller_identity" "current" {}
