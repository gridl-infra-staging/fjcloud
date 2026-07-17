# Staging Domain Remap Stage 5 Evidence - 20260709T224136Z

## Purpose

Final verification evidence for the staging-domain-remap and served-content parity lane. This bundle records deterministic shell-contract tests, local CI, live staging served-content probes, and positive/negative parity-gate behavior. Served content is authoritative; Cloudflare metadata is explanatory only.

## Prior Evidence Pointers

- Stage 1 live-state bundle: `docs/live-state/20260709T212731Z/`.
- Stage 1 before-state bundle: `docs/runbooks/evidence/staging-domain-remap/20260709T213058Z/`.
- Stage 2 anti-stop-gap bundle: `docs/runbooks/evidence/staging-domain-remap/20260709T214537Z/`.

## Shell-Contract And Local CI Results

- `bash scripts/tests/e2e_deployed_pages_parity_probe_test.sh`: `12 passed, 0 failed`, exit 0. Raw log: `tests/e2e_deployed_pages_parity_probe_test.log`.
- `bash scripts/tests/ci_e2e_deployed_pages_parity_test.sh`: `10 passed, 0 failed`, exit 0. Raw log: `tests/ci_e2e_deployed_pages_parity_test.log`.
- `bash scripts/tests/ci_deploy_web_contract_test.sh`: `26 passed, 0 failed`, exit 0, including `deploy-staging timeout-minutes=45` within `[20,60]`. Raw log: `tests/ci_deploy_web_contract_test.log`.
- `bash scripts/local-ci.sh --fast`: `Totals: pass=18 fail=0 skip=0`, `Result: PASS`, exit 0. Raw log: `tests/local_ci_fast.log`.

## Served-Content Before Vs Current

Stage 1 recorded production pricing with the `Get Started Free` signup CTA and staging pricing without that CTA. Current Stage 5 probing shows no remediation of the staging surface:

- `curl -sS -L --max-time 30 https://cloud.staging.flapjack.foo/pricing | grep -qE 'Get Started Free|href="/signup"|/signup'` was polled 18 times at 10-second intervals.
- Every attempt fetched HTTP content successfully (`curl_exit=0`) and failed the CTA grep (`grep_exit=1`, `command_exit=1`, body size 11245 bytes). Raw log: `live/staging_pricing_cta_poll.log`; raw bodies: `live/staging_pricing_attempt_*.html`.
- This matches the Stage 2 anti-stop gap: staging still serves the stale pricing page and the final staging served-content gate remains red.

## Version Marker Evidence

The checklist wording asked for `sha` values, but both live endpoints expose SvelteKit's `version` property rather than a `sha` property:

- Staging: `https://cloud.staging.flapjack.foo/_app/version.json` returned `{"version":"1783556911547"}`. Raw file: `live/staging_version.json`.
- Production: `https://cloud.flapjack.foo/_app/version.json` returned `{"version":"1783627077589"}`. Raw file: `live/prod_version.json`.
- The values differ, consistent with stale staging served content. The Stage 1 open question remains: these markers are numeric fallback-looking values, not 40-character commit SHAs.

## Parity Gate Proofs

The checklist's direct `scripts/launch/wait_for_pages_parity.sh` invocation failed locally with `permission denied` because the script is not executable. The owner works through `bash`, matching the shell-contract tests and workflow usage; raw failed direct-exec log: `live/staging_parity_against_prod_version.log`.

- Staging positive-path probe, corrected to target production's served `version` value: `TARGET_SHA=1783627077589 PAGES_ALIAS_URL=https://cloud.staging.flapjack.foo MAX_POLL_ATTEMPTS=3 POLL_INTERVAL_SECONDS=10 bash scripts/launch/wait_for_pages_parity.sh` exited 1 and wrote `ready=false`. It observed staging served `1783556911547` on all 3 attempts. Raw log: `live/staging_parity_against_prod_version_bash.log`; output file: `live/staging_parity_bash_github_output.txt`.
- Wrong-target negative proof: `TARGET_SHA=0000000000000000000000000000000000000000 PAGES_ALIAS_URL=https://cloud.flapjack.foo MAX_POLL_ATTEMPTS=2 POLL_INTERVAL_SECONDS=5 bash scripts/launch/wait_for_pages_parity.sh` exited 1 and wrote `ready=false`. It observed production served `1783627077589` and correctly rejected the impossible target. Raw log: `live/prod_wrong_target_negative_bash.log`; output file: `live/prod_wrong_target_negative_github_output.txt`.

## Disposition

Stage 5 verification is honest-red for staging: the parity gate is fixed to reject stale/mismatched served content, but `cloud.staging.flapjack.foo` still serves stale pricing content without the production signup CTA. Fixed in this lane: Stage 3 served-content parity rewrite and Stage 4 `deploy-staging` timeout bound. Still open: Cloudflare Pages custom-domain attachment or deploy credential path needed to make the staging custom domain serve current content.
