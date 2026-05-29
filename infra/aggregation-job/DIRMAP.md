<!-- [scrai:start] -->
## aggregation-job

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| src | The aggregation-job crate implements the periodic service responsible for aggregating metering data from collected usage metrics into billing-cycle data. |
| src | The aggregation-job is a daily batch job that initializes structured logging, loads configuration from environment variables, connects to PostgreSQL, and executes a rollup query to aggregate metering data for a target date window. |
<!-- [scrai:end] -->
