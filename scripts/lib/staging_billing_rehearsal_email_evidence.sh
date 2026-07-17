# Mailpit-backed invoice email evidence helpers for staging billing rehearsal.
# Build the invoice/email pairs that must have delivery evidence for created invoices.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# Join created invoice IDs to normalized invoice rows and retain rows with delivery addresses.
# Emit a compact JSON array of invoice_id and email pairs for Mailpit evidence checks.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
extract_required_invoice_email_pairs_json() {
    python3 - "$INVOICE_ROWS_JSON" "$CREATED_INVOICE_IDS_JSON" <<'PY' || true
import json
import sys

rows = json.loads(sys.argv[1])
required_ids = [
    str(invoice_id).strip().lower()
    for invoice_id in json.loads(sys.argv[2])
    if str(invoice_id).strip()
]
rows_by_id = {}
for row in rows:
    if not isinstance(row, dict):
        continue
    invoice_id = str(row.get("invoice_id", "")).strip().lower()
    if not invoice_id:
        continue
    rows_by_id[invoice_id] = {
        "invoice_id": invoice_id,
        "email": str(row.get("email", "")).strip(),
    }

pairs = []
for invoice_id in required_ids:
    row = rows_by_id.get(invoice_id)
    if row and row["email"]:
        pairs.append(row)
print(json.dumps(pairs))
PY
}

create_private_invoice_email_temp_file() {
    local template="$1"
    local failure_detail="$2"
    local temp_file

    temp_file="$(mktemp "$template")" || {
        EVIDENCE_LAST_CLASSIFICATION="invoice_email_tempfile_failed"
        EVIDENCE_LAST_DETAIL="$failure_detail"
        EVIDENCE_TERMINAL_FAILURE=1
        return 1
    }
    if ! chmod 600 "$temp_file"; then
        rm -f "$temp_file"
        EVIDENCE_LAST_CLASSIFICATION="invoice_email_tempfile_failed"
        EVIDENCE_LAST_DETAIL="$failure_detail"
        EVIDENCE_TERMINAL_FAILURE=1
        return 1
    fi
    printf '%s\n' "$temp_file"
}

invoice_email_pairs_to_lines() {
    python3 - "$1" <<'PY' || true
import json
import sys
pairs = json.loads(sys.argv[1])
for pair in pairs:
    invoice_id = str(pair.get("invoice_id", "")).strip()
    email = str(pair.get("email", "")).strip()
    if invoice_id and email:
        print(f"{invoice_id}|{email}")
PY
}

# Persist invoice IDs in rehearsal artifacts, but avoid storing recipient
# addresses because the artifact payload is retained after the live query.
invoice_email_artifact_payload_json() {
    local pairs_json="$1"
    local records_file="$2"

    python3 - "$pairs_json" "$records_file" <<'PY' || true
import json
import pathlib
import sys

pairs = json.loads(sys.argv[1])
records_path = pathlib.Path(sys.argv[2])
records = []
if records_path.exists():
    for line in records_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue

sanitized_pairs = []
for pair in pairs:
    if not isinstance(pair, dict):
        continue
    invoice_id = str(pair.get("invoice_id", "")).strip()
    if invoice_id:
        sanitized_pairs.append({"invoice_id": invoice_id})

missing_pairs = []
matched_pairs = []
mailpit_message_ids = []
for record in records:
    if not isinstance(record, dict):
        continue
    invoice_id = str(record.get("invoice_id", "")).strip()
    if not invoice_id:
        continue
    sanitized_record = {
        "invoice_id": invoice_id,
        "message_ids": record.get("message_ids", []),
        "message_count": record.get("message_count", 0),
    }
    if sanitized_record["message_ids"]:
        matched_pairs.append(sanitized_record)
        for msg_id in sanitized_record["message_ids"]:
            if msg_id not in mailpit_message_ids:
                mailpit_message_ids.append(msg_id)
    else:
        missing_pairs.append(sanitized_record)

payload = {
    "required_pairs": sanitized_pairs,
    "emails_required": len(sanitized_pairs),
    "emails_with_messages": len(matched_pairs),
    "matched_pairs": matched_pairs,
    "missing_pairs": missing_pairs,
    "missing_invoice_ids": [record.get("invoice_id", "") for record in missing_pairs],
    "mailpit_message_ids": mailpit_message_ids,
}
print(json.dumps(payload))
PY
}

