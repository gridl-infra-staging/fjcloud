# Cold Customer Algolia-Refugee Journey Audit: Stage 1 Preflight

## Purpose

Stage 1 establishes the verified preflight baseline for the cold-customer Algolia-refugee journey audit before any new probes or UX fixes are built. This artifact records direct staging probes from the dev checkout plus the owner map later stages should reuse.

## Run Metadata

- Timestamp (UTC): 2026-06-04T05:03:05Z
- Repo path: `fjcloud_dev`
- Evidence directory: `docs/runbooks/evidence/cold-customer-audit/20260604T050305Z`

## Out Of Scope

- Source-code fixes.
- New probes.
- Browser specs.
- Deploys.
- Edits to `PRIORITIES.md` or `ROADMAP.md`.

## Live Staging Probes

### Git Baseline

Command:

```bash
git fetch origin main --quiet
```

Result:

- Exit code: 0.
- Status path: `/tmp/jun04_l3_git_fetch_status.log`.
- No `Could not resolve host: github.com` or `.git/index.lock` permission-denial blocker occurred.

### Staging Version Endpoint

Command:

```bash
curl -fsS https://api.staging.flapjack.foo/version | tee /tmp/jun04_l3_version.json
```

Result:

- Exit code: 0, captured in `/tmp/jun04_l3_version_status.log`.
- Raw JSON copied from `/tmp/jun04_l3_version.json`:

```json
{"build_time":"2026-06-04T04:19:35Z","dev_sha":"a1f6935d6ebf82fc8ef261b68a2a242bf0116122","mirror_sha":"2e964a3e6bb8f3d62582b7d998390684a9a3f477","synced_at":"2026-06-04T04:15:43Z"}
```

Parsed summary:

- `dev_sha`: `a1f6935d6ebf82fc8ef261b68a2a242bf0116122`.
- `build_time`: `2026-06-04T04:19:35Z`.
- `mirror_sha`: `2e964a3e6bb8f3d62582b7d998390684a9a3f477`.
- `synced_at`: `2026-06-04T04:15:43Z`.
- Environment field: no explicit environment field was present in this `/version` response.

### Customer Quickstart Validator

Validation-cache check before run:

- Helper: `/Users/stuart/repos/gridl/mike_dev/matt_root/matt/validation_cache.py`.
- `matt_dir`: `/Users/stuart/.matt/projects/fjcloud_dev-8e48bd8b/jun04_am_3_cold_customer_algolia_refugee_journey_audit.md-1155f27c`.
- `head_sha`: `ba83754035ed9c7ca98556507fcf86c8c6ccd354`.
- `clean_tree`: `False`, because this evidence artifact was already present.
- Cache result: no hit.

Command:

```bash
set +e; bash scripts/validate_customer_quickstart.sh staging 2>&1 | tee /tmp/jun04_l3_validator_stdout.log; validator_rc=${PIPESTATUS[0]}; set -e; printf 'validator exit code: %s\n' "$validator_rc" | tee /tmp/jun04_l3_validator_status.log
```

Result:

- Exit code: 2, captured in `/tmp/jun04_l3_validator_status.log`.
- Full stdout/stderr path: `/tmp/jun04_l3_validator_stdout.log`.
- Validation-cache record: dirty-tree FAIL recorded for `bash scripts/validate_customer_quickstart.sh staging`.

Observed validator output:

```text
[validate_customer_quickstart] quickstart markers: auth_register auth_verify_email indexes_create indexes_batch_add_object indexes_search
[validate_customer_quickstart] migration markers: migration_indexes_list migration_indexes_create migration_indexes_batch_add_object migration_indexes_search migration_indexes_get_object migration_indexes_batch_update_object migration_indexes_delete_object migration_indexes_save_synonym migration_indexes_save_rule
ERROR: full-flow mode requires these env vars: SES_FROM_ADDRESS SES_REGION INBOUND_ROUNDTRIP_S3_URI INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN
ERROR: use 'prod --contract-only' for non-destructive contract probes when full-flow prerequisites are unavailable
```

Owner-flow interpretation:

