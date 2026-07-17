# Prod Customer Loop Canary Summary (20260518T032122Z)

| Check | Result |
|---|---|
| Invoke API status | 200 |
| Function error | present:Unhandled |
| Payload/log success marker | absent |
| Payload/log failure markers | present |
| Support-email canary FunctionError | present:Unhandled |
| Staging mirror CI | failure |
| Prod mirror CI | failure |
| Overall verdict | RED |

## Support Email Canary Probe
- Deployed image URI: 213880904778.dkr.ecr.us-east-1.amazonaws.com/fjcloud-prod-support-email-canary:latest
- Deployed architecture: ["arm64"]

## Notes
- Mirror CI status is risk context only; canary verdict is derived from function/payload/log rows.