mailpit_search_message_ids_json() {
    local response_json="$1"

    python3 - "$response_json" <<'PY' || true
import json
import sys

response = sys.argv[1]
try:
    payload = json.loads(response)
except Exception:
    print("[]")
    raise SystemExit(0)

messages = payload.get("messages")
if not isinstance(messages, list):
    print("[]")
    raise SystemExit(0)

message_ids = []
for msg in messages:
    if not isinstance(msg, dict):
        continue
    msg_id = msg.get("ID") or msg.get("id") or ""
    msg_id = str(msg_id).strip()
    if msg_id and msg_id not in message_ids:
        message_ids.append(msg_id)

print(json.dumps(message_ids))
PY
}

mailpit_message_body_contains_invoice_id() {
    local message_json="$1"
    local invoice_id="$2"

    python3 - "$message_json" "$invoice_id" <<'PY' || true
import json
import sys

message_raw = sys.argv[1]
invoice_id = sys.argv[2]
try:
    payload = json.loads(message_raw)
except Exception:
    print("false")
    raise SystemExit(0)

body_like_strings = []
body_keys = {
    "text",
    "html",
    "raw",
    "body",
    "content",
    "source",
}
ignored_id_keys = {"id", "messageid", "message_id"}

def collect(node, key_hint=""):
    if isinstance(node, dict):
        for key, value in node.items():
            lowered = str(key).lower()
            if lowered in ignored_id_keys:
                continue
            collect(value, lowered)
        return
    if isinstance(node, list):
        for item in node:
            collect(item, key_hint)
        return
    if isinstance(node, str):
        if (not key_hint) or (key_hint in body_keys):
            body_like_strings.append(node)

collect(payload)
print("true" if any(invoice_id in value for value in body_like_strings) else "false")
PY
}

mailpit_file_lines_to_json_array() {
    local file_path="$1"
    python3 - "$file_path" <<'PY' || true
import json
import pathlib
import sys

file_path = pathlib.Path(sys.argv[1])
values = []
for raw_line in file_path.read_text(encoding="utf-8").splitlines() if file_path.exists() else []:
    line = raw_line.strip()
    if not line or line in values:
        continue
    values.append(line)

print(json.dumps(values))
PY
}

validate_mailpit_api_url() {
    local raw_url="${MAILPIT_API_URL:-}"
    local normalized_url

    if ! normalized_url="$(python3 - "$raw_url" <<'PY'
import sys
import urllib.parse

raw_url = sys.argv[1].strip()
parsed = urllib.parse.urlsplit(raw_url)
hostname = (parsed.hostname or "").lower()

if parsed.scheme not in {"http", "https"}:
    raise SystemExit(1)
if not parsed.netloc or parsed.username or parsed.password:
    raise SystemExit(1)
if parsed.query or parsed.fragment or parsed.path not in {"", "/"}:
    raise SystemExit(1)

allowed_hosts = {"mailpit", "localhost", "127.0.0.1", "::1"}
allowed_suffixes = (".localhost", ".test", ".invalid")
is_allowed_mailpit_host = (
    hostname in allowed_hosts
    or (hostname.startswith("mailpit.") and hostname.endswith(allowed_suffixes))
)
if not is_allowed_mailpit_host:
    raise SystemExit(1)

print(f"{parsed.scheme}://{parsed.netloc}")
PY
    )"; then
        EVIDENCE_LAST_CLASSIFICATION="invoice_email_invalid_mailpit_url"
        EVIDENCE_LAST_DETAIL="MAILPIT_API_URL must be an http(s) local/test Mailpit host without credentials, path, query, or fragment."
        EVIDENCE_TERMINAL_FAILURE=1
        return 1
    fi

    MAILPIT_API_URL_EFFECTIVE="$normalized_url"
}

