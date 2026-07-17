# Database Fingerprints

Fresh Stage 3 receipts show no DB-source drift.

## Instance Selection

See `ec2_running_instances.md` and `remote_database_fingerprints.txt`.

- running `fjcloud-api-staging` targets: 1
- selected/remote instance: `i-0fbc6d6bbbc8bdc6d`
- SSM ping: `Online`

## Fingerprints

- `/etc/fjcloud/env`: `fjcloud-staging.cabwlew6jcjl.us-east-1.rds.amazonaws.com:5432/fjcloud`, `sha256_16=a377bb0163e33e75`
- `/proc/<MainPID>/environ`: `fjcloud-staging.cabwlew6jcjl.us-east-1.rds.amazonaws.com:5432/fjcloud`, `sha256_16=a377bb0163e33e75`
- `/fjcloud/staging/database_url`: `fjcloud-staging.cabwlew6jcjl.us-east-1.rds.amazonaws.com:5432/fjcloud`, `sha256_16=a377bb0163e33e75`
- `systemctl show --property=Environment fjcloud-api`: `DATABASE_URL` missing, expected because `ops/systemd/fjcloud-api.service` uses `EnvironmentFile=-/etc/fjcloud/env`.

## Decision

No staging host env, SSM parameter, probe DB source, or `ssm_exec_staging.sh` target-selection fix was justified by these receipts.
