# API 5xx Spike — Operator One-Pager

## Trigger symptoms
- CloudWatch alarm `fjcloud-${env}-alb-5xx-error-rate` is ALARM.
- Critical alert posted to Discord/Slack.
- Customer-visible API failures or elevated error reports.

## Immediate checks (first 10 minutes)
1. Open alarm history using
   `docs/runbooks/infra-alarm-triage.md` (`alb-5xx-error-rate`).
2. On API host, inspect recent errors:
   - `journalctl -u fjcloud-api --since "10 minutes ago" | grep -i error`
3. Check ALB target group health for failing/unhealthy targets.
4. Confirm latest deployed SHA via SSM parameter and recent deploy timeline.

## Decision flow
- Bad deploy suspected (errors began immediately after release):
  - Execute `ops/scripts/rollback.sh` for environment rollback.
- DB/connectivity symptoms (timeouts, connection refused):
  - Check RDS health/alarms and API DB connectivity logs.
- Single endpoint concentrated failures:
  - Isolate endpoint, gather request/error samples, triage owner quickly.
- Broad sustained failure across endpoints:
  - Treat as outage and escalate incident severity per canonical table.

## Response actions
1. Capture alarm timestamp, error sample, target health snapshot, deploy SHA.
2. Apply rollback or infra remediation based on branch above.
3. Re-check ALB 5xx metric and application logs after mitigation.
4. Continue monitoring until error rate stabilizes below alarm threshold.

## Response time
Use `docs/runbooks/incident-response.md` as the single severity/response-time
source of truth. Escalate from degraded service to full outage when failures
are broad, sustained, and customer-impacting across core API paths.

## Deep-dive references
- `docs/runbooks/infra-alarm-triage.md`
- `docs/runbooks/incident-response.md`
- `docs/runbooks/alerting.md`
