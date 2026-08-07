#!/usr/bin/env bash

# Owner for the production registration block: an ALB listener rule that refuses
# POST /auth/register with a marker-bearing 503.
#
# WHY A LISTENER RULE AND NOT A CLOUDFLARE RULE. `api.flapjack.foo` is DNS-only in
# Cloudflare -- it resolves straight to the prod ALB's IPs, not to Cloudflare's
# edge -- so a Cloudflare WAF rule would never see this traffic. `cloud.flapjack.foo`
# IS proxied, but blocking only the console leaves the API open to direct clients.
# The ALB is the one choke point both paths cross.
#
# WHY THIS IS SAFE TO RUN. The rule is purely additive: the prod HTTPS listener
# carries no rules other than its default forward, so adding one at priority 1
# cannot displace or reorder anything. Every other route keeps hitting the default
# action untouched, and `--revert` deletes exactly the rule this script created.
#
# WHY IT EXISTS IN THE REPO AT ALL. Terraform declares no `aws_lb_listener_rule`,
# so this rule is unmanaged -- a future `terraform apply` will neither remove nor
# recreate it. That makes it exactly the kind of invisible console patch the
# 2026-07 postmortem blamed for the public data-plane exposure. Keeping the
# applier and `probe_signup_closed.sh` in the repo is what gives it an owner and a
# failing check when it disappears.
#
# Default mode is dry-run. Writes require an explicit --execute.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=signup_block_contract.sh disable=SC1091
source "$SCRIPT_DIR/signup_block_contract.sh"

MODE="dry-run"

usage() {
    cat <<'EOF'
Usage: scripts/security/apply_prod_signup_block.sh [--execute|--revert]

  (no flag)   dry-run: report current state, make no AWS writes
  --execute   create the block rule if absent (idempotent)
  --revert    delete the block rule, reopening registration

Requires AWS credentials: set -a; source .secret/.env.secret; set +a
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --execute) MODE="execute"; shift ;;
        --revert)  MODE="revert";  shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

command -v aws >/dev/null 2>&1 || die "aws CLI not found"

# Resolve the listener live rather than hardcoding an ARN: load-balancer and
# listener ARNs are live state and drift when infrastructure is rebuilt.
ALB_ARN="$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?LoadBalancerName=='fjcloud-prod-alb'].LoadBalancerArn" \
    --output text 2>/dev/null)"
[ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ] || die "could not resolve the fjcloud-prod-alb ARN (check AWS credentials)"

LISTENER_ARN="$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[?Port==\`443\`].ListenerArn" --output text 2>/dev/null)"
[ -n "$LISTENER_ARN" ] && [ "$LISTENER_ARN" != "None" ] || die "could not resolve the prod HTTPS:443 listener"

printf 'alb=%s\n' "$ALB_ARN"
printf 'listener=%s\n' "$LISTENER_ARN"

# Identify our rule by its marker in the fixed-response body, not by priority
# alone: priority is a slot, the marker is an identity. Deleting by priority
# could remove a rule somebody else put there.
existing_rule_arn="$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
    --query "Rules[?contains(to_string(Actions), '${SIGNUP_BLOCK_MARKER}')].RuleArn" \
    --output text 2>/dev/null)"

if [ "$existing_rule_arn" = "None" ]; then existing_rule_arn=""; fi

case "$MODE" in
    dry-run)
        if [ -n "$existing_rule_arn" ]; then
            printf 'state=PRESENT rule=%s\n' "$existing_rule_arn"
            printf 'PLAN: nothing to do; the block is already in force\n'
        else
            printf 'state=ABSENT\n'
            printf 'PLAN: would create a priority-%s rule refusing POST %s with %s + marker %s\n' \
                "$SIGNUP_BLOCK_PRIORITY" "$SIGNUP_BLOCK_PATH" "$SIGNUP_BLOCK_STATUS" "$SIGNUP_BLOCK_MARKER"
        fi
        printf '==> Dry-run: no AWS writes performed\n'
        ;;

    execute)
        if [ -n "$existing_rule_arn" ]; then
            printf 'state=PRESENT rule=%s\n' "$existing_rule_arn"
            printf '==> Already in force; no change made (idempotent)\n'
            exit 0
        fi
        # MessageBody carries the marker the probe requires. Content type is JSON
        # so API clients get a parseable refusal rather than an HTML error page.
        body="$(printf '{"error":"registration temporarily closed","marker":"%s"}' "$SIGNUP_BLOCK_MARKER")"
        conditions="$(printf '[{"Field":"path-pattern","PathPatternConfig":{"Values":["%s"]}},{"Field":"http-request-method","HttpRequestMethodConfig":{"Values":["POST"]}}]' "$SIGNUP_BLOCK_PATH")"
        actions="$(printf '[{"Type":"fixed-response","FixedResponseConfig":{"StatusCode":"%s","ContentType":"application/json","MessageBody":%s}}]' \
            "$SIGNUP_BLOCK_STATUS" "$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")"

        created="$(aws elbv2 create-rule \
            --listener-arn "$LISTENER_ARN" \
            --priority "$SIGNUP_BLOCK_PRIORITY" \
            --conditions "$conditions" \
            --actions "$actions" \
            --query 'Rules[0].RuleArn' --output text 2>&1)" \
            || die "create-rule failed: $created"

        printf 'created=%s\n' "$created"

        # A create-rule exit code is not proof the rule is serving. Measured
        # 2026-08-07: the rule took between 5s and 15s to take effect, so a probe
        # run immediately after create still saw the open endpoint. Poll until the
        # block actually answers, and fail loudly if it never does -- reporting
        # success for a rule that is not in force is the worst outcome here.
        printf '==> Waiting for the rule to take effect\n'
        for attempt in $(seq 1 12); do
            if bash "$SCRIPT_DIR/probe_signup_closed.sh" --host "$PROD_API_HOST" >/dev/null 2>&1; then
                printf '==> Block in force and verified after %ss\n' "$((attempt * 5))"
                exit 0
            fi
            sleep 5
        done
        die "rule $created was created but registration is still not refused after 60s; investigate before trusting this block"
        ;;

    revert)
        if [ -z "$existing_rule_arn" ]; then
            printf 'state=ABSENT\n'
            printf '==> Nothing to revert\n'
            exit 0
        fi
        aws elbv2 delete-rule --rule-arn "$existing_rule_arn" >/dev/null 2>&1 \
            || die "delete-rule failed for $existing_rule_arn"
        printf 'deleted=%s\n' "$existing_rule_arn"
        printf '==> Registration reopened. This should only happen once the engine data plane is TLS-only.\n'
        ;;
esac
