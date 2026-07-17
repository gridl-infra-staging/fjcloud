# Owner confirmation captures
# captured_at_utc: 2026-05-21T17:11:19Z

## web/wrangler.toml:23-36
    23	name = "flapjack-cloud"
    24	pages_build_output_dir = ".svelte-kit/cloudflare"
    25	compatibility_date = "2026-04-01"
    26	compatibility_flags = ["nodejs_compat"]
    27	
    28	# Runtime env vars exposed to the SvelteKit Worker via $env/dynamic/private.
    29	# These are PUBLIC values — staging API hostname and environment label.
    30	# Adding these here is what makes /signup form submission succeed: the
    31	# action calls `api.register(...)` which fetches `${API_BASE_URL}/auth/register`,
    32	# and without API_BASE_URL the call falls through to the localhost default
    33	# and fails with a generic "unknown error" mapped from the network error.
    34	[vars]
    35	API_BASE_URL = "https://api.flapjack.foo"
    36	ENVIRONMENT = "staging"

## docs/NOW.md:15
    15	**P0 — Lane 4 LB-2 / LB-3 RED on staging.** Two root causes: (a) the Cloudflare Pages project `flapjack-cloud` carries `cloud.staging.flapjack.foo` as a custom domain on the **production** deployment, alongside `cloud.flapjack.foo` and `app.flapjack.foo`; both `production.env_vars.API_BASE_URL` and `preview.env_vars.API_BASE_URL` are set to `https://api.flapjack.foo`. Fix is not a 1-line PATCH — it requires re-attaching `cloud.staging.flapjack.foo` to the staging-branch preview deployments AND populating preview env_vars with staging values (or refactoring `getApiBaseUrl()` to derive from request Host). Recommendation A in `chatting/may21_post_wave1_lane4_partial_handoff.md`. (b) ✅ signup did not verify the returned JWT before setting the cookie — fixed this session in `web/src/routes/signup/+page.server.ts` (commit `43dcbdb6`) with regression test. Probe `scripts/canary/contracts/web_api_base_url_contract.sh staging` re-verifies after the Cloudflare fix.

