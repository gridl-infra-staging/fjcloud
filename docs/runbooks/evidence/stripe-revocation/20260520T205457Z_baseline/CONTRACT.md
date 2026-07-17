# Stripe Credential Revocation Contract (Stage 1)

Bundle path: docs/runbooks/evidence/stripe-revocation/20260520T205457Z_baseline
Created (UTC): 20260520T205457Z
Scope: Stage 1 contract only (no SSM mutation, no dashboard revocation, no post-revocation closeout).

## 1) Runtime secret-source ownership (deployed truth vs operator-local vars)

Runtime Stripe values are deployed from SSM parameter names under `/fjcloud/<env>/stripe_*` and mapped by `SSM_TO_ENV`.

- Runtime mapping owner: `ops/scripts/lib/generate_ssm_env.sh:43-64` (`SSM_TO_ENV` includes `stripe_secret_key`, `stripe_publishable_key`, `stripe_webhook_secret`).
- Runtime retrieval path owner: `ops/scripts/lib/generate_ssm_env.sh:120-124` (`aws ssm get-parameters-by-path --path /fjcloud/<env>/`).
- Boundary owner: `docs/design/secret_sources.md:36-45,65-89` (runtime SSM mapping is authoritative; local suffixed vars are operator-only and must not be treated as deployed truth).
- Locator-only (not ownership): `chats/icg/may19_pm_3_stripe_key_rotation_and_audit_operator_followup.md:5-15` identifies which old credentials are being closed.

Contract consequence: deployment-state claims must terminate at SSM/runtime evidence, not local `.secret/.env.secret` suffixed entries.

## 2) Live-key auth validation owner and boundary

Live Stripe auth proof must reuse existing owners; do not add ad hoc curl/auth helpers.

- Auth check owner functions: `scripts/lib/stripe_checks.sh:41-176` (`resolve_stripe_secret_key`, prefix policy, `check_stripe_key_live`).
- Invocation owner: `scripts/validate-stripe.sh:20-26,30-74` (only explicit live invocation path is `--live-cutover`, guarded by `STRIPE_LIVE_CUTOVER=1`).
- Runbook owner: `docs/runbooks/secret_rotation.md:60-120` (default validation is test-only; explicit live-cutover invocation is `STRIPE_LIVE_CUTOVER=1 bash scripts/validate-stripe.sh --live-cutover`).

Contract consequence: Stage 2/3 live-key API proof must use `STRIPE_LIVE_CUTOVER=1 bash scripts/validate-stripe.sh --live-cutover` and must not introduce a new helper script.

## 3) Verification matrix for superseded credentials

| Superseded credential | Canonical identifier | Verification terminus | Required evidence | Notes |
|---|---|---|---|---|
| Old staging secret key | `sk_live_...rWUzL` | Stripe API auth discriminator (`200 -> 401`) **only if full old value is recoverable** | Pre-revoke `200` baseline + post-revoke `401` probe artifact | Suffix-only notes are insufficient to construct API probe value. |
| Old prod publishable key | `pk_live_...A1PYb` | Dashboard revoked/rolled state (operator-confirmed) | Dashboard evidence suffix-matched to `...A1PYb` | Publishable key is not the secret-key auth probe surface. |
| Old prod webhook secret | `whsec_...sting` | Dashboard revoked-state plus live webhook continuity | Dashboard evidence + continuity proof | Continuity must show webhook path still verifies signatures on the new secret. |

Webhook strict-reject owner evidence:

- `infra/api/src/routes/webhooks.rs:87-105` requires configured secret, requires `stripe-signature` header, and maps `construct_webhook_event(...)` failures to `invalid webhook signature`.
- No bypass branch is present in that path; therefore old-secret closure for `whsec_...sting` is proven by dashboard revoked-state plus continued successful verification on the new secret.

## 4) `sk_live_*` vs `rk_live_*` conflict resolution

Observed sources:

- Follow-up locator names target as `sk_live_...rWUzL` (`chats/icg/may19_pm_3_stripe_key_rotation_and_audit_operator_followup.md:5-15`).
- Validation owners accept both live secret and restricted prefixes when explicitly live-cutover (`scripts/lib/stripe_checks.sh:73-83`; `scripts/validate-stripe.sh:42-60`).

Contract decision:

- Canonical revocation target is the suffix `...rWUzL` on the Stripe dashboard surface.
- Prefix family must be resolved from the real dashboard row associated with that suffix; do not infer revocation target by guessed prefix family alone.

## 5) Mechanical staging 24h gate for Stage 3 revocation

Stage 3 may revoke `...rWUzL` only when Stage 2 cites both of the following:

1. First timestamped artifact proving staging was already on `sk_test_*`.
2. Fresh Stage 2 staging auth + webhook proof showing at least 24h elapsed since item (1), with no contradictory failure evidence.

Candidate existing artifact for item (1):

- `chats/icg/evidence/may19_pm_3/05_summary.md:23-25` (records `/fjcloud/staging/stripe_secret_key -> ... sk_test_*`).

Candidate existing artifact for webhook continuity context:

- `chats/icg/evidence/may19_pm_3/06_webhook_verification_summary.md:7-15,22-24` (staging webhook 200-backed proof at `2026-05-19 22:01:00 UTC`).

If Stage 2 cannot tie the first `sk_test_*` proof to a concrete timestamped artifact, Stage 3 is pre-authorized to defer **only** the staging `...rWUzL` revocation while still proceeding with other revocations.

## 6) Full old staging key recovery policy (without printing secret)

Allowed sources for the full old `sk_live_...rWUzL` value (in order):

1. Operator-local `.secret/.env.secret` `_OLD` or `_ROTATED` twin per `.scrai/rules.md:11-18`.
2. Pre-existing operator metadata noted in `docs/runbooks/secret_rotation.md:54-58`.

If neither source yields the full old key value:

- Mark post-revoke `401` probe unavailable for that credential.
- Fall back to dashboard revoked-state as verification terminus for that credential.
- Record that fallback explicitly (no synthetic or empty-key API probe).

## 7) Open questions

- Can Stage 2 produce a concrete artifact timestamp earlier than `2026-05-19` for first staging `sk_test_*` cutover, or is `chats/icg/evidence/may19_pm_3/05_summary.md` the earliest admissible baseline?
- Is a dedicated Stage 2 artifact needed to prove a continuous (not sampled) 24h healthy staging interval, or is timestamped pairwise proof (cutover timestamp + fresh check timestamp with no intervening failure evidence) sufficient under this lane?
