<!-- [scrai:start] -->
## user-data

| File | Summary |
| --- | --- |
| bootstrap.sh | fjcloud VM bootstrap script (baked into AMI, re-runnable)

Reads instance metadata from IMDS (instance tags), fetches secrets from
AWS SSM Parameter Store, writes env files, and starts services.

Idempotent: safe to re-run. |
<!-- [scrai:end] -->
