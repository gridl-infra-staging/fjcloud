#!/usr/bin/env bash
#
# Focused live-baseline probe for the Stage 3 aggregate security contract.
#
# Ownership: this script owns row-level baseline classification across fleet,
# engine HTTP/TLS, EC2 security-group, and DNS evidence because the contract is
# aggregate and fail-closed. It reuses the evidence shape and per-target posture
# concepts from probe_engine_exposure.sh, but does not replace that script's
# narrower per-target exposure verdict semantics.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVIDENCE_DIR=""
LIVE_MODE=1

usage() {
    cat <<'EOF'
Usage: scripts/security/probe_live_baseline.sh [--evidence-dir DIR]

Without --evidence-dir, collect read-only live evidence into docs/live-state/.
With --evidence-dir, classify fixture-compatible evidence without network calls.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --evidence-dir)
            [ "$#" -ge 2 ] || die "--evidence-dir requires a path"
            EVIDENCE_DIR="$2"
            LIVE_MODE=0
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

if [ "$LIVE_MODE" -eq 0 ]; then
    [ -d "$EVIDENCE_DIR" ] || die "evidence directory not found: $EVIDENCE_DIR"
else
    TS="$(date -u +%Y%m%dT%H%M%SZ)"
    EVIDENCE_DIR="docs/live-state/${TS}_live_baseline"
    mkdir -p "$EVIDENCE_DIR" || die "could not create evidence directory"
    printf 'EVIDENCE_DIR path=%s\n' "$EVIDENCE_DIR"
fi

record_exit() {
    local exit_file="$1"
    local exit_code="$2"
    printf '%s\n' "$exit_code" > "$exit_file"
}

sanitize_aws_text_file() {
    local path="$1"
    [ -f "$path" ] || return 0

    python3 - "$path" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="ignore")
replacements = (
    (
        r"arn:aws:iam::\d{12}:user/[A-Za-z0-9+=,.@_-]+",
        "arn:aws:iam::<account-id>:user/<redacted>",
    ),
    (
        r"arn:aws:iam::\d{12}:instance-profile/[A-Za-z0-9+=,.@_/-]+",
        "arn:aws:iam::<account-id>:instance-profile/<redacted>",
    ),
    (
        r"arn:aws:ssm:[a-z0-9-]+:\d{12}:parameter/[^\s]+",
        "arn:aws:ssm:<region>:<account-id>:parameter/<redacted>",
    ),
    (
        r"arn:aws:sns:[a-z0-9-]+:\d{12}:[^\s]+",
        "arn:aws:sns:<region>:<account-id>:<redacted-topic>",
    ),
    (
        r"/fjcloud/(staging|prod)/[A-Za-z0-9._-]+",
        r"/fjcloud/\1/<redacted-parameter>",
    ),
)
for pattern, replacement in replacements:
    text = re.sub(pattern, replacement, text)
path.write_text(text, encoding="utf-8")
PY
}

sanitize_aws_json_file() {
    local path="$1"
    [ -f "$path" ] || return 0

    python3 - "$path" <<'PY'
from pathlib import Path
import json
import re
import sys

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))


def redact_string(value):
    if re.fullmatch(r"\d{12}", value):
        return "<account-id>"
    if re.fullmatch(r"arn:aws:iam::\d{12}:instance-profile/.+", value):
        return "arn:aws:iam::<account-id>:instance-profile/<redacted>"
    return re.sub(r"(?<=:)\d{12}(?=:)", "<account-id>", value)


def redact(node):
    if isinstance(node, dict):
        return {key: redact(value) for key, value in node.items()}
    if isinstance(node, list):
        return [redact(value) for value in node]
    if isinstance(node, str):
        return redact_string(node)
    return node


payload = redact(payload)
path.write_text(json.dumps(payload, indent=4) + "\n", encoding="utf-8")
PY
}

