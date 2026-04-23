# Staging Validation Evidence Log — 2026-04-09

## Summary Table

| # | Check                          | Status      | Details                                                                                     |
|---|--------------------------------|-------------|---------------------------------------------------------------------------------------------|
| 1 | AWS credentials                | PASS        | stuart-cli user authenticated                                                               |
| 2 | AMI ID retrieval               | PASS        | ami-078228dbe86117d85 from terraform state                                                  |
| 3 | Terraform drift check          | DRIFT       | 4 changes: EC2 volume size, S3 encryption cosmetic, ACM validation + HTTPS listener pending |
| 4 | EC2 instance health            | PASS        | i-0afc7651593f12372 running                                                                 |
| 5 | SSM reachability               | PASS        | send-command "echo ok" succeeded                                                            |
| 6 | API health (port 3001)         | PASS        | {"status":"ok"} via SSM curl                                                                |
| 7 | RDS connectivity               | PASS        | TCP connection to fjcloud-staging RDS on port 5432 OK (psql not installed; TCP verified)     |
| 8 | ALB target health              | FAIL        | Port mismatch: TG routes to 3000, API listens on 3001. See finding below.                   |
| 9 | CloudWatch alarms (6/6)        | PASS        | All 6 alarms in OK state                                                                    |
|10 | Stripe + metering gate         | ENV-BLOCKED | Stripe env vars not provisioned; unblocks when Stripe SSM params are set                    |
|11 | cargo audit                    | FAIL        | 6 vulnerabilities (3 high, 1 medium, 2 unscored); upgrade aws-lc-sys + rustls-webpki        |

---

## 1. AWS Credentials

Command: `aws sts get-caller-identity`
Exit code: 0

```
UserId: AIDATDTCLTRFKVSWMJCGQ
Account: [REDACTED]
Arn: arn:aws:iam::[REDACTED]:user/stuart-cli
```

## 2. AMI ID Retrieval

Command: `terraform show -json` (parsed for aws_instance AMI)
Exit code: 0

```
AMI: ami-078228dbe86117d85
Instance ID: i-0afc7651593f12372
State: running
```

## 3. Terraform Drift Check

Command: `cd ops/terraform/_shared && terraform plan -var="env=staging" -var="ami_id=ami-078228dbe86117d85" -detailed-exitcode`
Exit code: 2 (drift detected)

Plan: 2 to add, 2 to change, 0 to destroy.

Changes detected:
1. **module.compute.aws_instance.api** — root_block_device volume_size: 40 → 20
   - Live instance has 40GB root volume; Terraform spec says 20GB
   - This is a live drift finding (someone or Packer configured 40GB; TF wants 20GB)
2. **module.data.aws_s3_bucket_server_side_encryption_configuration.cold** — cosmetic rewrite of encryption rule (same AES256 config, different representation)
3. **module.dns.aws_acm_certificate_validation.main** — needs creation (pending DNS delegation for cert validation)
4. **module.dns.aws_lb_listener.https** — needs creation (pending ACM cert validation for HTTPS listener)
5. Output change: acm_certificate_arn update (old cert → new cert ARN)

Items 3-4 are expected: HTTPS listener and ACM cert validation are blocked on Porkbun NS delegation.
Item 1 is notable: the EC2 root volume size mismatch should be reconciled in Terraform config.

## 4. EC2 Instance Health

Command: `aws ec2 describe-instances --filters "Name=tag:Name,Values=fjcloud-api-staging" "Name=instance-state-name,Values=running"`
Exit code: 0

```
Instance: i-0afc7651593f12372
State: running
AMI: ami-078228dbe86117d85
```

## 5. SSM Reachability

Command: `aws ssm send-command --instance-ids i-0afc7651593f12372 --document-name AWS-RunShellScript --parameters 'commands=["echo ok"]'`
Exit code: 0

```
Command ID: e5ff7d8a-f0cf-4486-82f2-189833d35100
Status: Success
Output: ok
```

## 6. API Health Check (Instance-Local)

Command (via SSM): `curl -s http://127.0.0.1:3001/health`
Exit code: 0

```
Command ID: 2ae8746b-d42d-4d7f-99fb-41f72aba0915
Status: Success
Output: {"status":"ok"}
```

## 7. RDS Connectivity

Command (via SSM): TCP connection test to RDS endpoint
Exit code: 0

```
Command ID: 7c2e6f04-145f-439b-a216-96a215d73ab9
Status: Success
Output:
  DB_URL retrieved (length: 121)
  Testing connection to fjcloud-staging.[REDACTED].us-east-1.rds.amazonaws.com:5432
  TCP connection OK
```