## ops/terraform/dns/main.tf:1-39
     1	locals {
     2	  api_domain   = "api.${var.domain}"
     3	  www_domain   = "www.${var.domain}"
     4	  cloud_domain = "cloud.${var.domain}"
     5	
     6	  # Cloudflare does CNAME flattening at the zone apex, which is the closest
     7	  # equivalent to the prior Route53 ALIAS record for the public ALB.
     8	  public_dns_records = {
     9	    apex = {
    10	      name    = var.domain
    11	      type    = "CNAME"
    12	      content = aws_lb.api.dns_name
    13	      ttl     = var.dns_ttl
    14	      proxied = false
    15	    }
    16	    api = {
    17	      name    = local.api_domain
    18	      type    = "CNAME"
    19	      content = aws_lb.api.dns_name
    20	      ttl     = var.dns_ttl
    21	      proxied = false
    22	    }
    23	    www = {
    24	      name    = local.www_domain
    25	      type    = "CNAME"
    26	      content = aws_lb.api.dns_name
    27	      ttl     = var.dns_ttl
    28	      proxied = false
    29	    }
    30	    cloud = {
    31	      name = local.cloud_domain
    32	      type = "CNAME"
    33	      # The canonical cloud hostname still uses the existing Pages-backed web
    34	      # deploy while runtime/API traffic stays on the ALB-backed hosts.
    35	      content = "flapjack-cloud.pages.dev"
    36	      ttl     = 1
    37	      proxied = true
    38	    }
    39	  }

## ops/runbooks/site_takedown_20260503/restore.sh:16-38
    16	: "${CLOUDFLARE_GLOBAL_API_KEY:?need CF global key from .env.secret}"
    17	: "${CLOUDFLARE_X_Auth_Email:?need CF email from .env.secret}"
    18	ZONE="fafbf95a076d7e8ee984dbd18a62c933"
    19	ACCOUNT="99deba6554f68cb3544bd9ecfd08ff06"
    20	ALB="fjcloud-staging-alb-1511805790.us-east-1.elb.amazonaws.com"
    21	auth() { curl -s -H "X-Auth-Key: ${CLOUDFLARE_GLOBAL_API_KEY}" -H "X-Auth-Email: ${CLOUDFLARE_X_Auth_Email}" -H "Content-Type: application/json" "$@"; }
    22	ok() { python3 -c "import sys,json;d=json.load(sys.stdin);print('  success:',d.get('success'),d.get('errors') or '')"; }
    23	
    24	echo "[1/5] Recreate cloud.flapjack.foo CNAME → flapjack-cloud.pages.dev (proxied)"
    25	auth -X POST --data '{"type":"CNAME","name":"cloud.flapjack.foo","content":"flapjack-cloud.pages.dev","ttl":1,"proxied":true}' "https://api.cloudflare.com/client/v4/zones/${ZONE}/dns_records" | ok
    26	
    27	echo "[2/5] Recreate app.flapjack.foo CNAME → flapjack-cloud.pages.dev (proxied)"
    28	auth -X POST --data '{"type":"CNAME","name":"app.flapjack.foo","content":"flapjack-cloud.pages.dev","ttl":1,"proxied":true}' "https://api.cloudflare.com/client/v4/zones/${ZONE}/dns_records" | ok
    29	
    30	echo "[3/5] Recreate flapjack.foo apex CNAME → ${ALB} (DNS-only)"
    31	auth -X POST --data "{\"type\":\"CNAME\",\"name\":\"flapjack.foo\",\"content\":\"${ALB}\",\"ttl\":1,\"proxied\":false}" "https://api.cloudflare.com/client/v4/zones/${ZONE}/dns_records" | ok
    32	
    33	echo "[4/5] Recreate www.flapjack.foo CNAME → ${ALB} (DNS-only)"
    34	auth -X POST --data "{\"type\":\"CNAME\",\"name\":\"www.flapjack.foo\",\"content\":\"${ALB}\",\"ttl\":1,\"proxied\":false}" "https://api.cloudflare.com/client/v4/zones/${ZONE}/dns_records" | ok
    35	
    36	echo "[5/5] Re-add cloud + app as Pages custom domains"
    37	auth -X POST --data '{"name":"cloud.flapjack.foo"}' "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/pages/projects/flapjack-cloud/domains" | ok
    38	auth -X POST --data '{"name":"app.flapjack.foo"}' "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT}/pages/projects/flapjack-cloud/domains" | ok

## docs/design/stripe_customer_portal_contract.md:21-29
    21	- `web/src/routes/dashboard/billing/+page.server.ts` is the billing page server owner for billing request context and should remain the sole owner of default portal return target derivation.
    22	- Contract lock: default portal return URL is derived as `<request origin>/dashboard/billing` in `+page.server.ts` (Stage 4 implementation scope).
    23	- `web/src/routes/dashboard/billing/setup/+page.svelte:40-45` contains a SetupIntent `stripe.confirmSetup` return URL for payment-method setup flow only; it is a separate consumer pattern and must not become a second owner for billing-portal return URL policy.
    24	
    25	## Stripe Official Contract Verification (Reviewed 2026-04-24)
    26	- Portal sessions are created on demand and used as temporary entry points: Stripe integration docs require creating a new portal session when a customer wants billing management and redirecting to the session URL.
    27	- Session `configuration` is optional and falls back to the default configuration when omitted.
    28	- Session-level `return_url` is optional and overrides configuration-level `default_return_url` when provided.
    29	- Portal features are configuration-owned (`features.*` on customer portal configuration object).

## scripts/lib/stripe_account.sh:1-51
     1	#!/usr/bin/env bash
     2	# Shared explicit-account secret-key resolver for Stripe shell scripts.
     3	#
     4	# Contract:
     5	#   - --account <name> resolves STRIPE_SECRET_KEY_<name>.
     6	#   - Resolved key is exported to canonical STRIPE_SECRET_KEY only for the
     7	#     current script invocation.
     8	#   - Without --account, canonical STRIPE_SECRET_KEY must already be present.
     9	
    10	set -euo pipefail
    11	
    12	# Keep flag-value validation in the shared seam so each Stripe script does not
    13	# need its own copy of the same bash 3.2-safe guard.
    14	stripe_account_require_flag_value() {
    15	    local flag_name="$1"
    16	    local arg_count="$2"
    17	    local flag_value="${3:-}"
    18	
    19	    if [ "$arg_count" -lt 2 ] || [ -z "$flag_value" ]; then
    20	        echo "ERROR: ${flag_name} requires a value" >&2
    21	        return 2
    22	    fi
    23	
    24	    printf '%s\n' "$flag_value"
    25	}
    26	
    27	# TODO: Document stripe_account_resolve_secret_key.
    28	stripe_account_resolve_secret_key() {
    29	    local account_name="${1:-}"
    30	    local suffixed_var=""
    31	    local resolved_value=""
    32	
    33	    if [ -n "$account_name" ]; then
    34	        suffixed_var="STRIPE_SECRET_KEY_${account_name}"
    35	        # Use eval for bash 3.2 compatibility when resolving dynamic env names.
    36	        eval "resolved_value=\"\${${suffixed_var}:-}\""
    37	        if [ -z "${resolved_value}" ]; then
    38	            echo "ERROR: --account ${account_name} passed, but env var ${suffixed_var} is not set in .secret/.env.secret" >&2
    39	            return 2
    40	        fi
    41	        export STRIPE_SECRET_KEY="${resolved_value}"
    42	        export STRIPE_TARGET_ACCOUNT_NAME="${account_name}"
    43	    else
    44	        export STRIPE_TARGET_ACCOUNT_NAME="canonical"
    45	    fi
    46	
    47	    if [ -z "${STRIPE_SECRET_KEY:-}" ]; then
    48	        echo "ERROR: STRIPE_SECRET_KEY must be set — pass --account <name> or export canonical STRIPE_SECRET_KEY" >&2
    49	        return 1
    50	    fi
    51	}

## scripts/stripe/configure_billing_portal.sh:115-179
   115	if ! stripe_request GET "/v1/billing_portal/configurations" -G --data-urlencode "active=true" --data-urlencode "limit=100"; then
   116	    log "ERROR: Stripe portal configuration list failed: ${STRIPE_BODY}"
   117	    exit 1
   118	fi
   119	require_http_success "configuration list" 200
   120	
   121	DEFAULT_CONFIGURATION_ID="$(printf '%s' "$STRIPE_BODY" | jq -r '[.data[] | select(.is_default == true)] | sort_by(.created) | .[0].id // empty')"
   122	CONFIGURATION_ACTION=""
   123	
   124	if [ -n "${DEFAULT_CONFIGURATION_ID}" ]; then
   125	    if ! stripe_request POST "/v1/billing_portal/configurations/${DEFAULT_CONFIGURATION_ID}" "${PORTAL_FEATURE_ARGS[@]}"; then
   126	        log "ERROR: Stripe portal default-configuration update failed: ${STRIPE_BODY}"
   127	        exit 1
   128	    fi
   129	    require_http_success "configuration update" 200
   130	    CONFIGURATION_ACTION="updated_existing_default"
   131	else
   132	    if ! stripe_request POST "/v1/billing_portal/configurations" "${PORTAL_FEATURE_ARGS[@]}"; then
   133	        log "ERROR: Stripe portal configuration create failed: ${STRIPE_BODY}"
   134	        exit 1
   135	    fi
   136	    require_http_success "configuration create" 200
   137	    CONFIGURATION_ACTION="created_new_default"
   138	fi
   139	
   140	CONFIGURATION_ID="$(printf '%s' "$STRIPE_BODY" | jq -r '.id // empty')"
   141	if [ -z "${CONFIGURATION_ID}" ]; then
   142	    log "ERROR: Stripe portal configuration response did not include id"
   143	    exit 1
   144	fi
   145	
   146	IS_DEFAULT_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '.is_default // false')"
   147	ENABLED_FEATURES_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '[.features | to_entries[]? | select(.value.enabled == true) | .key] | sort')"
   148	HOSTED_LOGIN_ENABLED_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '.login_page.enabled // false')"
   149	HOSTED_LOGIN_URL_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '.login_page.url // null')"
   150	HOSTED_LOGIN_PRESENT_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '((.login_page.url // "") | length > 0)')"
   151	DEFAULT_RETURN_URL_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '.default_return_url // null')"
   152	DEFAULT_RETURN_PRESENT_JSON="$(printf '%s' "$STRIPE_BODY" | jq -c '((.default_return_url // "") | length > 0)')"
   153	
   154	jq -nc \
   155	    --arg target_account "${STRIPE_TARGET_ACCOUNT_NAME:-canonical}" \
   156	    --arg account_id "${ACCOUNT_ID}" \
   157	    --arg configuration_id "${CONFIGURATION_ID}" \
   158	    --arg configuration_action "${CONFIGURATION_ACTION}" \
   159	    --argjson is_default "${IS_DEFAULT_JSON}" \
   160	    --argjson enabled_features "${ENABLED_FEATURES_JSON}" \
   161	    --argjson hosted_login_enabled "${HOSTED_LOGIN_ENABLED_JSON}" \
   162	    --argjson hosted_login_url "${HOSTED_LOGIN_URL_JSON}" \
   163	    --argjson hosted_login_present "${HOSTED_LOGIN_PRESENT_JSON}" \
   164	    --argjson default_return_url "${DEFAULT_RETURN_URL_JSON}" \
   165	    --argjson default_return_url_present "${DEFAULT_RETURN_PRESENT_JSON}" \
   166	    '{
   167	      target_account:$target_account,
   168	      account_id:$account_id,
   169	      configuration_id:$configuration_id,
   170	      configuration_action:$configuration_action,
   171	      is_default:$is_default,
   172	      enabled_features:$enabled_features,
   173	      hosted_login:{
   174	        enabled:$hosted_login_enabled,
   175	        url:$hosted_login_url,
   176	        present:$hosted_login_present
   177	      },
   178	      default_return_url:$default_return_url,
   179	      default_return_url_present:$default_return_url_present
