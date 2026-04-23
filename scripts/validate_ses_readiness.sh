#!/usr/bin/env bash
# Validate SES readiness using read-only API calls and machine-readable output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation_json.sh"

json_get_field() {
    validation_json_get_field "$@"
}

json_get_nested_field() {
    local json_body="$1"
    local dotted_path="$2"
    python3 - "$json_body" "$dotted_path" <<'PY' || true
import json
import sys

body = sys.argv[1]
path = sys.argv[2]
try:
    data = json.loads(body)
except Exception:
    print("")
    raise SystemExit(0)

value = data
for part in path.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        print("")
        raise SystemExit(0)

if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(str(value))
PY
}

identity_kind_from_value() {
    local identity="$1"
    if [[ "$identity" == *"@"* ]]; then
        echo "email identity"
    else
        echo "domain identity"
    fi
}

identity_kind_from_type_field() {
    local identity_type="$1" fallback="$2"
    case "$identity_type" in
        DOMAIN)
            echo "domain identity"
            ;;
        EMAIL_ADDRESS)
            echo "email identity"
            ;;
        *)
            echo "$fallback"
            ;;
    esac
}

domain_identity_from_email() {
    local identity="$1"
    if [[ "$identity" == *@* ]]; then
        printf '%s\n' "${identity#*@}"
    fi
}

build_identity_cmd() {
    local identity_value="$1"
    IDENTITY_CMD=(aws sesv2 get-email-identity "--email-identity=$identity_value" --output json --no-cli-pager)
    if [[ -n "$region" ]]; then
        IDENTITY_CMD+=("--region=$region")
    fi
}

append_unproven_deliverability_step() {
    validation_append_step "unproven_deliverability_items" true "Unproven in this check: SPF, MAIL FROM, bounce/complaint handling, first-send evidence, inbox-receipt evidence."
}

emit_invalid_identity_result() {
    validation_append_step "get_account" false "Invalid value for --identity; values must not start with '-'."
    validation_append_step "sending_enabled" false "Skipped because SES identity input is invalid."
    validation_append_step "production_access" true "ProductionAccessEnabled not checked because SES identity input is invalid."
    validation_append_step "identity_verified" false "Skipped because SES identity input is invalid."
    validation_append_step "dkim_verified" false "Skipped because SES identity input is invalid."
    append_unproven_deliverability_step
    validation_emit_result false
}

emit_invalid_region_result() {
    validation_append_step "get_account" false "Invalid value for --region; values must not start with '-'."
    validation_append_step "sending_enabled" false "Skipped because SES region input is invalid."
    validation_append_step "production_access" true "ProductionAccessEnabled not checked because SES region input is invalid."
    validation_append_step "identity_verified" false "Skipped because SES region input is invalid."
    validation_append_step "dkim_verified" false "Skipped because SES region input is invalid."
    append_unproven_deliverability_step
    validation_emit_result false
}

identity=""
region=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                validation_append_step "get_account" false "Missing value for --identity."
                validation_append_step "sending_enabled" false "Skipped because required --identity value is missing."
                validation_append_step "production_access" true "ProductionAccessEnabled not checked because required --identity value is missing."
                validation_append_step "identity_verified" false "Skipped because required --identity value is missing."
                validation_append_step "dkim_verified" false "Skipped because required --identity value is missing."
                append_unproven_deliverability_step
                validation_emit_result false
                exit 1
            fi
            identity="$2"
            shift 2
            ;;
        --region)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                validation_append_step "get_account" false "Missing value for --region."
                validation_append_step "sending_enabled" false "Skipped because required --region value is missing."
                validation_append_step "production_access" true "ProductionAccessEnabled not checked because required --region value is missing."
                validation_append_step "identity_verified" false "Skipped because required --region value is missing."
                validation_append_step "dkim_verified" false "Skipped because required --region value is missing."
                append_unproven_deliverability_step
                validation_emit_result false
                exit 1
            fi
            region="$2"
            shift 2
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: scripts/validate_ses_readiness.sh --identity <email-or-domain> [--region <region>]
USAGE
            exit 0
            ;;
        *)
            validation_append_step "get_account" false "Unknown argument: $1"
            validation_append_step "sending_enabled" false "Skipped because argument parsing failed."
            validation_append_step "production_access" true "ProductionAccessEnabled not checked because argument parsing failed."
            validation_append_step "identity_verified" false "Skipped because argument parsing failed."
            validation_append_step "dkim_verified" false "Skipped because argument parsing failed."
            append_unproven_deliverability_step
            validation_emit_result false
            exit 1
            ;;
    esac
done

if [[ -z "$region" && -n "${SES_REGION:-}" ]]; then
    region="$SES_REGION"
fi

if [[ -z "$identity" ]]; then
    validation_append_step "get_account" false "Missing SES identity input. Pass --identity <email-or-domain>."
    validation_append_step "sending_enabled" false "Skipped because SES identity input is missing."
    validation_append_step "production_access" true "ProductionAccessEnabled not checked because SES identity input is missing."
    validation_append_step "identity_verified" false "Skipped because SES identity input is missing."
    validation_append_step "dkim_verified" false "Skipped because SES identity input is missing."
    append_unproven_deliverability_step
    validation_emit_result false
    exit 1
fi

if [[ "$identity" == -* ]]; then
    emit_invalid_identity_result
    exit 1
fi

if [[ -n "$region" && "$region" == -* ]]; then
    emit_invalid_region_result
    exit 1
fi

input_identity_kind="$(identity_kind_from_value "$identity")"

account_cmd=(aws sesv2 get-account --output json --no-cli-pager)
if [[ -n "$region" ]]; then
    account_cmd+=("--region=$region")
