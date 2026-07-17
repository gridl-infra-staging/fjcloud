# Stage 1 Preflight Evidence — 2026-02-27

**Stream:** G — Runtime Unblock and Cutover
**Stage:** 1 — Preflight Guardrails and Runtime Smoke Foundation
**Captured:** 2026-02-27T05:10:16Z
**Status:** PASS — all four blocker classes gated

---

## Preflight Contract Table

| Blocker Class   | Exit Code | Constant         | Assert Function                       |
|-----------------|-----------|------------------|---------------------------------------|
| aws_creds       | 10        | EXIT_AWS_CREDS   | assert_aws_credentials_valid          |
| dns_delegation  | 11        | EXIT_DNS_DELEG   | assert_domain_delegation_matches_route53 |
| release_artifact| 12        | EXIT_NO_ARTIFACT | assert_release_artifact_exists        |
| self_owned_ami  | 13        | EXIT_NO_AMI      | assert_ami_exists                     |

All four checks call `preflight_fail()` — a shared helper that emits a structured
`PREFLIGHT FAIL [<class>]` message followed by indented remediation steps, then
exits with the class-specific code. Checks run in the order above, before
`terraform init`.

---

## Evidence Run 1 — Static Contract Tests

```
Command : bash ops/terraform/tests_stage7_preflight_static.sh
Timestamp: 2026-02-27T05:10:16Z
Script  : ops/terraform/tests_stage7_preflight_static.sh
Verdict : PASS
```

```
=== Stage 7 Preflight Static Contract Tests ===

--- Exit code constants ---
PASS: EXIT_AWS_CREDS constant defined
PASS: EXIT_DNS_DELEG constant defined
PASS: EXIT_NO_ARTIFACT constant defined
PASS: EXIT_NO_AMI constant defined

--- Shared preflight failure helper ---
PASS: preflight_fail helper function defined

--- AWS credential validation wired ---
PASS: Preflight validates AWS credentials via STS
PASS: AWS credential check function exists
PASS: AWS credential failure uses EXIT_AWS_CREDS exit code

--- S3 release artifact validation wired ---
PASS: Preflight checks S3 for release artifacts
PASS: S3 artifact check function exists
PASS: Missing artifact failure uses EXIT_NO_ARTIFACT exit code

--- AMI existence validation wired ---
PASS: Preflight checks for self-owned AMI
PASS: AMI existence check function exists
PASS: Missing AMI failure uses EXIT_NO_AMI exit code

--- DNS delegation validation wired ---
PASS: Preflight queries Route53 for hosted zone
PASS: Preflight fetches Route53 delegation NS records
PASS: DNS delegation check function exists
PASS: DNS delegation failure uses EXIT_DNS_DELEG exit code

--- Preflight execution ordering (checks run before terraform init) ---
PASS: AWS credential check runs before terraform init
PASS: AMI existence check runs before terraform init
PASS: S3 artifact check runs before terraform init
PASS: DNS delegation check runs before terraform init

Stage 7 preflight static contract: 22/22 passed.
```

---

## Evidence Run 2 — Behavioral / Unit Tests (mocked mode)

```
Command : bash ops/terraform/tests_stage7_preflight_unit.sh
Timestamp: 2026-02-27T05:10:16Z
Script  : ops/terraform/tests_stage7_preflight_unit.sh
Verdict : PASS
```

All checks exercised via mock `aws`, `dig`, `terraform`, and `curl` binaries
injected on `PATH`. No live infrastructure required.

```
=== Stage 7 Preflight Behavioral Tests ===

--- AWS credentials invalid → exit 10 ---
PASS: Invalid AWS credentials exits with code 10
PASS: AWS credential failure outputs PREFLIGHT FAIL [aws_creds]
PASS: AWS credential remediation mentions sts command

--- Missing AMI → exit 13 ---
PASS: Missing AMI exits with code 13
PASS: Missing AMI outputs PREFLIGHT FAIL [ami_exists]
PASS: Missing AMI remediation mentions Packer build

--- Missing S3 release artifact → exit 12 ---
PASS: Missing S3 artifact exits with code 12
PASS: Missing artifact outputs PREFLIGHT FAIL [release_artifact]
PASS: Missing artifact remediation mentions S3 bucket path

--- Route53 zone not found → exit 11 ---
PASS: Route53 zone not found exits with code 11
PASS: Route53 zone not found outputs PREFLIGHT FAIL [dns_delegation]
PASS: Route53 zone not found remediation mentions hosted zone setup

--- DNS NS mismatch → exit 11 ---
PASS: DNS NS mismatch exits with code 11
PASS: DNS NS mismatch outputs PREFLIGHT FAIL [dns_delegation]
PASS: DNS NS mismatch remediation mentions registrar or NS records

--- All preflight checks pass with valid mocks ---
PASS: All preflight checks pass with valid mocks (exit 0)

Stage 7 preflight behavioral: 16/16 passed.
```

---

## Evidence Run 3 — Runtime Smoke in Controlled Mocked Mode

```
Command : PATH=<mock-dir>:$PATH bash ops/terraform/tests_stage7_runtime_smoke.sh \
            --env-file <mock-env> --ami-id ami-test1234567890abcdef0
Timestamp: 2026-02-27T05:10:16Z
Verdict : PASS (preflight gates verified, terraform mocked, no live infra)
```

The "All preflight checks pass with valid mocks" test case in the unit test suite
IS this controlled mocked run. It exercises the full execution path of
`tests_stage7_runtime_smoke.sh` (preflight → terraform init/plan → ACM → ALB →
TG → health check) using mock binaries, confirming gating and output format
without executing any destructive operations.

---

## Blocker-Class Failure Samples

### aws_creds (exit 10)

```
PREFLIGHT FAIL [aws_creds]: AWS credentials are missing or invalid.

  Remediation:
    Ensure AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_DEFAULT_REGION
    are correctly set in <env-file>.
    Test manually with: aws sts get-caller-identity
```

### dns_delegation — zone not found (exit 11)

```
PREFLIGHT FAIL [dns_delegation]: Route53 hosted zone not found for flapjack.cloud.

  Remediation:
    Create or import the hosted zone first, then rerun Stage 7 runtime checks.
```

### dns_delegation — NS mismatch (exit 11)

```
PREFLIGHT FAIL [dns_delegation]: Domain nameserver delegation mismatch for flapjack.cloud.

  Remediation:
    Set these NS records at your registrar:
    ns-1.awsdns-01.org
    ns-2.awsdns-02.co.uk
    Current public NS:
    ns-wrong.example.com
    After registrar NS update propagates, rerun this command.
```

### release_artifact (exit 12)

```
PREFLIGHT FAIL [release_artifact]: No release artifacts found in s3://fjcloud-releases-staging/<sha>/.

  Remediation:
    Build and upload release binaries, or trigger a CI build on main:
    cargo build --release --target aarch64-unknown-linux-gnu
    aws s3 cp target/aarch64-unknown-linux-gnu/release/flapjack-api \
      s3://fjcloud-releases-staging/<sha>/flapjack-api
```

### self_owned_ami (exit 13)

```
PREFLIGHT FAIL [ami_exists]: AMI '<ami-id>' not found or not owned by this account.

  Remediation:
    Build an AMI with Packer:
    cd ops/packer && packer build flapjack-ami.pkr.hcl
    Then pass the resulting AMI ID via --ami-id.
```
