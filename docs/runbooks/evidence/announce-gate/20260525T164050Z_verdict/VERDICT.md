# Announce-gate verdict — 2026-05-25T16:40:56Z

- Fail count: 2
- Status: NOT-READY

## Passes
PASS: signup /signup -> 200
PASS: status page reads operational
PASS: status SERVICE_STATUS_UPDATED is recent: 2026-05-25
PASS: web_api_base_url_contract all envs PASS
PASS: oauth_redirect_uri_contract all envs PASS
PASS: fjcloud-prod-customer-loop-canary-not-running: OK
PASS: customer-loop EventBridge rule: ENABLED
PASS: no CloudWatch alarms in ALARM state
PASS: LB-2 and LB-3 GREEN in docs/runbooks/evidence/launch-verification/20260524T170404Z_GREEN/staging-browser
PASS: v1.0.1+ release tag on origin
PASS: prod SNS topic has ≥1 confirmed subscription (1)
PASS: subprocessor disclosure PASSED
PASS: Stripe latest event has no pending webhooks

## Failures
FAIL: landing / not 200 (got 303)
FAIL: prod /version.dev_sha='d42ffd5498a8492cf620a8a7735852655ad5a918' != main=965dba5ac61f1b42fdf482c2592c9949ee2171a3

## Probe evidence files
alarms_in_alarm.txt
canary_alarm.txt
canary_rule.txt
contract_probe.txt
failures.txt
landing.txt
oauth_probe.txt
origin_tags.txt
passes.txt
prod_sns_subs.json
prod_sns_subs.txt
prod_version_code.txt
prod_version.json
signup.txt
status_code.txt
status_page.html
stripe_code.txt
stripe_latest_event.json
subprocessor_overall.txt
subprocessor.txt
VERDICT.md
