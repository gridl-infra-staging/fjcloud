---
created: 2026-05-05
updated: 2026-05-06
---

> **ABANDONED 2026-05-06.** The operator explicitly decided the seed
> accounts do not need a geo restriction ("if restricting the seed accounts
> is gonna cost $200/mo then lets just drop it"). This runbook is preserved
> for historical context only. Do not implement the rule. See
> chatting/may06_handoff_followup_lanes_and_decisions.md for the decision.

# WAF Operator Geo-Block (NC Restriction)

Block operator account logins from outside North Carolina via Cloudflare WAF.
Applies to the six seed operator emails on `flapjack.foo` zone.

## Prerequisites

Two infrastructure changes are required before this rule can take effect:

### 1. Cloudflare Plan Upgrade

The flapjack.foo zone is currently on the **Free** plan. The WAF expression
requires fields gated behind paid plans:

| Field | Required For | Minimum Plan |
|-------|-------------|-------------|
| `http.request.body.raw` | Match operator email in POST body | WAF Advanced (Pro+) |
| `ip.geoip.subdivision_1_iso_code` | Match NC state code | Business |

Upgrade to at least **Business** to use both fields in a single expression.

### 2. Enable CF Proxy on api.flapjack.foo

The `api.flapjack.foo` DNS record is currently `proxied = false` (grey cloud).
Cloudflare WAF rules only fire when traffic passes through CF's proxy.

Change in `ops/terraform/dns/main.tf`, `public_dns_records.api`:
```hcl
proxied = true   # was: false
```

Enabling proxy has implications:
- CF terminates TLS, re-encrypts to origin (configure SSL mode to Full Strict)
- Origin ALB sees CF IPs, not client IPs (use `CF-Connecting-IP` header)
- CF may cache responses (configure cache rules for API paths)
- WebSocket support may need explicit configuration

## Terraform Implementation

Once prerequisites are met, add to `ops/terraform/dns/main.tf` (or a new
sibling `waf.tf` if main.tf is approaching 500 lines):

```hcl
resource "cloudflare_ruleset" "nc_operator_geo_block" {
  zone_id     = var.cloudflare_zone_id
  name        = "NC Operator Geo-Block"
  description = "Block operator account logins from outside North Carolina"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules {
    expression  = <<-EXPR
      http.request.uri.path eq "/auth/login" and
      http.request.method eq "POST" and
      (http.request.body.raw contains "q@q.q" or
       http.request.body.raw contains "a@a.a" or
       http.request.body.raw contains "w@w.w" or
       http.request.body.raw contains "m@m.m" or
       http.request.body.raw contains "n@n.n" or
       http.request.body.raw contains "l@l.l") and
      ip.geoip.subdivision_1_iso_code ne "NC"
    EXPR
    action      = "block"
    description = "Block operator logins outside North Carolina"
    enabled     = true
  }
}
```

Apply from the root module:
```bash
source /path/to/.secret/.env.secret
export CLOUDFLARE_API_KEY="$CLOUDFLARE_GLOBAL_API_KEY"
export CLOUDFLARE_EMAIL="$CLOUDFLARE_X_Auth_Email"
terraform -chdir=ops/terraform/_shared plan
terraform -chdir=ops/terraform/_shared apply
```

## Verification

### CF API readback

```bash
source .secret/.env.secret
# Rulesets entrypoint
curl -s "https://api.cloudflare.com/client/v4/zones/$CLOUDFLARE_ZONE_ID_FLAPJACK_FOO/rulesets/phases/http_request_firewall_custom/entrypoint" \
  -H "X-Auth-Email: $CLOUDFLARE_X_Auth_Email" \
  -H "X-Auth-Key: $CLOUDFLARE_GLOBAL_API_KEY" \
  | jq '[.result.rules[] | select(.expression | contains("subdivision_1_iso_code"))] | length'
# Expected: >= 1
```

### Durham login probe (positive path)

```bash
curl -s -X POST https://api.flapjack.foo/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"q@q.q","password":"qqqqqqqq"}' \
  -w '\n%{http_code}'
# Expected: HTTP 200 with "token" in body (from NC IP)
```

## Travel-IP Override (stuart_travel)

When operating from outside NC, create a Cloudflare IP List named
`stuart_travel` and add a skip expression to the WAF rule:

### Create the IP list (one-time)

Dashboard: Security > WAF > Tools > IP Access Rules, or via API:
```bash
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/rules/lists" \
  -H "X-Auth-Email: $CLOUDFLARE_X_Auth_Email" \
  -H "X-Auth-Key: $CLOUDFLARE_GLOBAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"stuart_travel","description":"Operator travel IPs","kind":"ip"}'
```

### Add current IP to the list

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)
curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/rules/lists/$LIST_ID/items" \
  -H "X-Auth-Email: $CLOUDFLARE_X_Auth_Email" \
  -H "X-Auth-Key: $CLOUDFLARE_GLOBAL_API_KEY" \
  -H "Content-Type: application/json" \
  -d "[{\"ip\":\"$MY_IP\"}]"
```

### Update WAF expression to skip travel IPs

Add `and not ip.src in $stuart_travel` to the block expression. In Terraform,
reference the list via `cloudflare_list` data source or hardcode the list ID.

## CF Field Name Reference

The original spec used `ip.src.region_code` which is not a valid CF expression
field. The correct fields are:
- `ip.geoip.country` — ISO 3166 country code (Free plan)
- `ip.geoip.subdivision_1_iso_code` — ISO 3166-2 subdivision code, e.g. "NC" (Business+ plan)
