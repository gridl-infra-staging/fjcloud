#!/usr/bin/env bash
set -euo pipefail
source scripts/lib/env.sh
load_env_file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret.bak.1779296767
export AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID_ROTATED"
export AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY_ROTATED"
export AWS_DEFAULT_REGION=us-east-1

EVID="docs/runbooks/evidence/alert_emails/20260521T185702Z_prod"
EXPECTED_INPUT="docs/runbooks/evidence/alert_emails/20260521T175914Z_staging/prod_inputs.json"
TOPIC_ARN="arn:aws:sns:us-east-1:213880904778:fjcloud-alerts-prod"
ATTEMPTS="${ATTEMPTS:-4}"
SUMMARY_FILE="$EVID/stage4_verification_summary.txt"
STATUS_FILE="$EVID/stage4_status.txt"
CMD_LOG="$EVID/stage4_verification_command_log.txt"
SET_ASSERT_FILE="$EVID/stage4_set_equality_assertion_evidence.txt"
PENDING_ASSERT_FILE="$EVID/stage4_pending_assertion_evidence.txt"
SCRIPT_COPY="$EVID/stage4_verification_commands.sh"

cp /tmp/stage4_verify_prod_sns_fixed.sh "$SCRIPT_COPY"
chmod +x "$SCRIPT_COPY"

printf "topic_arn=%s\n" "$TOPIC_ARN" > "$SUMMARY_FILE"
printf "attempts=%s\n" "$ATTEMPTS" >> "$SUMMARY_FILE"
printf "expected_input=%s\n" "$EXPECTED_INPUT" >> "$SUMMARY_FILE"

cat > "$CMD_LOG" <<LOG
aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --output json
jq -e -n --slurpfile expected "$EXPECTED_INPUT" --slurpfile live "$EVID/prod_subscriptions_poll_1.json" '($expected[0] | sort | unique) == ([$live[0].Subscriptions[]? | select(.Protocol=="email" or .Protocol=="email-json") | .Endpoint] | sort | unique)'
jq -e -n --slurpfile expected "$EXPECTED_INPUT" --slurpfile live "$EVID/prod_subscriptions_poll_1.json" '([$live[0].Subscriptions[]? | select((.Protocol=="email" or .Protocol=="email-json") and (.Endpoint as $e | ($expected[0] | index($e)) != null)) | select(.SubscriptionArn=="PendingConfirmation")] | length) == 0'
LOG

expected_sorted_file="$(mktemp)"
trap 'rm -f "$expected_sorted_file"' EXIT
jq -r '.[]' "$EXPECTED_INPUT" | sort -u > "$expected_sorted_file"

set_gate_failed=0
pending_gate_failed=0

for poll in $(seq 1 "$ATTEMPTS"); do
  snap="$EVID/prod_subscriptions_poll_${poll}.json"
  aws sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --output json > "$snap"

  live_file="$EVID/prod_live_endpoints_poll_${poll}.txt"
  jq -r '.Subscriptions[] | select(.Protocol=="email" or .Protocol=="email-json") | .Endpoint' "$snap" | sort -u > "$live_file"

  set_diff_file="$EVID/prod_set_diff_poll_${poll}.txt"
  set +e
  diff -u "$expected_sorted_file" "$live_file" > "$set_diff_file"
  diff_rc=$?

  jq -e -n \
    --slurpfile expected "$EXPECTED_INPUT" \
    --slurpfile live "$snap" \
    '($expected[0] | sort | unique) == ([$live[0].Subscriptions[]? | select(.Protocol=="email" or .Protocol=="email-json") | .Endpoint] | sort | unique)' >/dev/null
  set_eq_rc=$?

  jq -e -n \
    --slurpfile expected "$EXPECTED_INPUT" \
    --slurpfile live "$snap" \
    '([$live[0].Subscriptions[]? | select((.Protocol=="email" or .Protocol=="email-json") and (.Endpoint as $e | ($expected[0] | index($e)) != null)) | select(.SubscriptionArn=="PendingConfirmation")] | length) == 0' >/dev/null
  pending_eq_rc=$?
  set -e

  if [ "$set_eq_rc" -eq 0 ] && [ "$diff_rc" -eq 0 ]; then
    set_gate="PASS"
  else
    set_gate="FAIL"
    set_gate_failed=1
  fi

  pending_count="$(jq --slurpfile expected "$EXPECTED_INPUT" '[.Subscriptions[] | select((.Protocol=="email" or .Protocol=="email-json") and (.Endpoint as $e | ($expected[0] | index($e)) != null)) | select(.SubscriptionArn=="PendingConfirmation")] | length' "$snap")"
  if [ "$pending_eq_rc" -eq 0 ]; then
    pending_gate="PASS"
  else
    pending_gate="FAIL"
    pending_gate_failed=1
  fi

  printf "poll=%s set_equality=%s pending=%s pending_count=%s\n" "$poll" "$set_gate" "$pending_gate" "$pending_count" >> "$SUMMARY_FILE"