build_mailpit_invoice_search_url() {
    local mailpit_api_url="${MAILPIT_API_URL_EFFECTIVE:-$MAILPIT_API_URL}"
    python3 - "$mailpit_api_url" "$1" <<'PY' || true
import sys
import urllib.parse

base_url = sys.argv[1].rstrip("/")
email = sys.argv[2]
query = f"to:{email} subject:invoice"
encoded_query = urllib.parse.quote(query, safe="")
print(f"{base_url}/api/v1/search?query={encoded_query}")
PY
}

build_mailpit_message_url() {
    local mailpit_api_url="${MAILPIT_API_URL_EFFECTIVE:-$MAILPIT_API_URL}"
    python3 - "$mailpit_api_url" "$1" <<'PY' || true
import sys
import urllib.parse

base_url = sys.argv[1].rstrip("/")
message_id = sys.argv[2]
encoded_message_id = urllib.parse.quote(message_id, safe="")
print(f"{base_url}/api/v1/message/{encoded_message_id}")
PY
}

invoice_email_payload_from_records() {
    local pairs_json="$1"
    local records_file="$2"

    invoice_email_artifact_payload_json "$pairs_json" "$records_file"
}

set_invoice_email_unsupported_runtime() {
    EVIDENCE_LAST_CLASSIFICATION="invoice_email_evidence_delegated"
    EVIDENCE_LAST_DETAIL="MAILPIT_API_URL is not configured; staging runtime invoice email evidence remains delegated to SES-backed proof."
    EVIDENCE_TERMINAL_FAILURE=1
    INVOICE_EMAIL_PAYLOAD='{"required_pairs":[],"emails_required":0,"emails_with_messages":0,"matched_pairs":[],"missing_pairs":[],"missing_invoice_ids":[],"mailpit_message_ids":[]}'
}

set_invoice_email_missing_pairs() {
    EVIDENCE_LAST_CLASSIFICATION="invoice_rows_missing_required_fields"
    EVIDENCE_LAST_DETAIL="Invoice row evidence did not provide invoice_id/email pairs for Mailpit checks."
    EVIDENCE_TERMINAL_FAILURE=1
    INVOICE_EMAIL_PAYLOAD='{"required_pairs":[],"emails_required":0,"emails_with_messages":0,"matched_pairs":[],"missing_pairs":[],"missing_invoice_ids":[],"mailpit_message_ids":[]}'
}

set_invoice_email_query_failure() {
    local mailpit_status="$1"
    local timeout_detail="$2"
    local failure_detail="$3"

    if [ "$mailpit_status" -eq 124 ] || [ "$mailpit_status" -eq 28 ]; then
        EVIDENCE_LAST_CLASSIFICATION="invoice_email_query_timed_out"
        EVIDENCE_LAST_DETAIL="$timeout_detail"
    else
        EVIDENCE_LAST_CLASSIFICATION="invoice_email_query_failed"
        EVIDENCE_LAST_DETAIL="$failure_detail"
    fi
    EVIDENCE_TERMINAL_FAILURE=1
}

set_invoice_email_http_error() {
    EVIDENCE_LAST_CLASSIFICATION="invoice_email_query_http_error"
    EVIDENCE_LAST_DETAIL="$1"
    EVIDENCE_TERMINAL_FAILURE=1
}

set_invoice_email_payload_from_records() {
    local pairs_json="$1"
    local evidence_records="$2"
    INVOICE_EMAIL_PAYLOAD="$(invoice_email_payload_from_records "$pairs_json" "$evidence_records")"
}

invoice_email_ses_lookup_time_ms() {
    local offset_minutes="$1"
    python3 - "$offset_minutes" <<'PY' || true
from datetime import datetime, timedelta, timezone
import sys

offset = int(sys.argv[1])
now = datetime.now(timezone.utc) + timedelta(minutes=offset)
print(int(now.timestamp() * 1000))
PY
}

ses_cloudwatch_next_token() {
    local page_json="$1"
    python3 - "$page_json" <<'PY' || true
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except Exception:
    print("")
    raise SystemExit(0)

token = payload.get("nextToken") or payload.get("NextToken") or ""
print(str(token).strip())
PY
}