fi

if ! account_json="$(AWS_PAGER="" "${account_cmd[@]}" 2>/dev/null)"; then
    validation_append_step "get_account" false "aws sesv2 get-account failed for region '${region:-default}'."
    validation_append_step "sending_enabled" false "Skipped because get_account failed."
    validation_append_step "production_access" true "ProductionAccessEnabled unavailable because get_account failed."
    validation_append_step "identity_verified" false "Skipped because get_account failed (input identity kind: ${input_identity_kind})."
    validation_append_step "dkim_verified" false "Skipped because get_account failed (input identity kind: ${input_identity_kind})."
    append_unproven_deliverability_step
    validation_emit_result false
    exit 1
fi

validation_append_step "get_account" true "Fetched SES account status for region '${region:-default}'."

sending_enabled="$(json_get_field "$account_json" "SendingEnabled")"
production_access_enabled="$(json_get_field "$account_json" "ProductionAccessEnabled")"

sending_enabled_ok=false
if [[ "$sending_enabled" == "true" ]]; then
    sending_enabled_ok=true
    validation_append_step "sending_enabled" true "SendingEnabled=true."
else
    validation_append_step "sending_enabled" false "SendingEnabled=${sending_enabled:-unknown}; must be true."
fi

if [[ "$production_access_enabled" == "true" ]]; then
    validation_append_step "production_access" true "ProductionAccessEnabled=true (production access enabled)."
elif [[ "$production_access_enabled" == "false" ]]; then
    validation_append_step "production_access" true "ProductionAccessEnabled=false (sandbox)."
else
    validation_append_step "production_access" true "ProductionAccessEnabled unavailable in response."
fi

queried_identity="$identity"
inherited_from_email_identity=false
build_identity_cmd "$queried_identity"
if ! identity_json="$(AWS_PAGER="" "${IDENTITY_CMD[@]}" 2>/dev/null)"; then
    if [[ "$input_identity_kind" == "email identity" ]]; then
        inherited_domain="$(domain_identity_from_email "$identity")"
        build_identity_cmd "$inherited_domain"
        if identity_json="$(AWS_PAGER="" "${IDENTITY_CMD[@]}" 2>/dev/null)"; then
            queried_identity="$inherited_domain"
            inherited_from_email_identity=true
        else
            validation_append_step "identity_verified" false "aws sesv2 get-email-identity failed for email identity '${identity}' and inherited domain identity '${inherited_domain}'."
            validation_append_step "dkim_verified" false "Skipped because neither the email identity nor inherited domain identity could be fetched."
            append_unproven_deliverability_step
            validation_emit_result false
            exit 1
        fi
    else
        validation_append_step "identity_verified" false "aws sesv2 get-email-identity failed for '${identity}' (${input_identity_kind})."
        validation_append_step "dkim_verified" false "Skipped because get-email-identity failed for '${identity}' (${input_identity_kind})."
        append_unproven_deliverability_step
        validation_emit_result false
        exit 1
    fi
fi

identity_type_field="$(json_get_field "$identity_json" "IdentityType")"
checked_identity_kind="$(identity_kind_from_type_field "$identity_type_field" "$input_identity_kind")"
verification_status="$(json_get_field "$identity_json" "VerificationStatus")"
dkim_status="$(json_get_nested_field "$identity_json" "DkimAttributes.Status")"

identity_verified_ok=false
if [[ "$verification_status" == "SUCCESS" ]]; then
    identity_verified_ok=true
    if [[ "$inherited_from_email_identity" == true ]]; then
        validation_append_step "identity_verified" true "VerificationStatus=SUCCESS for inherited domain identity '${queried_identity}' used by email identity '${identity}'."
    else
        validation_append_step "identity_verified" true "VerificationStatus=SUCCESS for ${checked_identity_kind} '${identity}'."
    fi
else
    if [[ "$inherited_from_email_identity" == true ]]; then
        validation_append_step "identity_verified" false "VerificationStatus=${verification_status:-unknown} for inherited domain identity '${queried_identity}' used by email identity '${identity}'; must be SUCCESS."
    else
        validation_append_step "identity_verified" false "VerificationStatus=${verification_status:-unknown} for ${checked_identity_kind} '${identity}'; must be SUCCESS."
    fi
fi

dkim_verified_ok=false
if [[ "$identity_type_field" == "EMAIL_ADDRESS" ]]; then
    dkim_verified_ok=true
    validation_append_step "dkim_verified" true "DKIM verification is not applicable to email identity '${identity}'."
elif [[ "$dkim_status" == "SUCCESS" ]]; then
    dkim_verified_ok=true
    if [[ "$inherited_from_email_identity" == true ]]; then
        validation_append_step "dkim_verified" true "DkimAttributes.Status=SUCCESS for inherited domain identity '${queried_identity}' used by email identity '${identity}'."
    else
        validation_append_step "dkim_verified" true "DkimAttributes.Status=SUCCESS for ${checked_identity_kind} '${identity}'."
    fi
else
    if [[ "$inherited_from_email_identity" == true ]]; then
        validation_append_step "dkim_verified" false "DkimAttributes.Status=${dkim_status:-unknown} for inherited domain identity '${queried_identity}' used by email identity '${identity}'; must be SUCCESS."
    else
        validation_append_step "dkim_verified" false "DkimAttributes.Status=${dkim_status:-unknown} for ${checked_identity_kind} '${identity}'; must be SUCCESS."
    fi
fi

append_unproven_deliverability_step

if [[ "$sending_enabled_ok" == true && "$identity_verified_ok" == true && "$dkim_verified_ok" == true ]]; then
    validation_emit_result true
    exit 0
fi

validation_emit_result false
exit 1
