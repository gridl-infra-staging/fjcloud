# Stage 2 CLI Evidence Deliverable

Created: 2026-06-04

## Purpose

Record the Stage 2 non-browser cold-customer rerun evidence under the Stage 1 UTC root. This document summarizes the owner commands, concrete artifacts, and open questions from the final staging-targeted rerun. It is not the Stage 5 closeout findings document.

## Sources

- Stage 1 baseline: `docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/preflight.md`
- Validator owner: `scripts/validate_customer_quickstart.sh:217-230`, `scripts/validate_customer_quickstart.sh:310-342`, `scripts/validate_customer_quickstart.sh:727-783`
- Walkthrough owner: `scripts/canary/contracts/cold_customer_journey_walkthrough.sh:192-230`, `scripts/canary/contracts/cold_customer_journey_walkthrough.sh:666-699`
- Walkthrough contract expectations: `scripts/canary/contracts/cold_customer_journey_walkthrough_contract_test.sh:108-143`, `scripts/canary/contracts/cold_customer_journey_walkthrough_contract_test.sh:317-370`
- Admin auth owner: `infra/api/src/auth/admin.rs:24-28`
- Fresh Stage 2 artifacts: `run_stdout.log`, `summary.json`, `cli_steps.jsonl`

## Evidence Summary

- The external canonical secret seam at `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret` was repaired before the final rerun: the missing full-flow prerequisite keys were added and `API_URL` was corrected to the staging host.
- The final validator rerun used `FJCLOUD_SECRET_FILE=/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret` and wrote `run_stdout.log`.
- `run_stdout.log` contains the owner-emitted quickstart marker inventory and migration marker inventory from `validate_doc_marker_contracts()`.
- The validator completed inbound email roundtrip, signup, email verification, index create/write/search, migration cases, index delete, account delete, and admin cleanup, then emitted `staging full-flow validation passed`.
- The shipped walkthrough owner exited `0`, wrote `summary.json` and `cli_steps.jsonl`, and emitted `probe passed`.
- Artifact validation proved `summary.overall=pass`, `seeded_record_object_id=doc-0`, `seeded_record_title=Document 0`, and ordered steps `register`, `verify_email`, `confirm_verified`, `create_index`, `batch_write`, `search_index`.

## Direct Evidence

The Stage 1 baseline fixed the interpretation target before Stage 2 ran: staging `/version` reported `dev_sha=c62287ada3f7662305032263766441fa4388ac98`, and the Stage 1 ancestry gates proved that SHA contains `e940f08f9` and is still an ancestor of fetched `origin/main`.

The final Stage 2 validator evidence is in `run_stdout.log`. The marker-contract owner emitted:

```text
[validate_customer_quickstart] quickstart markers: auth_register auth_verify_email indexes_create indexes_batch_add_object indexes_search
[validate_customer_quickstart] migration markers: migration_indexes_list migration_indexes_create migration_indexes_batch_add_object migration_indexes_search migration_indexes_get_object migration_indexes_batch_update_object migration_indexes_delete_object migration_indexes_save_synonym migration_indexes_save_rule
```

The same log records the non-browser full-flow owner verdicts:

```text
[customer-loop-canary] admin cleanup completed for tenant c995f90d-22db-45f4-a3c2-01dace264951
[customer-loop-canary] customer quickstart signup/verify/search flow succeeded
[customer-loop-canary] staging full-flow validation passed
```

The walkthrough owner then wrote `summary.json` with this pass payload:

```json
{
  "batch_accepted": 5,
  "customer_id": "ffbf751b-c10b-401c-8551-7779cf5be9cd",
  "overall": "pass",
  "seeded_record_object_id": "doc-0",
  "seeded_record_title": "Document 0",
  "verified": true
}
```

`cli_steps.jsonl` contains the expected ordered customer path: `register`, `verify_email`, `confirm_verified`, `create_index`, `batch_write`, and `search_index`, followed by cleanup steps `delete_index`, `delete_account`, and `admin_cleanup`.

## Decisions

- Stage 2 consumed the shipped owners only: `validate_doc_marker_contracts()`, `validate_full_flow_prereqs()`, `run_inbound_roundtrip()`, `run_signup_verify_search_flow()`, `cold_customer_prepare_environment()`, and `cold_customer_main()`.
- No `QUICKSTART_*` overrides, alternate bootstrap wrapper, fixture root, or new probe path was introduced. The only environment seam used for the final validator and walkthrough was `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret`.
- The intermediate production-host rerun is treated as investigation context, not as the Stage 2 staging verdict. The final staging-targeted validator and walkthrough both passed against `https://api.staging.flapjack.foo`.

## Open Questions

- During investigation, one intermediate rerun used the unrepaired canonical secret file while it still pointed `API_URL` at the production host. The customer-loop owner proved account deletion by reaching the success log after `/account` returned 204 or 404. S15 then re-probed production admin auth read-only for customer `041e6477-7a58-4a96-ac05-e2ce1ddc18e3`: the S14 targeted cleanup shape used `Authorization: Bearer ${ADMIN_KEY}` and returned HTTP 401, while the code-owned `x-admin-key` header returned HTTP 200 for `GET /admin/tenants/{customer_id}` on `api.flapjack.foo` with the same prod SSM-hydrated value. The authorization question is closed as a probe-header error; the remaining open question is whether Stage 4 or ops wants to run a destructive prod `DELETE` cleanup for that already account-deleted canary tenant.
