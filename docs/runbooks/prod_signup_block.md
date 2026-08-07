# Runbook — production registration block

**Status: IN FORCE since 2026-08-07.** Production customer self-registration is
deliberately refused at the prod ALB. This is a temporary safety control, not a
defect. If you are debugging "signup returns 503 on production", this file is the
answer — stop here.

## Why it exists

Two measured facts, both true when the block was installed:

1. The production engine data plane is **plaintext and world-open**. Security
   group `sg-0ab78cabd1b997099` (`fjcloud-prod-sg-flapjack-vm`) carries an ingress
   rule `0.0.0.0/0 tcp/7700` described "public flapjack data plane", and
   `http://34.228.66.185:7700/health` answered `200` from outside AWS. The prod SG
   has **no 443 rule and no port-80 ACME rule**, so no prod engine VM can serve or
   even obtain TLS today.
2. `POST /auth/register` has **no invite, waitlist or allowlist gate**
   (`infra/api/src/routes/auth.rs::register`), and `cloud.flapjack.foo` serves a
   live "Get Started" page.

Together those mean anyone who signed up on production would have had their
documents and API key cross the internet in cleartext. The block closes that
window until the engine fleet is TLS-only.

**Correction, 2026-08-07 UTC — this section previously understated the exposure.**
It claimed no prod engine VM has a DNS record, citing
`fj-vm-shared-1ca0d103.flapjack.foo` as NXDOMAIN, and concluded a new customer
would merely have got a broken endpoint. That measurement dug the EC2 **`Name`
tag**, not the hostname. The hostname is the tag with the `fj-` prefix stripped
(`ops/user-data/bootstrap.sh:188`). Re-measured from outside AWS:

```text
dig +short vm-shared-1ca0d103.flapjack.foo A @1.1.1.1   -> 34.228.66.185
                                            @8.8.8.8   -> 34.228.66.185
                                            @9.9.9.9   -> 34.228.66.185
curl http://vm-shared-1ca0d103.flapjack.foo:7700/health -> 200
```

So the prod engine **is** publicly addressable by hostname and answers over
plaintext today. A customer who signed up before this block would have received a
working endpoint that carried their documents and API key in cleartext — a live
confidentiality exposure, not a broken link. The block is more load-bearing than
this runbook first stated, not less.

The other reason a new prod customer would still have had a degraded experience
stands: the deployed prod API is ~1,626 commits behind `main`.

## What the block is

One additive ALB listener rule on the prod HTTPS:443 listener:

- **Match:** `path-pattern = /auth/register` AND `http-request-method = POST`
- **Action:** fixed response `503`, `application/json`, body carrying the marker
  `fjcloud-registration-closed`
- **Priority:** 1 (the listener had no other rules — only its default forward)

It is purely additive. Every other route, including `POST /auth/login`, still
reaches the default target group untouched. `GET /auth/register` is unaffected.
Staging is untouched and registration there stays open.

## Owners

| Concern | Owner |
| --- | --- |
| The rule's shape (marker, path, status, priority) | `scripts/security/signup_block_contract.sh` |
| Applying / reverting the rule | `scripts/security/apply_prod_signup_block.sh` |
| Proving the rule is in force | `scripts/security/probe_signup_closed.sh` |
| Proving the probe can fail | `scripts/tests/probe_signup_closed_test.sh` (registered in `scripts/lib/test_reachability_manifest.sh`, so `local-ci --fast` runs it) |

Terraform declares no `aws_lb_listener_rule`, so this rule is **unmanaged by
terraform** — a future `terraform apply` will neither remove nor recreate it.
That is exactly the invisible-console-patch shape the 2026-07 postmortem blamed
for the public data-plane exposure, which is why the applier and probe live in
the repo instead of the change living only in the AWS console.

## Evidence at installation (2026-08-07)

The positive and negative controls were run as a pair, because "prod returns 503"
alone cannot distinguish a working block from an outage:

```text
# prod, realistic signup shape -> refused by the block, before the handler
POST https://api.flapjack.foo/auth/register
  {"name":"probe","email":"probe@example.com","password":"x"}
  -> HTTP 503 {"error":"registration temporarily closed","marker":"fjcloud-registration-closed"}

# staging, IDENTICAL payload -> reaches the handler, proving the 503 above is the
# block and not a general outage or a network fault
POST https://api.staging.flapjack.foo/auth/register
  -> HTTP 400 {"error":"password must be at least 15 characters"}
```

The password is deliberately invalid so that even a failed block could not have
created an account as a side effect of measuring.

Collateral checks immediately after applying, all unchanged:

| Check | Result |
| --- | --- |
| `GET https://api.flapjack.foo/health` | `200` |
| `GET https://api.flapjack.foo/version` | `200` |
| `POST https://api.flapjack.foo/auth/login` | `422` (still live) |
| `GET https://api.flapjack.foo/auth/register` | `405` (only POST is matched) |
| `GET https://cloud.flapjack.foo/` | `200` |
| staging registration | still open |

## Commands

```bash
set -a; source .secret/.env.secret; set +a
unset AWS_SESSION_TOKEN

# Is the block in force?
bash scripts/security/probe_signup_closed.sh --host api.flapjack.foo   # exit 0 = CLOSED

# Re-apply after infrastructure rebuild (idempotent; self-verifies)
bash scripts/security/apply_prod_signup_block.sh --execute

# Inspect without writing
bash scripts/security/apply_prod_signup_block.sh
```

The applier polls after creating the rule because a `create-rule` exit code is
not proof the rule is serving: measured 2026-08-07, propagation took between 5s
and 20s, so a probe run immediately after create still saw the open endpoint.

## Lifting the block

**Do not lift this until the production engine data plane is TLS-only.** The exit
condition is the FR-5 prod half: prod terraform applied so the flapjack VM SG
carries 443 and the port-80 ACME rule, every prod engine VM answering
`https://<hostname>/health` with `200` and no `-k`, and `0.0.0.0/0 tcp/7700`
removed with the three static guards inverted.

When that is true:

```bash
bash scripts/security/apply_prod_signup_block.sh --revert
bash scripts/security/probe_signup_closed.sh --host api.flapjack.foo   # expect OPEN
```

Then delete this runbook and its three scripts in the same commit that records
the TLS closure — a safety control outliving its reason is its own hazard.
