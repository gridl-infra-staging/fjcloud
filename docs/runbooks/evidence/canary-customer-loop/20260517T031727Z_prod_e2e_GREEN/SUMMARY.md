# Stage 3 Prod Canary Verdict (2026-05-17T03:17:27Z)

| Check | Evidence | Verdict |
|---|---|---|
| Invoke API status | StatusCode=200 | GREEN |
| Function error | FunctionError=Unhandled | RED |
| Payload success marker | grep customer loop canary completed successfully | RED |
| Failure-marker exclusion | grep -E step .* failed:|dispatch_failure_alert | RED |
| Mirror CI state at run time | staging conclusion=empty, prod conclusion=empty | RISK CONTEXT |

Overall Stage 3 canary verdict: RED.

Notes:
- Staging CI preflight was in-progress (empty conclusion) at run time.
- Prod CI preflight was failure at run time.
- Mirror CI state is recorded as external risk context only and does not substitute for canary verdict logic.
- CloudWatch and invoke-log-tail both show repeated failure at verify_email: verification email not found in inbox within timeout.
