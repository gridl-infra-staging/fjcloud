# Stage 1 IAM Discovery (No Mutation)

## Scope and Contract

- Stage: 1 of 4
- Objective: produce evidence-backed IAM inventory for guarded Terraform changes and rollback
- Mutation policy: read-only IAM API calls only
- AWS region pin: us-east-1
- Pager disabled: AWS_PAGER empty and --no-cli-pager on every AWS call
- Evidence root pointer file: .lane7_evidence_dir
- Evidence root directory: docs/runbooks/evidence/secret-rotation/20260428T192916Z_iam_rotation

## SSOT References Used

- deploy workflow consumer: .github/workflows/ci.yml:313
- deploy role shape owner: ops/iam/github-actions-deploy-role.tf
- instance role/profile shape owner: ops/iam/fjcloud-instance-role.tf
- deploy action surface reference: ops/scripts/deploy.sh
- staging account SSOT source: docs/runbooks/staging-evidence.md:249
- staging account literal from runbook SSOT: 213880904778
- anti-tautology rule: staging account id in discovery_summary.json is runbook-derived, not STS-derived

## Operator Identity Evidence

- STS identity artifact: sts_caller_identity.json
- Purpose: operator identity proof only
- Guardrail: do not derive staging_account_id from STS output

## Deploy Workflow Consumer Contract

- .github/workflows/ci.yml line 313 uses role-to-assume: ${{ secrets.DEPLOY_IAM_ROLE_ARN }}
- Discovery maps this secret contract to OIDC-trusted role candidates below

## Deploy Role Candidate Mapping

- OIDC subject required by owner file: repo:gridl-infra-staging/fjcloud:ref:refs/heads/main
- Candidate role names (from trust policy scan):
- fjcloud-deploy => arn:aws:iam::213880904778:role/fjcloud-deploy

## Deploy Role Ambiguity Review Against deploy.sh Action Surface

- deploy.sh relies on S3 artifact read/write/list operations
- deploy.sh relies on EC2 describe-instances lookup
- deploy.sh relies on SSM send-command/get-command-invocation and parameter read/write
- Candidate role policies are captured as attached and inline snapshots for evidence-backed comparison
- If multiple candidates exist, the gap is retained explicitly instead of guessing

## Instance Role/Profile Mapping

- Expected role name from owner file: fjcloud-instance-role
- Expected instance profile name from owner file: fjcloud-instance-profile
- Discovered instance role candidates:
- fjcloud-instance-role => arn:aws:iam::213880904778:role/fjcloud-instance-role

## Local Dev Role Mapping

- Candidate local_dev role names:
- missing/not present

## Human SSO Role Mapping

- Candidate human_sso role names:
- missing/not present

## Managed Role Snapshot Baseline

- Snapshot root: roles/<role_name>/
- Required baseline files per role:
  - get-role.json
  - list-attached-role-policies.json
  - list-role-policies.json
  - get-role-policy__<policy>.json for each inline policy name
- Canonical source for full inventory remains iam_roles_all.json
- iam_roles_filtered.json is convenience-only and non-canonical

## Unresolved Gaps and Notes
- No deploy-role ambiguity requiring gap note beyond baseline mapping.
- local_dev role missing/not present in current account inventory.
- human_sso role missing/not present in current account inventory.

## Artifact Index

- sts_caller_identity.json
- commands.log
- iam_roles_all.json
- iam_roles_filtered.json
- deploy_role_candidates.txt
- instance_role_candidates.txt
- local_dev_role_candidates.txt
- human_sso_role_candidates.txt
- managed_role_candidates.txt
- roles/<role_name>/* snapshots
- discovery.md
- discovery_summary.json
- SUMMARY.md

## No-Mutation Statement

- Stage 1 used read-only IAM/STS APIs only.
- commands.log contains every AWS CLI invocation used in this stage.
- Write verbs were explicitly checked and none were present.
