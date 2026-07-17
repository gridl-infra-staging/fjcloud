# Launch verification — 2026-05-21 consolidation index

Date: 2026-05-21
Scope: rerun of the launch-verification proof set after the 2026-05-20 prod fleet outage and recovery. Indexes every evidence subdirectory produced by Stages 1–6 of `may20_3pm_4_launch_verification` and records each stage's honest verdict. Does NOT itself re-run any probes — verdicts below are read directly from each stage's canonical source file.

Overall: **PARTIAL** — 4 PASS (Stages 3–6), 1 FAIL (Stage 1 preflight), 1 DEFERRED (Stage 2 staging browser, upstream staging API 503).
> **Superseded by:** [`.github/workflows/ci.yml`](../../../../../.github/workflows/ci.yml) and [`scripts/launch/produce_launch_verification_bundle.sh`](../../../../../scripts/launch/produce_launch_verification_bundle.sh) now own staging launch-verification gating and bundle production.

## Per-stage index

### Stage 1 — Preflight live gates — **FAIL**

- Evidence: `preflight/`
- Canonical source: `preflight/SUMMARY.txt` (timestamp 2026-05-21T07:16:47Z)
- Key artifacts: `mirror_ci_status.json`, `deploy_status.json`, `canary_alarm_status.json`, `run_a_output.log`
- Proof: CI staging/prod deploy jobs PASS and the `fjcloud-prod-customer-loop-canary-not-running` alarm is `OK`, but three required gates FAIL.
- Owning-lane gaps cited verbatim from `preflight/SUMMARY.txt`:
  - `may20_3pm_1_fleet_recovery`: run-a `create_index` step failed with HTTP 503 after retries; provisioning/index path is not healthy.
  - `may20_3pm_2_pipeline_propagation`: staging `/version` returned `unknown` mirror/dev SHA, so deploy propagation to staging API is unverified/broken.
  - `may20_3pm_2_pipeline_propagation`: prod deploy is 86 commits behind dev main despite CI deploy-job success; main convergence not achieved.

### Stage 2 — Rerun staging browser proofs — **DEFERRED**

- Evidence: `none` — no `staging-browser/` subdirectory exists under `2026-05-21/`.
- Canonical source: `checklists/stage_02_checklist.md` (deferred markers `[d]`) plus handoff `session_handoffs/stage_02/s22_unstuck_deferred-stage2-on-staging-503.md`.
- Root cause: `https://api.staging.flapjack.foo/version` and `/health` both returned HTTP 503 throughout the verification window (`awselb/2.0`, no healthy targets); latest staging mirror CI run `26213041991` (2026-05-21T07:52:30Z) concluded `failure`. The canonical runner `scripts/launch/run_browser_lane_against_staging.sh` requires a reachable staging API and a green Stage 1 baseline, neither of which held during this window.
- Routing: blockers owned by `may20_3pm_1_fleet_recovery` (staging fleet) and `may20_3pm_2_pipeline_propagation` (staging mirror CI). Stage 2 was not re-attempted in this wave.

### Stage 3 — Full VM lifecycle Run B (Mode B paid terminus) — **PASS**

- Evidence: `prod-lifecycle-run-b/`
- Canonical source: `prod-lifecycle-run-b/SUMMARY.txt`
- Key artifacts: `run_b_exit_code.txt` (0), `run_b_output.log`, `stripe_paid_state.json` (livemode=true, status=`paid`), `tenant_active_pre_cleanup.json`, `post_cleanup_state.json` (status=`deleted`), `aws_verify_email_head_object.json`, `metadata.json`
- Proof: Live prod Stripe invoice `in_1TZTl2GXI8zVz4UH0CoGLtrP` reached `paid` terminus (HTTP 200, `livemode=true`); fjcloud tenant `faebc870-…` was `active` pre-cleanup and `deleted` post-cleanup; index `lifecycle-canary2026052110230126399` was created+deleted; orchestrator `scripts/validate_full_vm_lifecycle_prod.sh` exited 0 with `STRIPE_PAY_OUT_OF_BAND=1`.

### Stage 4 — SES deliverability roundtrip — **PASS (scope-limited, see scope notes)**