- `scripts/validate_customer_quickstart.sh:22` defines the ordered `MARKER_CASES` inventory: quickstart register, verify email, create index, batch `addObject`, search, then migration list/create/batch/search/get/update/delete/synonym/rule cases.
- `scripts/validate_customer_quickstart.sh:699` owns the executable sequence and dispatches canary-backed register, verify-email, index create, batch write, search, then migration cases and cleanup.
- `scripts/validate_customer_quickstart.sh:728` sources `scripts/canary/customer_loop_synthetic.sh`, loads canary env, bridges `INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN` and `INBOUND_ROUNDTRIP_S3_URI` into the canary inbox variables, runs the sequence, and emits `FLOW_FAILURE_STEP` / `FLOW_FAILURE_DETAIL` only if the canary flow itself is reached.
- This run did not reach the canary flow. There is no `FLOW_FAILURE_STEP` or `FLOW_FAILURE_DETAIL` in `/tmp/jun04_l3_validator_stdout.log`; the failure is the full-flow prerequisite gate at `scripts/validate_customer_quickstart.sh:319`.

Direct failing-surface reprobe:

```bash
source scripts/lib/env.sh
load_env_file .secret/.env.secret
for var in SES_FROM_ADDRESS SES_REGION INBOUND_ROUNDTRIP_S3_URI INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN; do
  if [ -n "${!var:-}" ]; then printf "%s=present\n" "$var"; else printf "%s=missing\n" "$var"; fi
done
```

Output path: `/tmp/jun04_l3_inbox_prereq_presence.log`.

```text
SES_FROM_ADDRESS=missing
SES_REGION=missing
INBOUND_ROUNDTRIP_S3_URI=missing
INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN=missing
```

Inbox helper classification reprobe:

```bash
source scripts/lib/test_inbox_helpers.sh
test_inbox_require_aws_inbox_prereqs "${INBOUND_ROUNDTRIP_S3_URI:-}" "${INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN:-}"
```

Output path: `/tmp/jun04_l3_inbox_helper_probe.log`.

```text
probe_env_gap_aws_inbox_env_missing: missing CANARY_TEST_INBOX_S3_URI or CANARY_TEST_INBOX_DOMAIN
inbox helper prereq exit code: 100
```

Supporting source citations:

- `scripts/validate_customer_quickstart.sh:319` lists the required full-flow email/inbox keys; `scripts/validate_customer_quickstart.sh:335` prints the observed missing-env error.
- `scripts/lib/test_inbox_helpers.sh:77` classifies caller-side AWS inbox prerequisites before S3 work; `scripts/lib/test_inbox_helpers.sh:87` emits the missing inbox env token and returns prereq skip code.
- `scripts/lib/test_inbox_helpers.sh:285` owns RFC822 fetch behavior once a bucket/key/region are available; this run did not reach fetch because the S3 URI and inbox domain were absent.

### Staging-Only Constraints

- API target probed in this stage: `https://api.staging.flapjack.foo`.
- Later browser target named by the stage: `https://cloud.staging.flapjack.foo`.
- Full staging validator mode requires `API_URL`, `SES_FROM_ADDRESS`, `SES_REGION`, `INBOUND_ROUNDTRIP_S3_URI`, `INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN`, and either `ADMIN_KEY` or `FLAPJACK_ADMIN_KEY` per `scripts/validate_customer_quickstart.sh:314` and `scripts/validate_customer_quickstart.sh:330`.
- In this checkout, after loading `.secret/.env.secret`, the four email/inbox variables listed above were missing. Values were not printed; only redacted present/missing state was captured.
- The currently observed validator blocker is a repo-local/staging-config prerequisite gap, not an external-unreachable blocker. Later stages can still proceed with owner-map and browser-contract work, but any full live signup-verify-search probe needs those staging inbox variables supplied or a repo-owned seam change that removes the mismatch.

## Owner Map

### Customer-Facing First Search

- `docs/getting-started/customer-quickstart.md:1` names "Customer Quickstart (Account Creation to First Search)".
- `docs/getting-started/customer-quickstart.md:3` states this quickstart is the customer-facing source of truth for the first successful search flow.
- The executable path is register (`docs/getting-started/customer-quickstart.md:22`), verify email (`docs/getting-started/customer-quickstart.md:41`), create index (`docs/getting-started/customer-quickstart.md:54`), batch `addObject` (`docs/getting-started/customer-quickstart.md:68`), and search (`docs/getting-started/customer-quickstart.md:89`).
- `docs/getting-started/customer-quickstart.md:105` starts the source-evidence index; it cites route owners and the canary-backed customer flow.