merge_ses_cloudwatch_logs_json() {
    local accumulated_json="$1"
    local page_json="$2"
    python3 - "$accumulated_json" "$page_json" <<'PY' || true
import json
import sys

try:
    accumulated = json.loads(sys.argv[1])
except Exception:
    accumulated = {"events": []}
page = json.loads(sys.argv[2])

events = accumulated.get("events", [])
if not isinstance(events, list):
    events = []
page_events = page.get("events", [])
if isinstance(page_events, list):
    events.extend(page_events)

print(json.dumps({"events": events}))
PY
}

# Route SES SEND events (with invoice_id message tag) through the EventBridge
# → CloudWatch Logs pipeline provisioned in ops/terraform/dns/main.tf. We
# replace the historical CloudTrail lookup-events path here because CloudTrail
# event history does not include SES v2 SendEmail data events; the log group
# owned by dns/main.tf::aws_cloudwatch_log_group.ses_send_events is the only
# queryable channel that observes the invoice-id-tagged send events.
run_ses_cloudwatch_logs_lookup() {
    local region log_group lookback_minutes start_time_ms end_time_ms limit
    local output_file seen_tokens_file status page_json next_token
    local aws_args

    region="${SES_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
    log_group="${REHEARSAL_SES_SEND_EVENTS_LOG_GROUP:-/fjcloud/staging/ses/send-events}"
    lookback_minutes="${REHEARSAL_SES_LOOKBACK_MINUTES:-30}"
    start_time_ms="$(invoice_email_ses_lookup_time_ms "-$lookback_minutes")"
    end_time_ms="$(invoice_email_ses_lookup_time_ms "1")"
    limit="${REHEARSAL_SES_CLOUDWATCH_LIMIT:-50}"
    output_file="$(
        create_private_invoice_email_temp_file \
            "${TMPDIR:-/tmp}/invoice_email_ses_cloudwatch.XXXXXX" \
            "Unable to allocate and secure a private temp file for SES CloudWatch Logs evidence."
    )" || return 1
    seen_tokens_file="$(
        create_private_invoice_email_temp_file \
            "${TMPDIR:-/tmp}/invoice_email_ses_tokens.XXXXXX" \
            "Unable to allocate and secure a private temp file for SES CloudWatch Logs pagination tracking."
    )" || {
        rm -f "$output_file"
        return 1
    }

    SES_CLOUDWATCH_LOGS_JSON='{"events":[]}'
    next_token=""
    while :; do
        aws_args=(
            logs filter-log-events
            --log-group-name "$log_group"
            --start-time "$start_time_ms"
            --end-time "$end_time_ms"
            --limit "$limit"
            --region "$region"
            --output json
            --no-cli-pager
        )
        if [ -n "$next_token" ]; then
            if grep -Fxq -- "$next_token" "$seen_tokens_file"; then
                rm -f "$output_file" "$seen_tokens_file"
                EVIDENCE_LAST_CLASSIFICATION="invoice_email_ses_query_failed"
                EVIDENCE_LAST_DETAIL="CloudWatch Logs SES send-events query repeated a pagination token while checking invoice email evidence."
                EVIDENCE_TERMINAL_FAILURE=1
                return 1
            fi
            printf '%s\n' "$next_token" >> "$seen_tokens_file"
            aws_args+=(--next-token "$next_token")
        fi
        AWS_PAGER="" aws "${aws_args[@]}" > "$output_file" 2>/dev/null
        status=$?
        if [ "$status" -ne 0 ]; then
            rm -f "$output_file" "$seen_tokens_file"
            if [ "$status" -eq 124 ]; then
                EVIDENCE_LAST_CLASSIFICATION="invoice_email_ses_query_timed_out"
                EVIDENCE_LAST_DETAIL="CloudWatch Logs SES send-events query timed out while checking invoice email evidence."
            else
                EVIDENCE_LAST_CLASSIFICATION="invoice_email_ses_query_failed"
                EVIDENCE_LAST_DETAIL="CloudWatch Logs SES send-events query failed while checking invoice email evidence."
            fi
            EVIDENCE_TERMINAL_FAILURE=1
            return 1
        fi

        page_json="$(cat "$output_file")"
        if ! is_valid_json "$page_json"; then
            SES_CLOUDWATCH_LOGS_JSON="$page_json"
            rm -f "$output_file" "$seen_tokens_file"
            return 0
        fi
        SES_CLOUDWATCH_LOGS_JSON="$(merge_ses_cloudwatch_logs_json "$SES_CLOUDWATCH_LOGS_JSON" "$page_json")"
        next_token="$(ses_cloudwatch_next_token "$page_json")"
        [ -n "$next_token" ] || {
            rm -f "$output_file" "$seen_tokens_file"
            return 0
        }
    done
}

