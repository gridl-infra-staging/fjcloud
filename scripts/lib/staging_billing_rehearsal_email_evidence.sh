# Mailpit-backed invoice email evidence helpers for staging billing rehearsal.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
# TODO: Document extract_required_invoice_email_pairs_json.
extract_required_invoice_email_pairs_json() {
    python3 - "$INVOICE_ROWS_JSON" "$CREATED_INVOICE_IDS_JSON" <<'PY' || true
import json
import sys

rows = json.loads(sys.argv[1])
required_ids = json.loads(sys.argv[2])
rows_by_id = {}
for row in rows:
    if not isinstance(row, dict):
        continue
    invoice_id = str(row.get("invoice_id", "")).strip()
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

build_mailpit_invoice_search_url() {
    python3 - "$MAILPIT_API_URL" "$1" <<'PY' || true
import sys
import urllib.parse

base_url = sys.argv[1].rstrip("/")
email = sys.argv[2]
query = f"to:{email} subject:invoice"
encoded_query = urllib.parse.quote(query, safe="")
print(f"{base_url}/api/v1/search?query={encoded_query}")
PY
}

invoice_email_payload_from_records() {
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

missing_pairs = [record for record in records if not record.get("message_ids")]
matched_pairs = [record for record in records if record.get("message_ids")]
mailpit_message_ids = []
for record in matched_pairs:
    for msg_id in record.get("message_ids", []):
        if msg_id not in mailpit_message_ids:
            mailpit_message_ids.append(msg_id)

payload = {
    "required_pairs": pairs,
    "emails_required": len(pairs),
    "emails_with_messages": len(matched_pairs),
    "matched_pairs": matched_pairs,
    "missing_pairs": missing_pairs,
    "missing_invoice_ids": [record.get("invoice_id", "") for record in missing_pairs],
    "mailpit_message_ids": mailpit_message_ids,
}
print(json.dumps(payload))
PY
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
            "Mailpit invoice search timed out for ${email}." \
            "Mailpit invoice search request failed for ${email}."
        return 1
    fi
    if [ "$HTTP_RESPONSE_CODE" != "200" ]; then
        set_invoice_email_http_error "Mailpit invoice search returned HTTP ${HTTP_RESPONSE_CODE} for ${email}."
        return 1
    fi

    response="$HTTP_RESPONSE_BODY"
    if ! is_valid_json "$response"; then
        set_invoice_email_query_failure \
            1 \
            "Mailpit invoice search returned invalid JSON for ${email}." \
            "Mailpit invoice search returned invalid JSON for ${email}."
        return 1
    fi
    candidate_ids_json="$(mailpit_search_message_ids_json "$response")"
    matched_ids_file="${TMPDIR:-/tmp}/invoice_email_message_ids_${$}_${invoice_id}.txt"
    : > "$matched_ids_file"

    while IFS= read -r candidate_message_id; do
        [ -n "$candidate_message_id" ] || continue
        message_url="${MAILPIT_API_URL%/}/api/v1/message/${candidate_message_id}"
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
        set_invoice_email_unsupported_runtime
        return 1
    fi

    pairs_json="$(extract_required_invoice_email_pairs_json)"
    required_count="$(json_array_length "$pairs_json")"
    if [ "$required_count" -le 0 ]; then
        set_invoice_email_missing_pairs
        return 1
    fi

    evidence_records="${TMPDIR:-/tmp}/invoice_email_matches_$$.jsonl"
    : > "$evidence_records"

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