### Algolia-Refugee Route Mapping

- `docs/getting-started/migrating_from_algolia.md:24` starts the operation mapping table for Algolia operations to fjcloud routes.
- `docs/getting-started/migrating_from_algolia.md:28` through `docs/getting-started/migrating_from_algolia.md:35` map create, push records, search, get, update, delete, synonym, and rule operations to JWT control-plane routes.
- `docs/getting-started/migrating_from_algolia.md:39` through `docs/getting-started/migrating_from_algolia.md:45` explicitly separate fjcloud workflow differences from Algolia headers and implicit-index behavior.
- `docs/getting-started/migrating_from_algolia.md:131` starts optional migration-assist routes. Those routes are separate from the default JWT control-plane path and require Algolia credentials in request bodies.

### Reusable Canary Owner

- `scripts/canary/customer_loop_synthetic.sh:1` identifies the reusable staging customer-loop canary owner.
- `scripts/canary/customer_loop_synthetic.sh:440` owns signup; it posts `/auth/register` and requires token plus customer ID.
- `scripts/canary/customer_loop_synthetic.sh:469` owns email verification; it parses the configured S3 inbox and fetches the verification email before calling `/auth/verify-email`.
- `scripts/canary/customer_loop_synthetic.sh:849` owns index creation.
- `scripts/canary/customer_loop_synthetic.sh:872` owns batch `addObject`.
- `scripts/canary/customer_loop_synthetic.sh:887` owns search and asserts non-empty hits.
- `scripts/canary/customer_loop_synthetic.sh:927`, `scripts/canary/customer_loop_synthetic.sh:943`, and `scripts/canary/customer_loop_synthetic.sh:963` own index, account, and admin cleanup.
- Later Stage 2 should reuse this seam instead of creating a parallel signup/verify/index/search harness.

### Browser Release-Surface Owner

- `web/tests/e2e-ui/smoke/customer_release_surfaces.spec.ts:47` owns index selection or creation for the browser release-surface smoke.
- `web/tests/e2e-ui/smoke/customer_release_surfaces.spec.ts:102` owns canonical tab-strip assertions against `INDEX_DETAIL_TABS`.
- `web/tests/e2e-ui/smoke/customer_release_surfaces.spec.ts:140` owns Metrics tab assertions, requiring the refresh button plus KPI grid, empty state, or tab-local unavailable alert.

### Index Detail Tab Source Of Truth

- `web/src/routes/console/indexes/[name]/index_detail_tabs.ts:1` defines `INDEX_DETAIL_TAB_PANEL_TEST_IDS`.
- `web/src/routes/console/indexes/[name]/index_detail_tabs.ts:21` defines `INDEX_DETAIL_TABS`, the single source of truth for tab ids, labels, and panel test IDs.
- Stage 3 should extend this owner only if missing selectors are proven by evidence; it should not add parallel tab constants in tests.

### Playwright Remote-Target Guardrail

- `web/playwright.config.contract.ts:224` starts `PLAYWRIGHT_PROJECT_CONTRACTS`, including setup projects for user, admin, onboarding, and customer journeys.
- `web/playwright.config.contract.ts:626` defines `REMOTE_TARGET_OPT_IN_ENV = 'PLAYWRIGHT_TARGET_REMOTE'`.
- `web/playwright.config.contract.ts:627` through `web/playwright.config.contract.ts:632` allow only hosts ending in `.flapjack.foo` for credentialed remote-target runs.
- Remote staging browser runs therefore require `PLAYWRIGHT_TARGET_REMOTE=1` and HTTPS hosts such as `https://cloud.staging.flapjack.foo`.

## Open Questions

- Which secret/config owner should supply `SES_FROM_ADDRESS`, `SES_REGION`, `INBOUND_ROUNDTRIP_S3_URI`, and `INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN` for staging full-flow validation?
- Is the absence of those four variables intentional for this dev checkout, or should `.secret/.env.secret` include a staging roundtrip inbox bundle?
- Should later stages accept a browser-only cold-customer audit while the live validator remains prereq-gated, or first land a repo-owned config/seam fix for staging full-flow prerequisites?

