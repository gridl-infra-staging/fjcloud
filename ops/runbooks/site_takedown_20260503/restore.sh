#!/usr/bin/env bash
# Restore the customer-facing site after the 2026-05-03 takedown
# (post v1.0.0 launch review — see chats/handoffs/may3_*).
#
# Reverses these changes:
#   1. Deletes DNS records for cloud, app, flapjack.foo apex, www
#   2. Removes cloud.flapjack.foo and app.flapjack.foo as Pages custom domains
#
# MX (Google Workspace email) was untouched — no restore needed for email.
# api.flapjack.foo was untouched — Stripe webhooks kept flowing throughout.
#
# Usage:
#   set -a; source /Users/stuart/repos/gridl-dev/uff_dev/.secret/.env.secret; set +a
#   bash restore.sh
set -euo pipefail
: "${CLOUDFLARE_GLOBAL_API_KEY:?need CF global key from .env.secret}"
: "${CLOUDFLARE_X_Auth_Email:?need CF email from .env.secret}"
ZONE="fafbf95a076d7e8ee984dbd18a62c933"
ACCOUNT="99deba6554f68cb3544bd9ecfd08ff06"
ALB="fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com"
auth() { curl -s -H "X-Auth-Key: ${CLOUDFLARE_GLOBAL_API_KEY}" -H "X-Auth-Email: ${CLOUDFLARE_X_Auth_Email}" -H "Content-Type: application/json" "$@"; }
ok() { python3 -c "import sys,json;d=json.load(sys.stdin);print('  success:',d.get('success'),d.get('errors') or '')"; }

echo "[1/5] Recreate cloud.flapjack.foo CNAME → flapjack-cloud.pages.dev (proxied)"
auth -X POST --data '{"type":"CNAME","name":"cloud.flapjack.foo","content":"flapjack-cloud.pages.dev","ttl":1,"proxied":true}' "https://api.cloudflare.com/client/v4/zones/${ZONE}/dns_records" | ok

echo "[2/5] Recreate app.flapjack.foo CNAME → flapjack-cloud.pages.dev (proxied)"
auth -X POST --data '{"type":"CNAME","name":"app.flapjack.foo","content":"flapjack-cloud.pages.dev","ttl":1,"proxied":true}' "https://api.cloudflare.com/client/v4/zones/${ZONE}/dns_records" | ok

echo "[3/5] Recreate flapjack.foo apex CNAME → ${ALB} (DNS-only)"
auth -X POST --data "{\"type\":\"CNAME\",\"name\":\"flapjack.foo\",\"content\":\"${ALB}\",\"ttl\":1,\"proxied\":false}" "https://api.cloudflare.com/client/v4/zones/${ZONE}/dns_records" | ok

echo "[4/5] Recreate www.flapjack.foo CNAME → ${ALB} (DNS-only)"
auth -X POST --data "{\"type\":\"CNAME\",\"name\":\"www.flapjack.foo\",\"content\":\"${ALB}\",\"ttl\":1,\"proxied\":false}" "https://api.cloudflare.com/client/v4/zones/${ZONE}/dns_records" | ok

echo "[5/5] Re-add cloud + app as Pages custom domains"
auth -X POST --data '{"name":"cloud.flapjack.foo"}' "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/pages/projects/flapjack-cloud/domains" | ok
auth -X POST --data '{"name":"app.flapjack.foo"}' "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/pages/projects/flapjack-cloud/domains" | ok

echo
echo "Done. Verify:"
echo "  dig +short @bailey.ns.cloudflare.com cloud.flapjack.foo  # expect flapjack-cloud.pages.dev."
echo "  curl -sI https://cloud.flapjack.foo/                     # expect 200 within 1-5 min"
echo
echo "Custom-domain SSL provisioning by Cloudflare may take a few minutes after re-adding."