done

{
  echo "strict_set_equality_command:"
  echo "jq -e -n --slurpfile expected $EXPECTED_INPUT --slurpfile live $EVID/prod_subscriptions_poll_1.json '(\$expected[0] | sort | unique) == ([\$live[0].Subscriptions[]? | select(.Protocol==\"email\" or .Protocol==\"email-json\") | .Endpoint] | sort | unique)'"
  set +e
  jq -e -n \
    --slurpfile expected "$EXPECTED_INPUT" \
    --slurpfile live "$EVID/prod_subscriptions_poll_1.json" \
    '($expected[0] | sort | unique) == ([$live[0].Subscriptions[]? | select(.Protocol=="email" or .Protocol=="email-json") | .Endpoint] | sort | unique)' >/dev/null
  echo "set_equality_rc=$?"
} > "$SET_ASSERT_FILE"

{
  echo "strict_no_pending_command:"
  echo "jq -e -n --slurpfile expected $EXPECTED_INPUT --slurpfile live $EVID/prod_subscriptions_poll_1.json '([\$live[0].Subscriptions[]? | select((.Protocol==\"email\" or .Protocol==\"email-json\") and (.Endpoint as \$e | (\$expected[0] | index(\$e)) != null)) | select(.SubscriptionArn==\"PendingConfirmation\")] | length) == 0'"
  set +e
  jq -e -n \
    --slurpfile expected "$EXPECTED_INPUT" \
    --slurpfile live "$EVID/prod_subscriptions_poll_1.json" \
    '([$live[0].Subscriptions[]? | select((.Protocol=="email" or .Protocol=="email-json") and (.Endpoint as $e | ($expected[0] | index($e)) != null)) | select(.SubscriptionArn=="PendingConfirmation")] | length) == 0' >/dev/null
  echo "pending_assertion_rc=$?"
} > "$PENDING_ASSERT_FILE"

if [ "$set_gate_failed" -eq 0 ] && [ "$pending_gate_failed" -eq 0 ]; then
  echo "set_equality_gate_result=PASS" >> "$SUMMARY_FILE"
  echo "pending_confirmation_gate_result=PASS" >> "$SUMMARY_FILE"
  echo "verification_passed" > "$STATUS_FILE"
else
  if [ "$set_gate_failed" -eq 1 ]; then
    echo "set_equality_gate_result=FAIL" >> "$SUMMARY_FILE"
  else
    echo "set_equality_gate_result=PASS" >> "$SUMMARY_FILE"
  fi

  if [ "$pending_gate_failed" -eq 1 ]; then
    echo "pending_confirmation_gate_result=FAIL" >> "$SUMMARY_FILE"
  else
    echo "pending_confirmation_gate_result=PASS" >> "$SUMMARY_FILE"
  fi

  echo "verification_failed" > "$STATUS_FILE"
fi
