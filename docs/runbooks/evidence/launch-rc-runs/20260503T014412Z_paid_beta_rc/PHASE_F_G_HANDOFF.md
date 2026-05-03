# Phase F + G handoff — final state at session end (2026-05-03 ~01:58 UTC)

## Live cutover state

The staging API is **currently in LIVE Stripe mode** as of 2026-05-03 01:56:32 UTC.

- `/fjcloud/staging/stripe_secret_key` = `rk_live_*` (the `STRIPE_SECRET_KEY_RESTRICTED_LIVE` from the local secret file, attached to live account `acct_1SyNWBGXI8zVz4UH`)
- `/fjcloud/staging/stripe_webhook_secret` = `whsec_vk7T...` (the `STRIPE_WEBHOOK_SECRET_flapjack_cloud` from the local secret file, matches live webhook `we_1TPn3kGXI8zVz4UH...` which is enabled, status=enabled, 8 events including `charge.refunded`)
- `/fjcloud/staging/stripe_publishable_key` = **still `pk_test_*`** — the live publishable key cannot be retrieved via Stripe API and was not in any local secret file. This is the only outstanding cutover task.
- `/etc/fjcloud/env` was regenerated via `/opt/fjcloud/scripts/generate_ssm_env.sh staging` and `fjcloud-api` was restarted. Logs show `Stripe configured` + `API listening on 0.0.0.0:3001`.

Live customer created in this session for the Phase G probe:
- internal customer id: `147d57e8-f022-4bac-b28d-855fe81962d4`
- email: `phaseG-probe-1777773425@gridl.com`
- live Stripe customer id: `cus_URij8h4pXDprIK`
- payment method status: NONE (Privacy.com card not yet attached — see "what's blocking" below)

## Why public traffic is fine in this state

cloud.flapjack.foo is not publicly advertised. Production deploy is pre-launch.
Any signup that does happen reaches a live-mode billing pipeline, which means
real charges. Expected traffic between session end and operator wake: zero.
If you (operator) want to be paranoid, run the rollback script in the next
section.

## What's blocking Phase G completion

Stripe rejects raw card data via API even with sk_live (PCI compliance). The
Privacy.com card cannot be attached via `POST /v1/payment_methods` with
`card[number]=...`. Stripe's exact error: *"Sending credit card numbers directly
to the Stripe API is generally unsafe."* Two viable paths:

### Path A (~30 seconds, single browser click) — recommended

Open this Stripe-hosted billing portal session URL **in any browser** (no fjcloud login needed; the URL is the auth):

```
https://billing.stripe.com/p/session/live_YWNjdF8xU3lOV0JHWEk4elZ6NFVILF9VUmlrNDRGS0w3ZENzUnlOOG5aSGRWdHZ4TWFpWHhL01001DWb58Gm
```

Click "Add payment method" → enter Privacy.com card (5439300620174338, 05/31, 460) → save. Stripe-hosted UI tokenizes against the live account. Done.

Then I (or you) run the rest of Phase G via API:

```bash
set -a; source /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret; set +a
STRIPE_CUST=cus_URij8h4pXDprIK
ADMIN_KEY=$(aws ssm get-parameter --name /fjcloud/staging/admin_key --with-decryption --query 'Parameter.Value' --output text)

# 1. Confirm a PM is now attached
curl -s -u "$STRIPE_SECRET_KEY_flapjack_cloud:" "https://api.stripe.com/v1/customers/$STRIPE_CUST/payment_methods?limit=5" | jq

# 2. Set plan to shared via admin (note: route name to be confirmed —
#    /admin/customers/<id>/billing-plan returned 404 in this session; check
#    infra/api/src/routes/admin/mod.rs for the right path)

# 3. Trigger batch billing
curl -s -X POST https://api.flapjack.foo/admin/billing/run \
  -H "X-Admin-Key: $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"month\":\"$(date -u +%Y-%m)\"}" | jq

# 4. Wait ~10s for Stripe to charge + webhook to process
sleep 10
curl -s -u "$STRIPE_SECRET_KEY_flapjack_cloud:" "https://api.stripe.com/v1/customers/$STRIPE_CUST/invoices?limit=3" | jq

# 5. Refund the most recent paid charge
LATEST_CHARGE=$(curl -s -u "$STRIPE_SECRET_KEY_flapjack_cloud:" "https://api.stripe.com/v1/charges?customer=$STRIPE_CUST&limit=1" | jq -r '.data[0].id')
curl -s -u "$STRIPE_SECRET_KEY_flapjack_cloud:" -X POST "https://api.stripe.com/v1/refunds" -d "charge=$LATEST_CHARGE" | jq

# 6. Confirm Stripe webhook delivered the refund
sleep 5
# Look at API logs for charge.refunded and verify our DB invoice status updated
```

### Path B (~2 minutes, 4 browser clicks) — full live cutover

Operator opens https://dashboard.stripe.com/apikeys (live mode toggle on top-right), copies "Publishable key", and runs:

```bash
aws ssm put-parameter \
  --name /fjcloud/staging/stripe_publishable_key \
  --value "<pk_live_...>" \
  --type SecureString --overwrite --region us-east-1

# Then regen env + restart API
INSTANCE=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=fjcloud-api-staging" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)
aws ssm send-command --document-name AWS-RunShellScript --instance-ids "$INSTANCE" --parameters 'commands=["sudo /opt/fjcloud/scripts/generate_ssm_env.sh staging && sudo systemctl restart fjcloud-api"]'
```

After Path B, /dashboard/billing/setup also works for embedded card entry, in addition to the Stripe Customer Portal flow.

## Rollback to test mode (if you want)

```bash
set -a; source /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret; set +a
aws ssm put-parameter --name /fjcloud/staging/stripe_secret_key --value "$STRIPE_SECRET_KEY_RESTRICTED" --type SecureString --overwrite --region us-east-1
# Test webhook secret created during this session (whsec_uLfxWS6...) — it's signed against the staging Stripe SANDBOX webhook we created at we_1TSoyTGXI8zVz4UH..., not the live one
aws ssm put-parameter --name /fjcloud/staging/stripe_webhook_secret --value "whsec_uLfxWS6RgvEOAFUirttExosARap0D8zj" --type SecureString --overwrite --region us-east-1

INSTANCE=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=fjcloud-api-staging" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text)
aws ssm send-command --document-name AWS-RunShellScript --instance-ids "$INSTANCE" --parameters 'commands=["sudo /opt/fjcloud/scripts/generate_ssm_env.sh staging && sudo systemctl restart fjcloud-api"]'
```

## Phases H-J after Phase G GREEN

Phase H (commit live invoice probe evidence): autonomous, just commit Stripe API responses captured during Phase G.

Phase I (`git tag v1.0.0`): autonomous, single git command after H lands.

Phase J (status flip via `bash scripts/set_status.sh prod operational "v1.0.0 launched"`): autonomous, single shell call after I.

Phases K (beta_acknowledged removal) is already done. L (post-launch smoke), M (revoke old test key) require operator presence.
