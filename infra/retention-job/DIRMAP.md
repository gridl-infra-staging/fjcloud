<!-- [scrai:start] -->
## retention-job

| File | Summary |
| --- | --- |

| Directory | Summary |
| --- | --- |
| src | The retention-job is a scheduled background task that permanently deletes customer records that have been marked as deleted for longer than a configurable retention period. |
| src | The retention-job crate is a periodic cleanup daemon that identifies customers deleted beyond a configurable retention period and hard-erases them from the system via an API call, with support for dry-run mode and per-run limits. |
<!-- [scrai:end] -->
