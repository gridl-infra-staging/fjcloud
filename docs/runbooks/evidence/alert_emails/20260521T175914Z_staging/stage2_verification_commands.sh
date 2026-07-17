#!/usr/bin/env bash
set -euo pipefail

EVID_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPECTED_INPUT="$EVID_DIR/staging_inputs.json"
SUMMARY_FILE="$EVID_DIR/stage2_verification_summary.txt"
STATUS_FILE="$EVID_DIR/stage2_status.txt"
ASSERTION_EVIDENCE_FILE="$EVID_DIR/stage2_set_equality_assertion_evidence.txt"
TOPIC_ARN="$(cat "$EVID_DIR/stage2_staging_topic_arn.txt")"
ATTEMPTS="${ATTEMPTS:-12}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$EXPECTED_INPUT" ] || fail "missing expected endpoints source: $EXPECTED_INPUT"

printf "topic_arn=%s\n" "$TOPIC_ARN" > "$SUMMARY_FILE"
printf "attempts=%s\n" "$ATTEMPTS" >> "$SUMMARY_FILE"
printf "bounded_retry_command=aws sns list-subscriptions-by-topic --topic-arn %s --output json\n" "$TOPIC_ARN" >> "$SUMMARY_FILE"

expected_sorted_file="$(mktemp)"
trap "rm -f '$expected_sorted_file'" EXIT
jq -r ".[]" "$EXPECTED_INPUT" | sort -u > "$expected_sorted_file"

set_equality_failed=0
pending_failed=0

for poll in $(seq 1 "$ATTEMPTS"); do
  snap="$EVID_DIR/stage2_subscriptions_poll_${poll}.json"
  [ -f "$snap" ] || fail "missing poll snapshot: $snap"

  live_file="$EVID_DIR/stage2_live_endpoints_poll_${poll}.txt"
  jq -r ".Subscriptions[] | select(.Protocol==\"email\" or .Protocol==\"email-json\") | .Endpoint" "$snap" | sort -u > "$live_file"

  set_diff_file="$EVID_DIR/stage2_set_diff_poll_${poll}.txt"
  set +e
  diff -u "$expected_sorted_file" "$live_file" > "$set_diff_file"
  diff_rc=$?
  jq -e -n \
    --slurpfile expected "$EXPECTED_INPUT" \
    --slurpfile live "$snap" \
    "(\$expected[0] | sort | unique) == ([\$live[0].Subscriptions[]? | select(.Protocol==\"email\" or .Protocol==\"email-json\") | .Endpoint] | sort | unique)" >/dev/null
  set_eq_rc=$?
  set -e

  if [ "$set_eq_rc" -eq 0 ] && [ "$diff_rc" -eq 0 ]; then
    set_gate="PASS"
  else
    set_gate="FAIL"
    set_equality_failed=1
  fi

  pending_count="$(jq --slurpfile expected "$EXPECTED_INPUT" "[.Subscriptions[] | select((.Protocol==\"email\" or .Protocol==\"email-json\") and (.Endpoint as \$e | (\$expected[0] | index(\$e)) != null)) | select(.SubscriptionArn==\"PendingConfirmation\")] | length" "$snap")"
  if [ "$pending_count" -eq 0 ]; then
    pending_gate="PASS"
  else
    pending_gate="FAIL"
    pending_failed=1
  fi

  printf "poll=%s set_equality=%s pending=%s pending_count=%s\n" "$poll" "$set_gate" "$pending_gate" "$pending_count" >> "$SUMMARY_FILE"
done

if [ "$set_equality_failed" -eq 1 ]; then
  echo "set_equality_gate_result=FAIL" >> "$SUMMARY_FILE"
else
  echo "set_equality_gate_result=PASS" >> "$SUMMARY_FILE"
fi

if [ "$pending_failed" -eq 1 ]; then
  echo "pending_confirmation_gate_result=FAIL" >> "$SUMMARY_FILE"
  printf "verification_failed_pending_confirmation\n" > "$STATUS_FILE"
else
  echo "pending_confirmation_gate_result=PASS" >> "$SUMMARY_FILE"
  printf "verification_passed\n" > "$STATUS_FILE"
fi

{
  echo "expected_input=$EXPECTED_INPUT"
  echo "live_input=$EVID_DIR/stage2_subscriptions_poll_1.json"
  echo "strict_set_equality_command:"
  cat <<'CMD'
jq -e -n \
  --slurpfile expected docs/runbooks/evidence/alert_emails/20260521T175914Z_staging/staging_inputs.json \
  --slurpfile live docs/runbooks/evidence/alert_emails/20260521T175914Z_staging/stage2_subscriptions_poll_1.json \
  '($expected[0] | sort | unique) == ([$live[0].Subscriptions[]? | select(.Protocol=="email" or .Protocol=="email-json") | .Endpoint] | sort | unique)'
CMD

  set +e
  jq -e -n \
    --slurpfile expected "$EXPECTED_INPUT" \
    --slurpfile live "$EVID_DIR/stage2_subscriptions_poll_1.json" \
    "(\$expected[0] | sort | unique) == ([\$live[0].Subscriptions[]? | select(.Protocol==\"email\" or .Protocol==\"email-json\") | .Endpoint] | sort | unique)" >/dev/null
  pass_rc=$?

  jq -e -n \
    --slurpfile expected "$EXPECTED_INPUT" \
    --argjson injected "[\"unexpected@example.com\"]" \
    --slurpfile live "$EVID_DIR/stage2_subscriptions_poll_1.json" \
    "(\$expected[0] + \$injected | sort | unique) == ([\$live[0].Subscriptions[]? | select(.Protocol==\"email\" or .Protocol==\"email-json\") | .Endpoint] | sort | unique)" >/dev/null
  mismatch_rc=$?
  set -e

  echo "set_equality_pass_rc=$pass_rc"
  echo "set_equality_mismatch_rc=$mismatch_rc"
} > "$ASSERTION_EVIDENCE_FILE"