## Evidence Quality Review

- This artifact includes concise summaries with raw-output paths: `/tmp/jun04_l3_version.json`, `/tmp/jun04_l3_version_status.log`, `/tmp/jun04_l3_validator_stdout.log`, `/tmp/jun04_l3_validator_status.log`, `/tmp/jun04_l3_inbox_prereq_presence.log`, and `/tmp/jun04_l3_inbox_helper_probe.log`.
- No secret values or full credentials are included. The only secret-adjacent evidence is redacted present/missing state for required env vars.
- Owner claims are cited to current source files and line numbers read from this checkout.
- Done-state semantics are not asserted here; checklist marker promotion remains orchestrator-owned.

## Corrective Git Proof Amendment

This amendment replaces the prior git-proof block because it named `066907b97af51dba8035d88d5e96eef06166da69`, a commit that is not the current pushed branch tip and is not contained by any local branch. The corrective proof avoids embedding a claim that this file contains the SHA of the commit that contains it: a Git commit ID hashes the file contents, so adding that ID to this file would change the ID. The final branch tip must be verified by running the recorded commands after commit and push.

Pre-correction clean state:

```bash
git status --short
git rev-parse HEAD
git show --stat --oneline --name-only HEAD
```

Output:

```text
cac37fada665541bc9dd05269a574ca5ee0f0827
cac37fada docs: record cold customer preflight git proof
docs/runbooks/evidence/cold-customer-audit/20260604T050305Z/preflight.md
```

Interpretation:

- `git status --short` produced no output before this correction, so there was no unrelated work in the checkout.
- The stale proof was in the current evidence artifact commit, and that commit touched only `docs/runbooks/evidence/cold-customer-audit/20260604T050305Z/preflight.md`.

Scope check before commit:

```bash
git diff --cached --stat
```

Output after staging only this artifact:

```text
 .../20260604T050305Z/preflight.md                  | 69 +++++++---------------
 1 file changed, 21 insertions(+), 48 deletions(-)
```

Required post-commit / post-push verification commands:

```bash
git status --short
git rev-parse HEAD
git show --stat --oneline --name-only HEAD
git status --short
```

Expected interpretation:

- The first and last `git status --short` outputs must be empty after commit and push, proving no unrelated work remains.
- `git show --stat --oneline --name-only HEAD` must name only `docs/runbooks/evidence/cold-customer-audit/20260604T050305Z/preflight.md` for the corrective evidence commit.
- The actual final branch-tip SHA is the live `git rev-parse HEAD` output after the corrective commit exists; it is intentionally not embedded in this file to avoid another stale self-reference.

## Review-Blocker Git Proof Reprobe

Clean review of the prior amendment found that this artifact still recorded the intended post-commit checks rather than concrete command output. This reprobe records the actual pushed branch state observed immediately before the second corrective evidence-only commit.

Current pushed branch proof before this amendment:

```bash
git status --short
git status --branch --short
git rev-parse HEAD
git rev-parse @{u}
git show --stat --oneline --name-only HEAD
```

Output:

```text
git status --short:
(no output)

git status --branch --short:
## batman/jun04_am_3_cold_customer_algolia_refugee_journey_audit...origin/batman/jun04_am_3_cold_customer_algolia_refugee_journey_audit

git rev-parse HEAD:
021deb459a69b0d0fbdd3ea51ced50a4fa72263b

git rev-parse @{u}:
021deb459a69b0d0fbdd3ea51ced50a4fa72263b

git show --stat --oneline --name-only HEAD:
021deb459 docs: correct cold customer preflight git proof
docs/runbooks/evidence/cold-customer-audit/20260604T050305Z/preflight.md
```

Interpretation:

- The checkout was clean before this amendment.
- Local `HEAD` matched the upstream tracking branch before this amendment.
- The pushed branch-tip commit under review touched only this preflight artifact.

Scope check for this amendment after staging only this artifact:

```bash
git diff --cached --stat
```

Output:

```text
 .../20260604T050305Z/preflight.md                  | 55 ++++++++++++++++++++++
 1 file changed, 55 insertions(+)
```

Post-commit verification for this amendment is recorded in the session handoff because a Git commit cannot contain its own final hash or post-creation command output without changing that hash.
