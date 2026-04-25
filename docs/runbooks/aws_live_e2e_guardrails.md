# AWS Live E2E Guardrails

Operator runbook for repo-owned live AWS spend and TTL cleanup guardrails.

## Purpose

Define the canonical, reproducible operator workflow that keeps two boundaries explicit:

- implemented repo-owned guardrail wiring (Terraform + janitor contracts)
- operator-owned live prerequisites and explicit enablement gates

## Scope

In scope:

- CloudTrail retention/export ownership in `ops/terraform/monitoring/`.
- AWS Budgets spend-control contract surface in `ops/terraform/monitoring/`.
- Fail-closed TTL cleanup guardrails in `ops/scripts/live_e2e_ttl_janitor.sh`.
- Non-destructive validation entrypoints that verify contracts without live cleanup.

Out of scope:

- Scheduled/nightly live execution by default.
- Live AWS mutation without explicit operator opt-in.
- Inventing monthly spend/action-owner values that must be operator-supplied.
- Applying TTL janitor cleanup to durable staging resources under `ops/terraform/data/`.

## Canonical Ownership

### Spend Controls (`ops/terraform/monitoring/`)

Single source of truth:

- [`ops/terraform/monitoring/main.tf`](../../ops/terraform/monitoring/main.tf)
- [`ops/terraform/monitoring/variables.tf`](../../ops/terraform/monitoring/variables.tf)
- [`ops/terraform/monitoring/outputs.tf`](../../ops/terraform/monitoring/outputs.tf)

Implemented now (repo-owned):

- CloudTrail trail + export bucket retention/policy contract.
- `aws_budgets_budget.live_e2e_spend` declaration gated on `live_e2e_monthly_spend_limit_usd`.
- `aws_budgets_budget_action.live_e2e_spend_enforcement` declaration gated by `live_e2e_budget_action_enabled` (default `false`).
- Budget action creation is explicitly ordered after budget creation.
- Explicit preconditions requiring all action identity inputs before enforcement can be enabled:
  - `live_e2e_budget_action_principal_arn`
  - `live_e2e_budget_action_policy_arn`
  - `live_e2e_budget_action_role_name`
  - `live_e2e_budget_action_execution_role_arn`
- Outputs exposing budget name/configured state/action-enabled state.

`_shared` ownership boundary:

- [`ops/terraform/_shared/main.tf`](../../ops/terraform/_shared/main.tf) is pass-through wiring only.
- `_shared` forwards inputs to `monitoring`; it does not declare duplicate `aws_*` spend/CloudTrail resources.

Operator-blocked live prerequisites:

- Budget-period semantics are already decided: `$20/day` means `$600/month` via `live_e2e_monthly_spend_limit_usd`, and strict calendar-day enforcement is not implemented.
- The current prep artifact status is `blocked` until operators provide the remaining identity/resource inputs:
  - `api_instance_id` via `--api-instance-id`
  - `db_instance_identifier` via `--db-instance-identifier`
  - `alb_arn_suffix` via `--alb-arn-suffix`
  - `live_e2e_budget_action_principal_arn` via `--budget-action-principal-arn`
  - `live_e2e_budget_action_policy_arn` via `--budget-action-policy-arn`
  - `live_e2e_budget_action_role_name` via `--budget-action-role-name`
  - `live_e2e_budget_action_execution_role_arn` via `--budget-action-execution-role-arn`
- Keep `ops/terraform/monitoring/variables.tf` as the canonical variable/default contract; treat generated `proposal.auto.tfvars.example` as run-scoped input materialization, not a second default table.
- Apply with explicit `live_e2e_budget_action_enabled=true` only when live enforcement is intended.

### Budget Guardrail Prep (`ops/scripts/live_e2e_budget_guardrail_prep.sh`)

Single source of truth:

- [`ops/scripts/live_e2e_budget_guardrail_prep.sh`](../../ops/scripts/live_e2e_budget_guardrail_prep.sh)
- [`scripts/tests/live_e2e_budget_guardrail_prep_test.sh`](../../scripts/tests/live_e2e_budget_guardrail_prep_test.sh)

Operator-facing prep command (non-mutating):