Note: `psql` is not installed on the EC2 instance. PostgreSQL version could not be queried directly.
TCP connectivity to RDS on port 5432 was confirmed using bash /dev/tcp test.

## 8. ALB Target Health — FAIL (Known Port Mismatch)

Command: `aws elbv2 describe-target-health --target-group-arn <TG_ARN>`
Exit code: 0

```json
{
    "TargetHealthDescriptions": [
        {
            "Target": {
                "Id": "i-0afc7651593f12372",
                "Port": 3000
            },
            "HealthCheckPort": "3000",
            "TargetHealth": {
                "State": "unused",
                "Reason": "Target.NotInUse",
                "Description": "Target group is not configured to receive traffic from the load balancer"
            }
        }
    ]
}
```

**FINDING: ALB Port Mismatch**
- Target group `fjcloud-staging-api-tg` routes to port **3000**
- API server listens on port **3001** (configured in Stage 8 deploy.sh)
- Additionally, the HTTPS listener has not been created yet (pending ACM cert validation / DNS delegation)
- Target state is "unused" because no listener forwards traffic to this target group yet

**Required fix**: Change target group port from 3000 to 3001 in `ops/terraform/dns/main.tf` lines 72 and 91.
This must be done before public traffic can reach the API through the ALB.
Stage 10 will promote this finding to PRIORITIES.md.

## 9. CloudWatch Alarms

Command: `aws cloudwatch describe-alarms --alarm-name-prefix fjcloud-staging`
Exit code: 0

```
| Alarm Name                                     | State |
|------------------------------------------------|-------|
| fjcloud-staging-alb-5xx-error-rate             | OK    |
| fjcloud-staging-alb-p99-target-response-time   | OK    |
| fjcloud-staging-api-cpu-high                   | OK    |
| fjcloud-staging-api-status-check-failed        | OK    |
| fjcloud-staging-rds-cpu-high                   | OK    |
| fjcloud-staging-rds-free-storage-low           | OK    |
```

All 6 alarms in OK state.

## 10. Stripe + Metering Gate

Command: `BACKEND_LIVE_GATE=1 bash scripts/live-backend-gate.sh --skip-rust-tests`
Exit code: 1

```json
{
  "passed": false,
  "checks_run": 6,
  "checks_failed": 6,
  "checks_skipped": 1,
  "failures": [
    "check_stripe_key_present",
    "check_stripe_key_live",
    "check_stripe_webhook_secret_present",
    "check_stripe_webhook_forwarding",
    "check_usage_records_populated",
    "check_rollup_current"
  ]
}
```

ENV-BLOCKED: All Stripe checks failed because `STRIPE_TEST_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` are not set.
Metering checks failed because no `DATABASE_URL` is available locally.
Unblock criteria: Provision Stripe credentials in SSM and/or set env vars locally for validation.

## 11. Cargo Audit

Command: `cd infra && cargo audit -q`
Exit code: 1

6 vulnerabilities found, 5 allowed warnings:

| Advisory          | Crate          | Version | Severity     | Title                                                  | Fix             |
|-------------------|----------------|---------|--------------|--------------------------------------------------------|-----------------|
| RUSTSEC-2026-0045 | aws-lc-sys     | 0.37.1  | 5.9 (medium) | Timing Side-Channel in AES-CCM Tag Verification       | >=0.38.0        |
| RUSTSEC-2026-0044 | aws-lc-sys     | 0.37.1  | unscored     | X.509 Name Constraints Bypass via Wildcard/Unicode CN  | >=0.39.0        |
| RUSTSEC-2026-0048 | aws-lc-sys     | 0.37.1  | 7.4 (high)   | CRL Distribution Point Scope Check Logic Error         | >=0.39.0        |
| RUSTSEC-2026-0047 | aws-lc-sys     | 0.37.1  | 7.5 (high)   | PKCS7_verify Signature Validation Bypass               | >=0.38.0        |
| RUSTSEC-2026-0046 | aws-lc-sys     | 0.37.1  | 7.5 (high)   | PKCS7_verify Certificate Chain Validation Bypass       | >=0.38.0        |
| RUSTSEC-2026-0049 | rustls-webpki  | 0.103.9 | unscored     | CRLs not authoritative by Distribution Point           | >=0.103.10      |

**Recommended action**: Upgrade `aws-lc-sys` to >=0.39.0 and `rustls-webpki` to >=0.103.10.
These are transitive dependencies via `aws-lc-rs` → `rustls` and direct `rustls-webpki`.
Triage priority: 3 high-severity advisories affect TLS certificate validation paths.
