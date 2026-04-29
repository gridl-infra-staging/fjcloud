# Stage 1 Summary

## Artifact files

- .lane7_evidence_dir pointer: docs/runbooks/evidence/secret-rotation/20260428T192916Z_iam_rotation
- sts_caller_identity.json
- commands.log
- iam_roles_all.json
- iam_roles_filtered.json
- discovery.md
- discovery_summary.json
- deploy/local/instance/sso candidate text files
- roles/<role_name> snapshot directories

## Resolved role mappings

- deploy workflow role: fjcloud-deploy (arn:aws:iam::213880904778:role/fjcloud-deploy)
- staging EC2 role expected: fjcloud-instance-role
- local_dev role: missing (missing)
- human_sso roles: 0 candidates

## Unresolved gaps

- Deploy-role ambiguity candidates: 1
- Local-dev role present: no

## No mutation statement

No IAM mutation APIs were invoked. commands.log includes all AWS CLI invocations; mutation-verb grep gate passed.
