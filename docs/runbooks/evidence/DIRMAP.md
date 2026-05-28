<!-- [scrai:start] -->
## evidence

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| alert_emails | — |
| database-recovery | — |
| fleet-recovery | This directory contains timestamped operational checkpoints from a multi-stage fleet recovery process for fjcloud, spanning May 20-21, 2026, with each stage (diagnosis through closeout) capturing shell commands and verification scripts. |
| launch-rc-runs | This directory contains monitoring evidence from a production launch candidate deployment, specifically tracking usage metrics freshness through automated polling scripts executed during a 4-hour post-launch window with 8 measurement checkpoints. |
| may16_wave_deploy_verify | This directory contains a timestamped probe script from May 18, 2026 that validates authentication lockout behavior by capturing how the system responds to repeated failed login attempts. |
| monitoring-coverage | — |
| privacy_com_contract | A timestamped live-state probe from May 16, 2026 containing scripts and outputs that validate the current status of external vendor surfaces like Stripe, AWS, and other dependencies. |
| prod_db_leak_cleanup | This directory contains staged validation artifacts for cleaning up a production database leak, with Stage 4 comparing deployment termination runs for mutation consistency and Stage 5 validating the reproducibility and idempotency of tenant soft-deletion operations. |
| security-coverage-a3 | — |
| staging-isolation | — |
| staging-metering | — |
| stripe-pre-gut-snapshot | — |
<!-- [scrai:end] -->