```bash
bash ops/scripts/live_e2e_budget_guardrail_prep.sh \
  --env staging \
  --region us-east-1 \
  --artifact-dir <dir> \
  --monthly-spend-limit-usd <usd> \
  --budget-action-principal-arn <arn> \
  --budget-action-policy-arn <arn> \
  --budget-action-role-name <name> \
  --budget-action-execution-role-arn <arn>
```

Optional explicit enablement proposal:

```bash
bash ops/scripts/live_e2e_budget_guardrail_prep.sh \
  --env staging \
  --region us-east-1 \
  --artifact-dir <dir> \
  --monthly-spend-limit-usd <usd> \
  --budget-action-principal-arn <arn> \
  --budget-action-policy-arn <arn> \
  --budget-action-role-name <name> \
  --budget-action-execution-role-arn <arn> \
  --enable-action-proposal
```

Prep-script contract:

- Never runs Terraform; it only prepares operator-reviewed inputs and plan guidance.
- Writes a private run directory under the caller-selected `--artifact-dir`.
- Emits `summary.json` to stdout and to the run directory as the machine-readable source of truth.
- `blocked` exits `0`, preserves ordered `missing_fields` and `missing_flags`, and omits `proposal.auto.tfvars.example`, `terraform_plan_command.txt`, `plan_command`, and `proposed_variables`.
- `proposal_ready` exits `0` only after read-only AWS discovery resolves monitoring identifiers and includes run-scoped `proposal.auto.tfvars.example` + `terraform_plan_command.txt` artifacts plus `plan_command` and `proposed_variables` in `summary.json`.
- Uses read-only AWS CLI discovery with pager disabled (`AWS_PAGER` empty), `--no-cli-pager`, and explicit `--region`.
- Redacts known secret values from captured logs and keeps artifacts user-private even under permissive shell umasks.

### TTL Cleanup (`ops/scripts/live_e2e_ttl_janitor.sh`)

Single source of truth:

- [`ops/scripts/live_e2e_ttl_janitor.sh`](../../ops/scripts/live_e2e_ttl_janitor.sh)
- [`scripts/tests/live_e2e_ttl_janitor_test.sh`](../../scripts/tests/live_e2e_ttl_janitor_test.sh)

Implemented safety contract:

- Dry-run by default.
- Selector requirement is fail-closed: at least one of `--owner` or `--test-run-id` is required.
- Selector values must be single tag values without commas or whitespace so AWS CLI shorthand parsing cannot widen the filter set.
- Required lifecycle tags per discovered resource:
  - `test_run_id`
  - `owner`
  - `ttl_expires_at`
  - `environment`
- Discovery uses Resource Groups Tagging API with explicit resource-type allowlist (`ec2:instance`, `rds:db`).
- Destructive deletion is double-gated and fails closed unless both are set:
  - `--execute`
  - `FJCLOUD_ALLOW_LIVE_E2E_DELETE=1`

Out-of-scope ownership boundary:

- `ops/terraform/data/` resources are durable staging ownership and not TTL-janitor cleanup targets.

### Evidence Wrapper (`scripts/launch/live_e2e_evidence.sh`)

Single source of truth:

- [`scripts/launch/live_e2e_evidence.sh`](../../scripts/launch/live_e2e_evidence.sh)
- [`scripts/tests/live_e2e_evidence_test.sh`](../../scripts/tests/live_e2e_evidence_test.sh)
- [`scripts/tests/live_e2e_evidence_docs_test.sh`](../../scripts/tests/live_e2e_evidence_docs_test.sh)

Operator-facing wrapper command (default non-mutating run):

```bash
bash scripts/launch/live_e2e_evidence.sh \
  --env staging \
  --domain flapjack.foo \
  --artifact-dir <dir> \
  --ami-id <ami-xxxxxxxxxxxxxxxxx> \
  --env-file .secret/.env.secret
```

Optional live operations are intentionally explicit:

```bash
# Add --apply to run terraform apply after plan.
# Add --run-deploy with --release-sha <40-char-sha>.
# Add --run-migrate to execute migration + idempotency check.
# Add --run-rollback with --rollback-sha <40-char-sha>.
```

Wrapper/owner boundary:

- `scripts/launch/live_e2e_evidence.sh` is the top-level evidence wrapper.
- Spend/TTL guardrails stay owned by the Terraform and janitor contracts above.
- Runtime infra assertions are delegated to [`ops/terraform/tests_stage7_runtime_smoke.sh`](../../ops/terraform/tests_stage7_runtime_smoke.sh).
- Credentialed billing evidence is delegated to [`scripts/staging_billing_rehearsal.sh`](../../scripts/staging_billing_rehearsal.sh) only when the operator adds `--run-billing-rehearsal --month <YYYY-MM> --confirm-live-mutation`.

The wrapper writes run-scoped artifacts under the caller-selected
`--artifact-dir`, and `summary.json` in the run directory is the run-level
machine-readable source of truth.

Interpret `summary.json` fields as:

- `checks` for runtime-smoke owner results.
- `credentialed_checks` for optional billing rehearsal.
- blocked credentialed billing rows keep `artifact_path` empty.
- `external_blockers` for caller/operator blockers; generated rerun commands are shell-escaped before they are written into `summary.json`.
- `overall_verdict` values capture run-level outcome (`pass`, `fail`, `blocked`).

blocked prerequisites exit `0` and do not imply launch readiness. Executed
assertion failures are `fail`.

The runtime owner harness validates these live contracts:

- ACM certificate status is `ISSUED`.
- ALB has an HTTPS listener on `443`.
- Target group has healthy targets.
- Cloudflare public records CNAME to ALB.
- SES identity + DKIM report `SUCCESS`.
- `https://api.<domain>/health` returns success.

Evidence and operator follow-up:

- When checks pass, keep runtime/evidence updates in [`docs/runbooks/staging-evidence.md`](./staging-evidence.md) and [`docs/runbooks/infra-evidence-bundle.md`](./infra-evidence-bundle.md) instead of duplicating evidence logs here.
- When checks fail, capture the failing command, exit code, and the wrapper-selected run directory under `--artifact-dir`; include `summary.json` and delegated logs from that run directory.
- Classify failures by contract surface first: static ownership contract, Terraform plan/apply surface, runtime environment assertion, TTL janitor discovery, or credentialed billing evidence.
- Re-run only the failed command after the targeted fix.

## Guardrail Validation Commands

Run from repo root.

### 1) Static contracts (non-destructive)

```bash
bash ops/terraform/tests_stage7_static.sh
bash ops/terraform/tests_stage8_static.sh
bash scripts/tests/live_e2e_budget_guardrail_prep_test.sh
bash scripts/tests/live_e2e_ttl_janitor_test.sh
bash scripts/tests/live_e2e_evidence_test.sh
bash scripts/tests/live_e2e_evidence_docs_test.sh
```

### 2) Validation bundle (non-destructive)

```bash
bash ops/terraform/validate_all.sh
```

`validate_all.sh` validates Terraform module contracts, security-group guardrails, and janitor presence/gating contracts only. It does not execute cleanup.

### 3) Budget-guardrail artifact consumption path

```bash
bash ops/terraform/validate_all.sh --budget-guardrail-artifact <run-dir-or-summary.json>
```

- Accepts either the run directory or `summary.json` path emitted by `ops/scripts/live_e2e_budget_guardrail_prep.sh`.
- For `blocked`, validates ordered `missing_fields`/`missing_flags` pairing and confirms omission of plan payload/artifact files; Terraform planning is skipped.
- For `proposal_ready`, validates `summary.json`, `proposal.auto.tfvars.example`, and `terraform_plan_command.txt` consistency, then runs `terraform plan -input=false` with that proposal var-file.
- This path is non-destructive and limited to planning; it does not run `terraform apply`.

### 4) Janitor entrypoint usage

Show help:

```bash
bash ops/scripts/live_e2e_ttl_janitor.sh --help
```

Safe dry-run example:

```bash
bash ops/scripts/live_e2e_ttl_janitor.sh \
  --environment live-e2e \
  --owner <owner-id>
```

Destructive mode (explicit opt-in only):

```bash
FJCLOUD_ALLOW_LIVE_E2E_DELETE=1 \
bash ops/scripts/live_e2e_ttl_janitor.sh \
  --environment live-e2e \
  --owner <owner-id> \
  --execute
```

### 5) Guardrail env reference

- `FJCLOUD_ALLOW_LIVE_E2E_DELETE` is documented in [`docs/env-vars.md`](../env-vars.md) under `## Live E2E Guardrails`.

