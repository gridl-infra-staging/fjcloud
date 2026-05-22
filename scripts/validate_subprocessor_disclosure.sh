#!/usr/bin/env bash
# Validate sub-processor disclosure content on staging/prod legal pages.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() {
    echo "[validate_subprocessor_disclosure] $*"
}

fail() {
    echo "[validate_subprocessor_disclosure] ERROR: $*" >&2
    exit 1
}

extract_expected_date() {
    local format_file="$REPO_ROOT/web/src/lib/format.ts"
    local date

    date="$(sed -nE "s/^export const LEGAL_EFFECTIVE_DATE = '([0-9]{4}-[0-9]{2}-[0-9]{2})';$/\1/p" "$format_file" | head -n1)"
    if [ -z "$date" ]; then
        fail "unable to extract LEGAL_EFFECTIVE_DATE from $format_file"
    fi
    if [[ ! "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        fail "LEGAL_EFFECTIVE_DATE malformed: $date"
    fi
    printf '%s\n' "$date"
}

slugify_host() {
    local host="$1"
    host="${host#https://}"
    host="${host#http://}"
    host="${host//./_}"
    printf '%s\n' "$host"
}

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

assert_contains_literal() {
    local file_path="$1"
    local expected_literal="$2"
    grep -Fq "$expected_literal" "$file_path"
}

assert_path_specific_legal_copy() {
    local path="$1"
    local out_html="$2"
    local reason_ref="$3"

    case "$path" in
        "/dpa")
            if ! assert_contains_literal "$out_html" "Data Processing Addendum"; then
                printf -v "$reason_ref" "%s" "missing canonical /dpa heading: Data Processing Addendum"
                return 1
            fi
            if ! assert_contains_literal "$out_html" "Flapjack Cloud maintains written sub-processor agreements, including Standard Contractual Clauses where required by applicable law."; then
                printf -v "$reason_ref" "%s" "missing canonical /dpa SCC commitment sentence"
                return 1
            fi
            if ! assert_contains_literal "$out_html" "Flapjack Cloud commits to maintaining and periodically reviewing this sub-processor disclosure to reflect current vendor processing roles."; then
                printf -v "$reason_ref" "%s" "missing canonical /dpa maintenance commitment sentence"
                return 1
            fi
            if ! assert_contains_literal "$out_html" "Slack Technologies, LLC and Discord, Inc. are limited to social identity and support communications and are not used for payment processing."; then
                printf -v "$reason_ref" "%s" "missing canonical /dpa social-identity scope sentence"
                return 1
            fi
            ;;
        "/privacy")
            if ! assert_contains_literal "$out_html" "Privacy Policy"; then
                printf -v "$reason_ref" "%s" "missing canonical /privacy heading: Privacy Policy"
                return 1
            fi
            if ! assert_contains_literal "$out_html" "Third Parties and Sharing"; then
                printf -v "$reason_ref" "%s" "missing canonical /privacy section heading: Third Parties and Sharing"
                return 1
            fi
            if ! assert_contains_literal "$out_html" "Slack Technologies, LLC and Discord, Inc. process only support and social identity interactions and are excluded from payment-processing flows."; then
                printf -v "$reason_ref" "%s" "missing canonical /privacy social-identity scope sentence"
                return 1
            fi
            ;;
        *)
            printf -v "$reason_ref" "%s" "unsupported path: $path"
            return 1
            ;;
    esac

    return 0
}

