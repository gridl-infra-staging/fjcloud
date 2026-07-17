# Stage 2 CLI Cold-Customer Evidence

Created: 2026-06-05

## Purpose

Record the Stage 2 staging CLI rerun from the existing cold-customer owner. This file closes only the CLI question: whether the first post-batch search can observe the seeded hit inside the current retry/default contract.

## Command

The prescribed env file was used after clearing stale inherited AWS credential/profile variables from the parent shell. Direct probes showed the env file itself returned `STS_OK arn_suffix=stuart-cli`; the inherited shell credentials returned `InvalidAccessKeyId`.

```bash
set -o pipefail; env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_PROFILE -u AWS_DEFAULT_PROFILE CANARY_INDEX_REGION=us-east-1 CANARY_TEST_INBOX_DOMAIN=test.flapjack.foo COLD_CUSTOMER_SEARCH_MAX_ATTEMPTS=8 COLD_CUSTOMER_SEARCH_RETRY_SLEEP_SECONDS=2 bash scripts/canary/contracts/cold_customer_journey_walkthrough.sh --env staging --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret --evidence-dir docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/cli 2>&1 | tee docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/cli/run_stdout.log
```

Exit code: `0`

HEAD SHA at rerun: `52b6b0d85d3d1eda8a45f050b672641d2d352d1a`

## Owner Artifacts

`summary.json` proves the overall CLI owner passed:

```json
{
  "overall": "pass",
  "index_name": "cold-customer-canary2026060510051225303",
  "batch_accepted": 5,
  "seeded_record_object_id": "doc-0",
  "seeded_record_title": "Document 0",
  "verified": true
}
```

`cli_steps.jsonl` proves the `search_index` step returned the seeded hit:

```json
{
  "step": "search_index",
  "outcome": "pass",
  "http_status": 200,
  "response_body": {
    "nbHits": 1,
    "hits": [
      {
        "objectID": "doc-0",
        "title": "Document 0",
        "body": "Deterministic content 740b94c83fa5c1d2a780e34f8aa65508"
      }
    ]
  }
}
```

`run_stdout.log` contains:

```text
[cold-customer-walkthrough] probe passed; evidence=docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/cli
```

## In-Scope Fix

The first clean-AWS rerun reached `search_index` and failed with `seeded_record_missing`, but the owner artifacts only preserved response shape keys. The focused red regression was added to `scripts/tests/cold_customer_journey_walkthrough_test.sh`, then `cold_customer_append_step_evidence` was extended to preserve a sanitized `response_body` subset for `search_index` only. The evidence now keeps only the query, hit count, and seeded hit fields needed for diagnosis, while avoiding backend-only host metadata and other verbose internals. Non-search steps still do not persist sensitive response bodies.

## Validation

```text
bash scripts/tests/cold_customer_journey_walkthrough_test.sh
```

Result: pass, `11` tests.

```text
bash scripts/local-ci.sh --fast
```

Result: pass, `14` gates passed, `0` failed, `0` skipped.