collect_targets() {
    local raw_file="$EVIDENCE_DIR/instances.json"
    local target_file="$EVIDENCE_DIR/targets.tsv"
    local exit_file="$EVIDENCE_DIR/targets.exit"
    local error_file="$EVIDENCE_DIR/targets.error"
    local aws_exit

    # Constrained to running instances: terminated instances keep their tags for
    # about an hour and stopped instances keep them indefinitely, but neither
    # exposes a public address, so including them would trip the fail-closed
    # target derivation below and blank every fleet row after routine churn.
    : > "$target_file"
    if aws ec2 describe-instances \
        --filters "Name=tag:managed-by,Values=fjcloud" "Name=instance-state-name,Values=running" \
        --output json > "$raw_file" 2> "$error_file"; then
        aws_exit=0
    else
        aws_exit=$?
    fi
    sanitize_aws_text_file "$error_file"
    record_exit "$exit_file" "$aws_exit"
    [ "$aws_exit" -eq 0 ] || return 0
    sanitize_aws_json_file "$raw_file"

    if ! python3 - "$raw_file" > "$target_file" 2>> "$error_file" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

rows = []
for reservation in payload.get("Reservations", []):
    for instance in reservation.get("Instances", []):
        tags = {
            tag.get("Key"): tag.get("Value")
            for tag in instance.get("Tags", [])
            if isinstance(tag, dict)
        }
        environment = tags.get("environment") or tags.get("Env") or "fleet"
        instance_id = instance.get("InstanceId") or ""
        address = instance.get("PublicDnsName") or instance.get("PublicIpAddress") or ""
        groups = [
            group.get("GroupId")
            for group in instance.get("SecurityGroups", [])
            if isinstance(group, dict) and group.get("GroupId")
        ]
        if not instance_id or not address or not groups:
            raise SystemExit("required target fields could not be derived")
        key_safe_env = re.sub(r"[^A-Za-z0-9_-]", "_", environment)
        rows.append((key_safe_env, instance_id, address, ",".join(groups)))

for row in rows:
    print("\t".join(row))
PY
    then
        record_exit "$exit_file" 1
        return 0
    fi
}

target_key() {
    printf '%s_%s\n' "$1" "$2"
}

collect_security_group() {
    local key="$1"
    local sg_csv="$2"
    local -a group_ids
    local aws_exit

    IFS=',' read -r -a group_ids <<< "$sg_csv"
    if aws ec2 describe-security-groups --group-ids "${group_ids[@]}" --output json \
        > "$EVIDENCE_DIR/${key}.sg.json" 2> "$EVIDENCE_DIR/${key}.sg.error"; then
        aws_exit=0
    else
        aws_exit=$?
    fi
    sanitize_aws_text_file "$EVIDENCE_DIR/${key}.sg.error"
    record_exit "$EVIDENCE_DIR/${key}.sg.exit" "$aws_exit"
    [ "$aws_exit" -eq 0 ] || return 0
    sanitize_aws_json_file "$EVIDENCE_DIR/${key}.sg.json"
}

collect_http_status() {
    local key="$1"
    local path_key="$2"
    local url="$3"
    local status_file="$EVIDENCE_DIR/${key}.http_${path_key}.status"
    local exit_file="$EVIDENCE_DIR/${key}.http_${path_key}.exit"
    local status curl_exit

    if status="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "$url" 2> "$EVIDENCE_DIR/${key}.http_${path_key}.error")"; then
        curl_exit=0
    else
        curl_exit=$?
    fi
    printf '%s\n' "${status:-000}" > "$status_file"
    record_exit "$exit_file" "$curl_exit"
}

collect_health() {
    local key="$1"
    local url="$2"
    local status_file="$EVIDENCE_DIR/${key}.http_health.status"
    local body_file="$EVIDENCE_DIR/${key}.http_health.body"
    local exit_file="$EVIDENCE_DIR/${key}.http_health.exit"
    local status curl_exit

    if status="$(curl -sS -m 8 -o "$body_file" -w '%{http_code}' "$url" 2> "$EVIDENCE_DIR/${key}.http_health.error")"; then
        curl_exit=0
    else
        curl_exit=$?
    fi
    printf '%s\n' "${status:-000}" > "$status_file"
    record_exit "$exit_file" "$curl_exit"
}

