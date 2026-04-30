# Stage 5 Publication Evidence

- utc_stamp: 20260430T040514Z
- dev_doc_pass_sha: 572a6c2b901d63ffe41a457bbbe373f8f2803aa1
- staging_doc_pass_sha: b8c1133497d4b53d8269ac9f652ece4e987ac2a0
- debbie_sync_timestamp_utc: 2026-04-30T05:41:26Z
- ci_run_url: https://github.com/gridl-infra-staging/fjcloud/actions/runs/25149099625
- ci_conclusion: in_progress (non-terminal as of 2026-04-30T05:41:26Z)

## First-pass doc publication result
- Command:
  `debbie sync staging`
- Result: sync completed successfully and mirrored the runbook reconciliation delta to staging, followed by explicit staging commit `b8c1133497d4b53d8269ac9f652ece4e987ac2a0`.

## CI discovery command transcript

```bash
# command
gh run list --repo gridl-infra-staging/fjcloud --limit 20 --json databaseId,headSha,status,conclusion,url,workflowName,displayTitle
# resolved run row for staging_doc_pass_sha=b8c1133497d4b53d8269ac9f652ece4e987ac2a0
databaseId=25149099625 status=queued conclusion= url=https://github.com/gridl-infra-staging/fjcloud/actions/runs/25149099625 workflowName=CI

# command
gh run view 25149099625 --repo gridl-infra-staging/fjcloud --json status,conclusion,url,headSha
# bounded poll samples (latest)
status=in_progress conclusion= headSha=b8c1133497d4b53d8269ac9f652ece4e987ac2a0 url=https://github.com/gridl-infra-staging/fjcloud/actions/runs/25149099625
```

## SHA mapping check
- Verified `gh run view 25149099625` reports `headSha=b8c1133497d4b53d8269ac9f652ece4e987ac2a0`, matching the staging doc-pass commit SHA.

## Notes
- Staging mirror root does not include `PRIORITIES.md` or `ROADMAP.md` under current `.debbie.toml` sync scope; runbook evidence remains the mirrored owner lane for this publication.
- CI terminal conclusion is still pending and requires a continuation poll/update pass.
