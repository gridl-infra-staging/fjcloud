# Cold Customer Algolia-Refugee Journey Audit: Stage 4 Preflight

## Purpose

Stage 4 captures live CLI + browser evidence and authors `findings.md`. This
preflight is the per-UTC baseline the rest of this evidence root is grounded in,
as required by Stage 1's contract. It records the staging API state, the lane
branch state, the local checkout state, and the staging-vs-branch deploy delta
at the moment the Stage 4 probes were run.

This file replaces the prior absent-preflight gap flagged by the Stage 4 review
(`missing-active-preflight`). The Stage 1 baseline preflight remains the
canonical owner-map artifact at
`docs/runbooks/evidence/cold-customer-audit/20260604T050305Z/preflight.md`; this
preflight does NOT restate that owner map — it only captures the live state
needed to interpret this UTC root's CLI and browser evidence.

## Run Metadata

- Evidence root: `docs/runbooks/evidence/cold-customer-audit/20260604T084633Z/`.
- Stage: Stage 4 of 7 (research-only — capture evidence + author findings;
  no source-code fixes; no probe/spec changes; no deploy; no `PRIORITIES.md` or
  `ROADMAP.md` edits).
- Repo path:
  `fjcloud_dev`.
- Lane branch:
  `batman/jun04_am_3_cold_customer_algolia_refugee_journey_audit`.

## Out Of Scope

- Source-code fixes (Stage 5 owns in-envelope fixes).
- Probe or browser-spec changes (Stages 2 and 3 own those).
- Deploys, redeploys, or merges to `main`.
- Edits to `PRIORITIES.md`, `ROADMAP.md`, or any planning surface.
- Bulk removal of `TODO: Document` stubs (debbie post-sync hooks own that).

## Live Staging Probes

### Staging Version Endpoint

Command:

```bash
curl -fsS https://api.staging.flapjack.foo/version
```

Raw response (from `version_pre.json`):

```json
{"build_time":"2026-06-04T08:05:40Z","dev_sha":"26530584c00b215cec178044fe371bd0d47678db","mirror_sha":"11644262ae404d658b9a496b41fc5924ffa274f6","synced_at":"2026-06-04T07:50:28Z"}
```

Parsed summary:

- `dev_sha`: `26530584c00b215cec178044fe371bd0d47678db`.
- `build_time`: `2026-06-04T08:05:40Z`.
- `mirror_sha`: `11644262ae404d658b9a496b41fc5924ffa274f6`.
- `synced_at`: `2026-06-04T07:50:28Z`.

A post-lane snapshot (`version_post.json`) was captured after the CLI and
browser runs and shows the same `dev_sha` / `build_time` / `mirror_sha` —
staging did not redeploy mid-lane.

### Staging Health Endpoint

Command:

```bash
curl -fsS https://api.staging.flapjack.foo/health
```

Response:

```json
{"status":"ok"}
```

Staging API answered `200 OK` from the dev checkout; no DNS / TLS / availability
blocker for the CLI or browser probes.

## Git Baseline

### Lane Branch State

```bash
git rev-parse HEAD
git rev-parse --abbrev-ref HEAD
git status --short
```

Output:

```text
00eb15f44a572cbb5dae2a2f67b956b1dfdeb0f6
batman/jun04_am_3_cold_customer_algolia_refugee_journey_audit
(no output)
```

- Lane HEAD before the Stage 4 fix-up commit:
  `00eb15f44a572cbb5dae2a2f67b956b1dfdeb0f6`.
- Working tree clean before this preflight was written.

### Branch vs `origin/main` Delta

```bash
git fetch origin main --quiet
git rev-parse origin/main
git log --oneline origin/main..HEAD | head -10
```

Output:

```text
origin/main: 26530584c00b215cec178044fe371bd0d47678db
00eb15f44 evidence(cold-customer-audit): add run_stdout.log files (force past *.log gitignore)
35f815119 evidence(cold-customer-audit): capture stage 4 findings and journey artifacts
cc85f5fa8 matt: stage 4 checklist
909c592bb matt: stage 3 completion
8607cead0 fix(web): reject dotenv E2E_ADMIN_KEY in remote-target mode
011bf3b13 fix(web): fail closed on E2E_ADMIN_KEY in remote-target mode
88bd6fc56 test(web): fail closed cold customer contract prerequisites
e940f08f9 Fix search preview proxy auth and params
b37839104 test(web): add cold customer journey contract
8c9174441 matt: stage 3 checklist
```

