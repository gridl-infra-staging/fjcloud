# AWS OpenSearch Pricing Evidence

PURPOSE: Stage 2 live pricing verification for `infra/pricing-calculator/src/providers/aws_opensearch.rs`.

## Fetches

- `curl -L --max-time 30 https://aws.amazon.com/opensearch-service/pricing/`
  - HTTP status: 200
  - Effective URL: `https://aws.amazon.com/opensearch-service/pricing/`
  - Raw response: `body.html`
  - Headers: `headers.txt`
- `curl -L --max-time 30 https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonES/current/us-east-1/index.json`
  - HTTP status: 200
  - Effective URL: `https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonES/current/us-east-1/index.json`
  - Raw response: `aws_offer_us_east_1.json`
  - Headers: `aws_offer_us_east_1.headers.txt`

## Source-Backed Updates

- `m6g.large.search`: `$0.128/hr` = `12.8` cents/hr.
- `r6g.large.search`: `$0.167/hr` = `16.7` cents/hr.
- `r6g.xlarge.search`: `$0.335/hr` = `33.5` cents/hr.
- `r6g.2xlarge.search`: `$0.669/hr` = `66.9` cents/hr.
- `r6g.4xlarge.search`: `$1.339/hr` = `133.9` cents/hr.
- gp3 storage: `$0.122/GB-month` = `12.2` cents/GB-month.
- `t3.small.search` and `t3.medium.search` still match the existing modeled rates.

## Result

- AWS compute and gp3 storage constants were updated in `aws_opensearch.rs`.
- The OpenSearch pricing page states that standard AWS data transfer charges apply, but the captured OpenSearch page and AmazonES offer did not provide a source-backed value for the module's outbound transfer constant.
- `metadata().last_verified` remains `None`.

## Gap Disposition

- Exact gap: `DATA_TRANSFER_CENTS_PER_GB` is still modeled from the standard first-tier transfer assumption instead of verified from an OpenSearch-owned source.
- Smallest unblock: add a source-backed EC2 data transfer artifact and decide whether that source belongs in `metadata().source_urls`.
- Owner files: `infra/pricing-calculator/src/providers/aws_opensearch.rs`, `infra/pricing-calculator/src/providers/mod.rs`.
- Usable proxy: current `$0.09/GB` first-tier assumption; bias is low for under-10-TB internet egress workloads and high for other regions or higher transfer tiers.
- Disposition: ship with corrected compute/storage rates but keep provider unverified and explicitly allowlisted until transfer pricing is source-backed.