# Correlate the SES CloudWatch Logs events (EventBridge-shaped JSON) with each
# rehearsal invoice by the `invoice_id` MessageTag attached in
# infra/api/src/services/email.rs::SesEmailService::send_rendered_email.
# The billing run also sends invoice-ready mail during Stripe finalization; the
# dispatch_source tag keeps this gate pinned to the paid-webhook send.
invoice_email_ses_cloudwatch_artifact_payload_json() {
    local pairs_json="$1"
    local cloudwatch_json="$2"

    python3 - "$pairs_json" "$cloudwatch_json" <<'PY' || true
import json
import sys

pairs = json.loads(sys.argv[1])
cloudwatch_payload = json.loads(sys.argv[2])
events = cloudwatch_payload.get("events", [])

required = []
for pair in pairs:
    if isinstance(pair, dict) and str(pair.get("invoice_id", "")).strip():
        required.append({"invoice_id": str(pair.get("invoice_id", "")).strip().lower()})

REQUIRED_EMAIL_TYPE = "invoice_ready"
REQUIRED_DISPATCH_SOURCE = "invoice_payment_succeeded"


def extract_event_body(event):
    if not isinstance(event, dict):
        return None
    raw_message = event.get("message")
    if isinstance(raw_message, str):
        try:
            return json.loads(raw_message)
        except json.JSONDecodeError:
            return None
    if isinstance(raw_message, dict):
        return raw_message
    return None


def extract_invoice_id_and_message_id(body):
    if not isinstance(body, dict):
        return "", ""
    detail = body.get("detail") or {}
    if not isinstance(detail, dict):
        return "", ""
    event_type = str(detail.get("eventType") or "").strip().lower()
    if event_type != "send":
        return "", ""
    mail = detail.get("mail") or {}
    if not isinstance(mail, dict):
        return "", ""
    message_id = str(mail.get("messageId") or "").strip()
    tags = mail.get("tags") or {}
    if not isinstance(tags, dict):
        return "", message_id

    def first_tag_value(name):
        tag_values = tags.get(name)
        if isinstance(tag_values, list) and tag_values:
            return str(tag_values[0]).strip().lower()
        if isinstance(tag_values, str):
            return tag_values.strip().lower()
        return ""

    email_type = first_tag_value("email_type")
    if email_type != REQUIRED_EMAIL_TYPE:
        return "", message_id
    dispatch_source = first_tag_value("dispatch_source")
    if dispatch_source != REQUIRED_DISPATCH_SOURCE:
        return "", message_id
    invoice_id = first_tag_value("invoice_id")
    return invoice_id, message_id


event_index = {}
for event in events:
    body = extract_event_body(event)
    invoice_id, message_id = extract_invoice_id_and_message_id(body)
    if not invoice_id or not message_id:
        continue
    event_index.setdefault(invoice_id, [])
    if message_id not in event_index[invoice_id]:
        event_index[invoice_id].append(message_id)

matched_pairs = []
missing_pairs = []
ses_message_ids = []
for pair in required:
    invoice_id = pair["invoice_id"]
    pair_message_ids = list(event_index.get(invoice_id, []))
    record = {
        "invoice_id": invoice_id,
        "message_ids": pair_message_ids,
        "message_count": len(pair_message_ids),
    }
    if pair_message_ids:
        matched_pairs.append(record)
        for message_id in pair_message_ids:
            if message_id not in ses_message_ids:
                ses_message_ids.append(message_id)
    else:
        missing_pairs.append(record)

sanitized_required = [{"invoice_id": pair["invoice_id"]} for pair in required]
print(json.dumps({
    "evidence_source": "aws_cloudwatch_logs_ses_send_events",
    "required_email_type": REQUIRED_EMAIL_TYPE,
    "required_dispatch_source": REQUIRED_DISPATCH_SOURCE,
    "required_pairs": sanitized_required,
    "emails_required": len(sanitized_required),
    "emails_with_messages": len(matched_pairs),
    "matched_pairs": matched_pairs,
    "missing_pairs": missing_pairs,
    "missing_invoice_ids": [record["invoice_id"] for record in missing_pairs],
    "ses_message_ids": ses_message_ids,
    "mailpit_message_ids": [],
}))
PY
}