## Implemented vs Operator-Blocked

Implemented now:

- Monitoring Terraform owns CloudTrail retention/export and budget guardrail wiring.
- Budget guardrail prep emits run-scoped `summary.json` as source of truth with exact status split: `blocked` exits `0` with ordered `missing_fields`/`missing_flags` and omits plan payload artifacts; `proposal_ready` exits `0` only after read-only discovery and includes proposal artifacts.
- `bash ops/terraform/validate_all.sh --budget-guardrail-artifact <run-dir-or-summary.json>` consumes prep artifacts and allows Terraform planning only for `proposal_ready` via `terraform plan -input=false`.
- `_shared` stays pass-through only for spend-action inputs.
- Janitor script/tests enforce selector + tag + allowlist + double-gated delete contracts.
- Live evidence wrapper/tests own run-scoped artifact capture and delegated runtime/billing orchestration.
- Static and bundle validation entrypoints exist for repeatable non-destructive verification.

Operator-blocked (intentionally unresolved):

- Budget-period semantics are fixed to monthly-equivalent: `$20/day` means `$600/month` via `live_e2e_monthly_spend_limit_usd`; strict calendar-day enforcement is not implemented in the current contract.
- The current prep artifact remains `blocked` until operators supply these missing field/flag pairs: `api_instance_id`/`--api-instance-id`, `db_instance_identifier`/`--db-instance-identifier`, `alb_arn_suffix`/`--alb-arn-suffix`, `live_e2e_budget_action_principal_arn`/`--budget-action-principal-arn`, `live_e2e_budget_action_policy_arn`/`--budget-action-policy-arn`, `live_e2e_budget_action_role_name`/`--budget-action-role-name`, and `live_e2e_budget_action_execution_role_arn`/`--budget-action-execution-role-arn`.
- Explicit live apply with `live_e2e_budget_action_enabled=true` when enforcement is intended.
- SES live readiness gates and credentialed live billing/webhook evidence for scheduled live runs.

## Sources

- [`ops/terraform/monitoring/main.tf`](../../ops/terraform/monitoring/main.tf)
- [`ops/terraform/monitoring/variables.tf`](../../ops/terraform/monitoring/variables.tf)
- [`ops/terraform/monitoring/outputs.tf`](../../ops/terraform/monitoring/outputs.tf)
- [`ops/terraform/_shared/main.tf`](../../ops/terraform/_shared/main.tf)
- [`ops/terraform/_shared/variables.tf`](../../ops/terraform/_shared/variables.tf)
- [`ops/scripts/live_e2e_ttl_janitor.sh`](../../ops/scripts/live_e2e_ttl_janitor.sh)
- [`ops/scripts/live_e2e_budget_guardrail_prep.sh`](../../ops/scripts/live_e2e_budget_guardrail_prep.sh)
- [`scripts/tests/live_e2e_budget_guardrail_prep_test.sh`](../../scripts/tests/live_e2e_budget_guardrail_prep_test.sh)
- [`scripts/tests/live_e2e_ttl_janitor_test.sh`](../../scripts/tests/live_e2e_ttl_janitor_test.sh)
- [`scripts/launch/live_e2e_evidence.sh`](../../scripts/launch/live_e2e_evidence.sh)
- [`scripts/tests/live_e2e_evidence_test.sh`](../../scripts/tests/live_e2e_evidence_test.sh)
- [`scripts/tests/live_e2e_evidence_docs_test.sh`](../../scripts/tests/live_e2e_evidence_docs_test.sh)
- [`ops/terraform/tests_stage7_static.sh`](../../ops/terraform/tests_stage7_static.sh)
- [`ops/terraform/tests_stage7_runtime_smoke.sh`](../../ops/terraform/tests_stage7_runtime_smoke.sh)
- [`ops/terraform/tests_stage8_static.sh`](../../ops/terraform/tests_stage8_static.sh)
- [`ops/terraform/validate_all.sh`](../../ops/terraform/validate_all.sh)
- [`docs/runbooks/infra-evidence-bundle.md`](./infra-evidence-bundle.md)
- [`docs/runbooks/staging-evidence.md`](./staging-evidence.md)
- [`docs/env-vars.md`](../env-vars.md)
