# Announce-gate verdict — 2026-05-25T08:43:17Z

- Fail count: 3
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
PASS: Stripe latest event has no pending webhooks

## Failures
FAIL: landing / not 200 (got 303)
FAIL: prod /version.dev_sha='d42ffd5498a8492cf620a8a7735852655ad5a918' != main=f718758c0649ea86351883c521539f724ab378b6
FAIL: validate_subprocessor_disclosure.sh non-zero exit

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
subprocessor.txt
VERDICT.md
