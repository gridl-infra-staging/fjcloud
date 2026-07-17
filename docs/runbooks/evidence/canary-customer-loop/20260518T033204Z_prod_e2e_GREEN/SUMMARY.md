# Prod Customer Loop Canary Summary (20260518T033204Z)

| Check | Result |
|---|---|
| Invoke API status | 200 |
| Function error | present:Unhandled |
| Payload/log success marker | absent |
| Payload/log failure markers | present |
| Support-email canary FunctionError | present:Unhandled |
| Staging mirror CI |  |
| Prod mirror CI |  |
| Overall verdict | RED |

## Deployed Image Probes
- Customer-loop image URI: 213880904778.dkr.ecr.us-east-1.amazonaws.com/fjcloud-prod-customer-loop-canary:9e9714cf7137
- Support-email image URI: 213880904778.dkr.ecr.us-east-1.amazonaws.com/fjcloud-prod-support-email-canary:latest

## Notes
- Mirror CI status is risk context only; canary verdict is derived from function/payload/log rows.
