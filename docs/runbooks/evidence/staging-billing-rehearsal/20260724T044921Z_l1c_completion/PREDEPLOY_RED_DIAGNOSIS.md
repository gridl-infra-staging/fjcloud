# Predeploy red-path diagnosis

Observation window: 2026-07-24T04:57:38Z through 2026-07-24T05:04:14Z.

## Exact data state

The current staging row is `ACTION_REQUIRED` with reason `rollups_stale`.
The canonical SSM SQL returned:

| Table | Maximum timestamp/date | Total rows | Fresh rows (48h) |
| --- | --- | ---: | ---: |
| `usage_daily` | date `2026-07-17`; aggregated `2026-07-18T01:00:06.804727Z` | 164 | 0 |
| `usage_records` | recorded `2026-07-17T20:12:23.750566Z` | 113201 | 0 |

Receipt: `command_outputs/011_predeploy_usage_sql.log`.

The aggregation timer is loaded, enabled, and active. It fired at
2026-07-24T01:00:38Z; its oneshot service exited successfully. The seven-day
journal shows successful daily execution from July 18 through July 24. The
job has no fresh producer rows to aggregate, so neither the scheduler nor
`ROLLUP_SQL` is the demonstrated failing owner.

## Demonstrated owner

The single demonstrated owner is the dataplane lifecycle contract represented
by `ops/systemd/fj-metering-agent.service`. The API-server copy of that unit is
an intentionally dormant ghost: current `ops/scripts/deploy.sh` excludes the
metering binary/unit and expects `/etc/fjcloud/metering-env` to be absent on
the control-plane host. Its inactive status is therefore not evidence that
the API host should start producing usage.

The fresh SQL reproduces the predecessor's producer-boundary failure. The
already-merged repair commit `e36327f4b880cf3a623e78cb839d211305425ea9`
fixes the dataplane bootstrap activation owner in
`ops/user-data/bootstrap.sh` by atomically enabling and starting
`fj-metering-agent`. Its regression contract is in
`ops/terraform/tests_iac_validation_static.sh`. The commit is an ancestor of
both local HEAD and current `origin/main`; the owner files are identical
between them. The focused current-tree test passed 103/103, including the
three exact activation assertions
(`command_outputs/016_metering_bootstrap_contract.log`).

No duplicate repair is warranted before deploying the accepted `origin/main`
state. Post-deploy SQL and the live-state row remain the acceptance oracle.