check_ses_invoice_email_evidence_once() {
    local pairs_json required_count payload missing_count

    pairs_json="$(extract_required_invoice_email_pairs_json)"
    required_count="$(json_array_length "$pairs_json")"
    if [ "$required_count" -le 0 ]; then
        set_invoice_email_missing_pairs
        return 1
    fi

    if ! run_ses_cloudwatch_logs_lookup; then
        return 1
    fi
    if ! is_valid_json "$SES_CLOUDWATCH_LOGS_JSON"; then
        EVIDENCE_LAST_CLASSIFICATION="invoice_email_ses_query_failed"
        EVIDENCE_LAST_DETAIL="CloudWatch Logs SES send-events query returned invalid JSON."
        EVIDENCE_TERMINAL_FAILURE=1
        INVOICE_EMAIL_PAYLOAD='{"evidence_source":"aws_cloudwatch_logs_ses_send_events","required_pairs":[],"emails_required":0,"emails_with_messages":0,"matched_pairs":[],"missing_pairs":[],"missing_invoice_ids":[],"ses_message_ids":[],"mailpit_message_ids":[]}'
        return 1
    fi

    payload="$(invoice_email_ses_cloudwatch_artifact_payload_json "$pairs_json" "$SES_CLOUDWATCH_LOGS_JSON")"
    INVOICE_EMAIL_PAYLOAD="$payload"
    missing_count="$(json_array_length "$(extract_json_array_field "$payload" "missing_invoice_ids")")"
    if [ "$missing_count" -gt 0 ]; then
        EVIDENCE_LAST_CLASSIFICATION="invoice_email_ses_not_ready"
        EVIDENCE_LAST_DETAIL="CloudWatch Logs SES send-events evidence is missing invoice-ID-correlated sends."
        return 1
    fi

    EVIDENCE_LAST_CLASSIFICATION="invoice_email_ready"
    EVIDENCE_LAST_DETAIL="CloudWatch Logs SES send-events evidence converged with invoice-ID correlation."
    return 0
}

find_mailpit_matching_ids_json() {
    local invoice_id="$1"
    local email="$2"
    local query_url response candidate_ids_json candidate_message_id message_url contains_invoice_id
    local matched_ids_file mailpit_status matching_ids_json

    query_url="$(build_mailpit_invoice_search_url "$email")"
    if capture_http_json_response "$query_url"; then
        :
    else
        mailpit_status=$?
        set_invoice_email_query_failure \
            "$mailpit_status" \
            "Mailpit invoice search timed out while checking invoice ${invoice_id}." \
            "Mailpit invoice search request failed while checking invoice ${invoice_id}."
        return 1
    fi
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        set_invoice_email_http_error "Mailpit invoice search returned HTTP ${HTTP_RESPONSE_CODE} while checking invoice ${invoice_id}."
        return 1
    fi

    response="$HTTP_RESPONSE_BODY"
    if ! is_valid_json "$response"; then
        set_invoice_email_query_failure \
            1 \
            "Mailpit invoice search returned invalid JSON while checking invoice ${invoice_id}." \
            "Mailpit invoice search returned invalid JSON while checking invoice ${invoice_id}."
        return 1
    fi
    candidate_ids_json="$(mailpit_search_message_ids_json "$response")"
    matched_ids_file="$(
        create_private_invoice_email_temp_file \
            "${TMPDIR:-/tmp}/invoice_email_message_ids_${$}_XXXXXX.txt" \
            "Unable to allocate and secure a private temp file for Mailpit message-id correlation."
    )" || return 1

    while IFS= read -r candidate_message_id; do
        [ -n "$candidate_message_id" ] || continue
        message_url="$(build_mailpit_message_url "$candidate_message_id")"
        if capture_http_json_response "$message_url"; then
            :
        else
            mailpit_status=$?
            set_invoice_email_query_failure \
                "$mailpit_status" \
                "Mailpit message fetch timed out for ${candidate_message_id}." \
                "Mailpit message fetch request failed for ${candidate_message_id}."
            rm -f "$matched_ids_file"
            return 1
        fi
        if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
            set_invoice_email_http_error "Mailpit message fetch returned HTTP ${HTTP_RESPONSE_CODE} for ${candidate_message_id}."
            rm -f "$matched_ids_file"
            return 1
        fi
        if ! is_valid_json "$HTTP_RESPONSE_BODY"; then
            set_invoice_email_query_failure \
                1 \
                "Mailpit message fetch returned invalid JSON for ${candidate_message_id}." \
                "Mailpit message fetch returned invalid JSON for ${candidate_message_id}."
            rm -f "$matched_ids_file"
            return 1
        fi
        contains_invoice_id="$(mailpit_message_body_contains_invoice_id "$HTTP_RESPONSE_BODY" "$invoice_id")"
        if [ "$contains_invoice_id" = "true" ]; then
            printf '%s\n' "$candidate_message_id" >> "$matched_ids_file"
        fi
    done < <(json_array_to_lines "$candidate_ids_json")

    matching_ids_json="$(mailpit_file_lines_to_json_array "$matched_ids_file")"
    rm -f "$matched_ids_file"
    MAILPIT_MATCHING_IDS_JSON="$matching_ids_json"
    return 0
}