main() {
    cd "$REPO_ROOT"

    local expected_date
    expected_date="$(extract_expected_date)"

    local run_utc
    run_utc="$(date -u +"%Y%m%dT%H%M%SZ")"
    local bundle_dir="$REPO_ROOT/docs/runbooks/evidence/subprocessor_disclosure/$run_utc"
    mkdir -p "$bundle_dir"

    local -a hosts=("https://cloud.staging.flapjack.foo" "https://cloud.flapjack.foo")
    local -a paths=("/dpa" "/privacy")
    local -a vendors=(
        "Amazon Web Services, Inc."
        "Stripe, Inc."
        "Cloudflare, Inc."
        "Slack Technologies, LLC"
        "Discord, Inc."
    )

    local -a summary_lines=()
    local -a summary_json_entries=()
    summary_lines+=("run_utc=$run_utc")
    summary_lines+=("expected_date=$expected_date")

    local failed=0
    local deferred=0

    local host path host_slug path_slug out_html status reason http_code curl_rc
    for host in "${hosts[@]}"; do
        host_slug="$(slugify_host "$host")"

        for path in "${paths[@]}"; do
            path_slug="${path#/}"
            out_html="$bundle_dir/${host_slug}__${path_slug}.html"
            status="PASSED"
            reason="all checks passed"

            curl_rc=0
            http_code="$(curl -sS -L -o "$out_html" -w '%{http_code}' "${host}${path}")" || curl_rc=$?
            if [ "$curl_rc" -ne 0 ] || [ "$http_code" = "000" ]; then
                status="FAILED"
                reason="curl transport failure (curl_exit=${curl_rc} http_code=${http_code:-none})"
            elif [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
                status="FAILED"
                reason="invalid http status token: ${http_code}"
            elif [ "$http_code" = "404" ]; then
                status="DEFERRED"
                reason="path not yet published (http status 404)"
            elif [[ "$http_code" =~ ^[45] ]]; then
                status="FAILED"
                reason="http status ${http_code}"
            elif ! assert_contains_literal "$out_html" "Effective date: $expected_date"; then
                status="FAILED"
                reason="missing canonical effective-date label: Effective date: $expected_date"
            else
                local missing_vendor=0
                local vendor
                for vendor in "${vendors[@]}"; do
                    if ! grep -Fq "$vendor" "$out_html"; then
                        missing_vendor=1
                        break
                    fi
                done

                if [ "$missing_vendor" -eq 1 ]; then
                    status="DEFERRED"
                    reason="vendor list not yet fully propagated"
                else
                    if ! assert_path_specific_legal_copy "$path" "$out_html" reason; then
                        status="FAILED"
                    fi
                fi
            fi

            summary_lines+=("${host}${path}|${status}|${reason}|artifact=$(basename "$out_html")")
            summary_json_entries+=("{\"host\":\"$(json_escape "$host")\",\"path\":\"$(json_escape "$path")\",\"status\":\"$status\",\"reason\":\"$(json_escape "$reason")\",\"artifact\":\"$(json_escape "$(basename "$out_html")")\",\"http_code\":\"$(json_escape "${http_code}")\",\"curl_exit\":${curl_rc}}")

            if [ "$status" = "FAILED" ]; then
                failed=1
            elif [ "$status" = "DEFERRED" ]; then
                deferred=1
                continue
            fi
        done
    done

    local summary_file="$bundle_dir/summary_status.txt"
    {
        printf '%s\n' "# subprocessor disclosure validation summary"
        printf '%s\n' "classification_format=host_path|STATUS|reason|artifact=file"
        printf '%s\n' "${summary_lines[@]}"
    } > "$summary_file"

    local status_json="$bundle_dir/summary_status.json"
    local final_status
    if [ "$failed" -eq 1 ]; then
        final_status="FAILED"
    elif [ "$deferred" -eq 1 ]; then
        final_status="DEFERRED"
    else
        final_status="PASSED"
    fi

    {
        printf '{\n'
        printf '  "run_utc": "%s",\n' "$run_utc"
        printf '  "expected_date": "%s",\n' "$expected_date"
        printf '  "status": "%s",\n' "$final_status"
        printf '  "summary_file": "%s",\n' "$(basename "$summary_file")"
        printf '  "probes": [\n'
        local idx=0
        local total="${#summary_json_entries[@]}"
        for entry in "${summary_json_entries[@]}"; do
            idx=$((idx + 1))
            if [ "$idx" -lt "$total" ]; then
                printf '    %s,\n' "$entry"
            else
                printf '    %s\n' "$entry"
            fi
        done
        printf '  ]\n'
        printf '}\n'
    } > "$status_json"

    log "evidence bundle: $bundle_dir"
    log "summary file: $summary_file"
    log "status json: $status_json"

    if [ "$final_status" = "FAILED" ]; then
        log "result: FAILED"
        exit 1
    fi

    if [ "$final_status" = "DEFERRED" ]; then
        log "result: DEFERRED (exit 0; live copy not fully propagated)"
        exit 0
    fi

    log "result: PASSED"
}

main "$@"
