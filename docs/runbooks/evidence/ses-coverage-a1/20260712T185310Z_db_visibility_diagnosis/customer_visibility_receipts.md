# Customer row visibility through probe_sql_single_value

- probe_email: stage1db202607121858507126@test.flapjack.foo
- customer_id: abc9d7db-bf74-4cdf-949b-3135f61b8bab
- id_query_email_attempt_1: stage1db202607121858507126@test.flapjack.foo
- email_query_id_attempt_1: abc9d7db-bf74-4cdf-949b-3135f61b8bab
- repeat_sleep_seconds: 2
- id_query_email_attempt_2: stage1db202607121858507126@test.flapjack.foo
- email_query_id_attempt_2: abc9d7db-bf74-4cdf-949b-3135f61b8bab
- expected_email: stage1db202607121858507126@test.flapjack.foo
- expected_id: abc9d7db-bf74-4cdf-949b-3135f61b8bab
- query owner: scripts/lib/clickthrough_probe_common.sh:99-128 via scripts/launch/ssm_exec_staging.sh