check_invoice_email_evidence_once() {
    local pairs_json required_count evidence_records invoice_id email
    local matching_ids_json matching_count payload missing_count

    if [ -z "${MAILPIT_API_URL:-}" ]; then
        check_ses_invoice_email_evidence_once
        return $?
    fi
    validate_mailpit_api_url || return 1

    pairs_json="$(extract_required_invoice_email_pairs_json)"
    required_count="$(json_array_length "$pairs_json")"
    if [ "$required_count" -le 0 ]; then
        set_invoice_email_missing_pairs
        return 1
    fi

    evidence_records="$(
        create_private_invoice_email_temp_file \
            "${TMPDIR:-/tmp}/invoice_email_matches.XXXXXX" \
            "Unable to allocate and secure a private temp file for Mailpit invoice email evidence."
    )" || return 1

    while IFS='|' read -r invoice_id email; do
        [ -n "$invoice_id" ] || continue
        [ -n "$email" ] || continue
        if find_mailpit_matching_ids_json "$invoice_id" "$email"; then
            matching_ids_json="${MAILPIT_MATCHING_IDS_JSON:-[]}"
        else
            set_invoice_email_payload_from_records "$pairs_json" "$evidence_records"
            rm -f "$evidence_records"
            return 1
        fi
        matching_count="$(json_array_length "$matching_ids_json")"
        python3 - "$invoice_id" "$email" "$matching_ids_json" "$matching_count" <<'PY' >> "$evidence_records" || true
import json
import sys
invoice_id = sys.argv[1]
email = sys.argv[2]
message_ids = json.loads(sys.argv[3])
count = int(sys.argv[4])
print(json.dumps({
    "invoice_id": invoice_id,
    "email": email,
    "message_ids": message_ids,
    "message_count": count,
}))
PY
    done < <(invoice_email_pairs_to_lines "$pairs_json")

    payload="$(invoice_email_payload_from_records "$pairs_json" "$evidence_records")"
    rm -f "$evidence_records"
    INVOICE_EMAIL_PAYLOAD="$payload"

    missing_count="$(json_array_length "$(extract_json_array_field "$payload" "missing_invoice_ids")")"
    if [ "$missing_count" -gt 0 ]; then
        EVIDENCE_LAST_CLASSIFICATION="invoice_email_not_ready"
        EVIDENCE_LAST_DETAIL="Invoice email evidence is missing invoice-ID-correlated Mailpit matches."
        return 1
    fi

    EVIDENCE_LAST_CLASSIFICATION="invoice_email_ready"
    EVIDENCE_LAST_DETAIL="Invoice email evidence converged in Mailpit with invoice-ID correlation."
    return 0
}
