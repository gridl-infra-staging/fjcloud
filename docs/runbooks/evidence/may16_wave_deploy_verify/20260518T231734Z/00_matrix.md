# may16 Wave Deploy-Verify Sweep - Stage 1 Matrix SSOT

UTC bundle: 20260518T231734Z

| lane | deferred target | source footer file | current owner file/function | provisional verdict | required evidence pointer | notes |
| --- | --- | --- | --- | --- | --- | --- |
| may16_pm_2 | Stage 4 mirror sync plus CI recovery deploy verification | footer_may16_pm_2_debbie_stub_strip_blank_line.txt | scripts/deploy_status.sh::probe_version plus infra/api/src/router/route_assembly.rs::build_router_without_layers (/version route) | LIVE-VERIFY-REQUIRED | Stage 2 artifacts: may16_pm_2_stage4.stdout, may16_pm_2_stage4.stderr, may16_pm_2_stage4.exit, and mirror CI run evidence | Footer leaves Stage 4 at 0/1; row remains deploy-classification until live mirror proof exists. |
| may16_pm_3 | Stage 3 mirror CI Playwright recovery | footer_may16_pm_3_playwright_customer_login_fixture.txt | web/src/tests/playwright-config-contract.test.ts::dashboard_upgrade_to_shared.spec.ts contract plus mirror CI Playwright job | LIVE-VERIFY-REQUIRED | Stage 2 artifacts: may16_pm_3_stage3.stdout, may16_pm_3_stage3.stderr, may16_pm_3_stage3.exit, and mirror Playwright job evidence | Current contract pins this spec to chromium:mocked only, so mocked coverage cannot terminate live staging proof. |
| may16_pm_5 | Stage 6 Stripe sandbox upgrade trust-ratchet deploy proof | footer_may16_pm_5_self_service_upgrade_endpoint_and_trust_ratchet.txt | infra/api/src/routes/billing.rs::upgrade_to_shared/create_and_finalize_invoice/pay_invoice plus scripts/launch/capture_upgrade_trust_ratchet_evidence.sh | LIVE-VERIFY-REQUIRED | Later-stage artifact destination: docs/runbooks/evidence/browser-evidence/<UTC>_upgrade_trust_ratchet via scripts/launch/capture_upgrade_trust_ratchet_evidence.sh | Code owners are present in this tree, but footer still shows Stage 6 at 0/3. |
| may16_pm_6 | Stage 5 quota-warning staging delivery proof | footer_may16_pm_6_quota_warning_emails_records_storage.txt | infra/migrations/050_quota_warnings_sent_jsonb.sql plus infra/api/src/repos/pg_customer_repo_quota_warning.rs | LIVE-VERIFY-REQUIRED | Stage 2 live route, DB, and inbox evidence files for may16_pm_6 | Persistence seam is landed, but footer leaves Stage 5 at 2/3 so deploy proof remains open. |
| may16_9pm_2 | Stage 4 final local CI gate plus staging lockout probe | footer_may16_9pm_2_auth_hardening_lockout_and_rate_limits.txt | infra/migrations/052_auth_lockout_state.sql plus infra/api/src/routes/auth.rs::login | LIVE-VERIFY-REQUIRED | Stage 2 artifacts: local-ci output, staging 429/Retry-After probe, and staging RDS lockout-column probe | Repo seams are landed, but footer remains 2/3 for Stage 4 and still requires live-system proof. |
| may16_9pm_4 run-a | Stage 4 run-a full prod VM lifecycle execution plus teardown evidence | footer_may16_9pm_4_full_prod_vm_lifecycle_proof.txt | scripts/validate_full_vm_lifecycle_prod.sh::run-a mode plus pre/post cleanup evidence capture | LIVE-VERIFY-REQUIRED | Later-stage artifact destination: docs/runbooks/evidence/full-vm-lifecycle-prod/<UTC>_run-a/ | Run-a must remain a distinct row even though source footer is shared with run-b. |
| may16_9pm_4 run-b | Stage 5 run-b paid lifecycle path plus paid terminus evidence | footer_may16_9pm_4_full_prod_vm_lifecycle_proof.txt | scripts/validate_full_vm_lifecycle_prod.sh::run-b mode plus paid-path evidence capture | LIVE-VERIFY-REQUIRED | Later-stage artifact destination: docs/runbooks/evidence/full-vm-lifecycle-prod/<UTC>_run-b/ | Run-b must prove paid-path evidence and is mandatory as a separate row. |

## Sources

- Footer captures in this bundle are verbatim slices of each lane matt-progress block.
- Current-tree owner seam proof captures:
  - code_verified_may16_pm_2.txt
  - code_verified_may16_pm_3.txt
  - code_verified_may16_pm_5.txt
  - code_verified_may16_pm_6.txt
  - code_verified_may16_9pm_2.txt
  - code_verified_may16_9pm_4.txt