collect_tls() {
    local key="$1"
    local host="$2"
    local metrics curl_exit tls_status tls_verify

    if metrics="$(curl -sS -m 8 -o /dev/null -w $'%{http_code}\t%{ssl_verify_result}' \
        "https://${host}:443/1/indexes" 2> "$EVIDENCE_DIR/${key}.tls.error")"; then
        curl_exit=0
    else
        curl_exit=$?
    fi
    IFS=$'\t' read -r tls_status tls_verify <<< "$metrics"
    printf '%s\n' "${tls_status:-000}" > "$EVIDENCE_DIR/${key}.tls.status"
    printf '%s\n' "${tls_verify:-0}" > "$EVIDENCE_DIR/${key}.tls.verify"
    record_exit "$EVIDENCE_DIR/${key}.tls.exit" "$curl_exit"
}

collect_target_evidence() {
    local environment="$1"
    local instance_id="$2"
    local address="$3"
    local sg_csv="$4"
    local key

    key="$(target_key "$environment" "$instance_id")"
    collect_security_group "$key" "$sg_csv"
    collect_tls "$key" "$address"
    collect_http_status "$key" dashboard "http://${address}:7700/dashboard"
    collect_http_status "$key" swagger_ui "http://${address}:7700/swagger-ui"
    collect_http_status "$key" indexes "http://${address}:7700/1/indexes"
    collect_health "$key" "http://${address}:7700/health"
}

collect_dns_txt() {
    local row="$1"
    local name="$2"
    local output_file="$EVIDENCE_DIR/dns_${row}.output"
    local exit_file="$EVIDENCE_DIR/dns_${row}.exit"
    local dns_exit

    if command -v dig >/dev/null 2>&1; then
        if dig +short TXT "$name" > "$output_file" 2> "$EVIDENCE_DIR/dns_${row}.error"; then
            dns_exit=0
        else
            dns_exit=$?
        fi
    elif command -v host >/dev/null 2>&1; then
        if host -t TXT "$name" > "$output_file" 2> "$EVIDENCE_DIR/dns_${row}.error"; then
            dns_exit=0
        else
            dns_exit=$?
        fi
    else
        printf 'no DNS TXT reader available\n' > "$EVIDENCE_DIR/dns_${row}.error"
        : > "$output_file"
        dns_exit=127
    fi
    record_exit "$exit_file" "$dns_exit"
}

write_manifest() {
    {
        printf '# live baseline evidence\n'
        printf 'generated_by=scripts/security/probe_live_baseline.sh\n'
        printf 'evidence_dir=%s\n' "$EVIDENCE_DIR"
        printf 'fixture_compatible=true\n'
        printf 'secret_material_serialized=false\n'
    } > "$EVIDENCE_DIR/manifest.txt"
}

collect_live_evidence() {
    local environment instance_id address sg_ids extra

    collect_targets
    while IFS=$'\t' read -r environment instance_id address sg_ids extra \
        || [ -n "${environment}${instance_id}${address}${sg_ids}${extra}" ]; do
        [ -n "${environment}${instance_id}${address}${sg_ids}${extra}" ] || continue
        [ -z "$extra" ] || continue
        collect_target_evidence "$environment" "$instance_id" "$address" "$sg_ids"
    done < "$EVIDENCE_DIR/targets.tsv"
    collect_dns_txt spf flapjack.foo
    collect_dns_txt dmarc _dmarc.flapjack.foo
    write_manifest
}

classify_evidence() {
    python3 "$SCRIPT_DIR/probe_live_baseline_classifier.py" "$EVIDENCE_DIR"
}

if [ "$LIVE_MODE" -eq 1 ]; then
    collect_live_evidence
fi

classify_evidence