Interpretation:

- `origin/main` tip equals the staging `dev_sha`. The current staging build IS
  the latest published `origin/main`.
- Nine commits on the lane branch are NOT yet on `origin/main`. The relevant
  commit for Stage 4 evidence interpretation is `e940f08f9` (Fix search preview
  proxy auth and params).

### Staging Deploy Delta Probe

```bash
git merge-base --is-ancestor e940f08f9 origin/main \
  && echo "e940f08f9 IS on origin/main" \
  || echo "e940f08f9 NOT on origin/main"
git merge-base --is-ancestor e940f08f9 26530584c00b215cec178044fe371bd0d47678db \
  && echo "e940f08f9 IS in staging dev_sha" \
  || echo "e940f08f9 NOT in staging dev_sha"
```

Output:

```text
e940f08f9 NOT on origin/main
e940f08f9 NOT in staging dev_sha
```

Interpretation (load-bearing for Stage 4 findings):

- `e940f08f9` is the Stage 3 fix for the Search Preview proxy auth / params.
  It is committed on the lane branch but has not landed on `origin/main`, so
  staging cannot have it.
- This is a real `blocked` reason for any browser-spec assertion that depends
  on the Search Preview proxy. Stage 4 findings must record the affected rows
  as `blocked: staging-deploy-lag` rather than as product defects.

## Evidence Root Contract

This UTC root contains:

- `preflight.md` — this file.
- `version_pre.json` — staging `/version` immediately before probes.
- `version_post.json` — staging `/version` immediately after probes.
- `cli/cli_steps.jsonl` — per-step CLI probe results from
  `scripts/canary/contracts/cold_customer_journey_walkthrough.sh`.
- `cli/summary.json` — overall CLI probe verdict + failing step.
- `cli/run_stdout.log` — stdout/stderr captured by `tee` from the CLI run.
- `cli/expected_seed.md` — derived customer-correctness anchors (objectIDs and
  titles that the deterministic batch payload uploaded) — see Seeded Record
  Anchors section below.
- `browser/run_stdout.log` — Playwright `--reporter=list` stdout.
- `browser/error-context.md` — Playwright page snapshot at failure.
- `browser/test-failed-1.png` — Playwright failure screenshot.
- `browser/trace.zip` — Playwright trace (~4.2 MB) with full visual frames.
- `browser/README.md` — notes about the absent `video.webm` and why the
  `trace.zip` is the sufficient visual evidence.
- `findings.md` — Stage 4 findings table with disposition per surface.

## Seeded Record Anchors

The CLI probe's `summary.json` leaves `seeded_record_object_id` and
`seeded_record_title` empty whenever the search step fails to retrieve the
seeded record — these fields are only populated when the search retrieves a
matching hit (`scripts/canary/contracts/cold_customer_journey_walkthrough.sh`
lines 478-505). The empty fields are therefore the natural shape of "search
returned zero hits" and are NOT a redaction. To preserve the
customer-correctness anchors the checklist requires (the objectIDs and titles
that the deterministic batch _should_ have been retrievable by), the probe's
deterministic payload generator
(`scripts/lib/deterministic_batch_payload.sh::deterministic_batch_payload`) is
re-derived in `cli/expected_seed.md` for this evidence root.

## Open Questions

- Should the CLI probe's `summary.json` schema be extended to record the
  _expected_ seeded `objectID` / `title` (derived from the batch payload) even
  when search fails, so downstream evidence audits do not need a sibling
  `expected_seed.md`? — out of scope for Stage 4; surface as a Stage 5 or
  Stage 6 candidate after disposition triage.

## Evidence Quality Review

- Raw response paths are stored alongside this preflight (`version_pre.json`,
  `version_post.json`, `cli/run_stdout.log`, `browser/run_stdout.log`).
- No secret material is included. The CLI probe writes signup tokens and
  customer IDs to `cli_steps.jsonl`; the customer was deleted in the probe's
  cleanup step (HTTP 204) and the admin-cleanup step confirmed the tenant was
  gone (HTTP 404), so the token recorded in evidence cannot authenticate
  against any live tenant.
- Owner claims for the staging-deploy lag are grounded in `git merge-base`
  output above, not in restated artifact prose.
- Done-state semantics are not asserted here. Checklist marker promotion remains
  orchestrator-owned.
