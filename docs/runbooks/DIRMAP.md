<!-- [scrai:start] -->
## runbooks

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| evidence | The evidence directory contains production operational artifacts: launch-rc-runs holds timestamped monitoring and validation scripts for the first 4 hours after deployment, while prod_db_leak_cleanup contains the later stages of a multi-stage cleanup pipeline addressing a customer data leak through systematic deployment termination and tenant soft-deletion. |
| evidence | The evidence directory contains production deployment and cleanup procedures: launch-rc-runs manages post-deployment monitoring and health validation during the critical first 4 hours, while prod_db_leak_cleanup executes the final stages of a database leak remediation with safe customer deployment termination and reversible tenant data cleanup. |
<!-- [scrai:end] -->