- Evidence: `ses-roundtrip/`
- Canonical source: `ses-roundtrip/SUMMARY.txt` (run 2026-05-21T11:09:37Z)
- Key artifacts: `roundtrip_exit_code.txt` (0), `roundtrip_output.json`, `precheck_status.txt`
- Proof: SES probe sent from `system@flapjack.foo` to `roundtrip-inbound-probe-20260521T110937Z-4841@test.flapjack.foo` was delivered to the S3 sink (`s3://flapjack-cloud-releases/e2e-emails/…`); RFC822 `Authentication-Results` header parsed to `dkim=pass, spf=pass, dmarc=pass`.
- **Scope boundary (carried from `ses-roundtrip/SUMMARY.txt`):** this proves the `test.flapjack.foo` inbound path (SES receipt rule `mailpail-to-s3` → S3 sink) and Authentication-Results header correctness only. It does **NOT** prove automated placement into the real `support@flapjack.foo` Google Workspace inbox; that seam does not exist in the repo-owned automation today and must not be overclaimed.

### Stage 5 — Subprocessor disclosure proof — **PASS**

- Evidence: `subprocessor-disclosure/`
- Canonical source: `subprocessor-disclosure/summary_status.txt` (run 2026-05-21T11:27:26Z, expected_date=2026-05-19)
- Key artifacts: `exit_code.txt`, `run_output.txt`, `summary_status.json`, four per-host HTML captures (`cloud_flapjack_foo__{dpa,privacy}.html`, `cloud_staging_flapjack_foo__{dpa,privacy}.html`)
- Proof: All four URLs (`https://cloud.{staging.,}flapjack.foo/{dpa,privacy}`) return `PASSED|all checks passed`; rendered DPA/privacy pages match expected effective date `2026-05-19` and contain the required subprocessor disclosure on both prod and staging public web hosts.

### Stage 6 — Prod OAuth launch proof — **PASS**

- Evidence: `prod-oauth/`
- Canonical source: `prod-oauth/SUMMARY.md`
- Key artifacts: `contract_exit_code.txt` (0), `contract_run.txt`, `google_start_status_code.txt` (302), `github_start_status_code.txt` (302)
- Proof: `scripts/canary/contracts/oauth_redirect_uri_contract.sh prod` exited 0 with PASS lines for both providers (`token endpoint error=invalid_grant` for Google and `bad_verification_code` for GitHub — both are the expected discriminators for a registered `redirect_uri` against a bogus code). Live spot checks of `https://api.flapjack.foo/auth/oauth/{google,github}/start` both returned `302`, confirming SSM-sourced client credentials are loaded in the prod API process and `redirect_uri` resolves against `APP_BASE_URL` to provider-accepted values.

## Scope notes

1. **Staging coverage is absent for this wave.** Stage 2 was deferred because the staging API was returning HTTP 503 across the verification window. As a result, this wave proves prod-only customer flows (Stages 3 and 6) plus cross-environment publication checks (Stage 5 covers both staging and prod web). No staging browser proof exists for `signup_to_paid_invoice` or `billing_portal_payment_method_update` from this date; the most recent passing staging-browser evidence must be sourced from a prior verification window if needed.
2. **SES test-inbox vs. real-mailbox distinction.** Stage 4 PASS proves the shared `test.flapjack.foo` inbound path and Authentication-Results header correctness. It does NOT prove that a customer email sent to `support@flapjack.foo` is delivered into the Google Workspace inbox an operator actually reads — that seam is outside repo-owned automation today. Do not cite Stage 4 as proof of `support@` reachability.
3. **Stage 1 preflight FAIL means downstream proofs ran against a partially-validated baseline.** Stages 3–6 each succeeded, but Stage 1's overall verdict was FAIL (run-a 503 on fleet recovery, staging SHA unknown, prod 86 commits behind dev main). The downstream PASS verdicts are valid for what they tested (prod live customer lifecycle, prod OAuth start, both-env public-web subprocessor disclosure, shared SES inbound path); they do not, however, recover the missing preflight assurances about staging-side propagation or main-convergence on prod.

## Pointers

- Stage 1 preflight: `preflight/SUMMARY.txt`
- Stage 2 deferral evidence: `checklists/stage_02_checklist.md` (markers `[d]`) and `session_handoffs/stage_02/s22_unstuck_deferred-stage2-on-staging-503.md` in the project's matt session directory.
- Stage 3–6 stage summaries: `prod-lifecycle-run-b/SUMMARY.txt`, `ses-roundtrip/SUMMARY.txt`, `subprocessor-disclosure/summary_status.txt`, `prod-oauth/SUMMARY.md`.
