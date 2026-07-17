---
verified: 2026-05-06
---

# OAuth Post-Merge Adversarial Review — `8ad964f9`

**Reviewed:** 2026-05-06T08:46:01Z (autonomous review pass per
`chatting/may06_handoff_followup_lanes_and_decisions.md` § "pm_1 post-merge review")

**Scope:** commits `53c33d42` … `544d6bb9` plus the merge commit `8ad964f9`;
~3.9k LOC across `infra/api/src/` + `web/src/` for Google + GitHub OAuth
identity, atomic deleted-customer guard, provider-verified email handling,
race-window hardening.

## VERDICT: DEFECTS-FOUND (2 medium, 1 low)

The takeover-via-unverified-local-row vector flagged by `53c33d42` is
correctly closed for the active surface. The Stage-5 `544d6bb9`
posthoc-security commit fixed a separate cookie-rejection-on-local-http
issue (the prior `Secure; SameSite=None` policy was a soft cookie-rejection
bug on local http, not a takeover). Two real defects + one low-severity
dead-state issue remain.

---

## DEFECT 1 (medium) — Asymmetric deleted-customer guard between verified-email and synthetic-email branches

**Files:** `infra/api/src/routes/oauth.rs:209-273` (`resolve_oauth_customer`),
`infra/api/src/routes/oauth.rs:373-388`
(`find_active_customer_by_email`),
`infra/api/src/routes/oauth.rs:339-369`
(`create_or_find_synthetic_oauth_customer`).

**Bug.** `find_active_customer_by_email` returns `Err((FORBIDDEN,
"oauth_customer_deleted"))` when the local row is `status='deleted'`. The
verified-email path consults this guard. But
`create_or_find_synthetic_oauth_customer` does NOT — on a unique-violation
conflict against the synthetic email, it only calls `find_oauth_identity`
and returns `OAUTH_SYNTHETIC_EMAIL_CONFLICT` (a generic 409). If a
soft-deleted row sits at `oauth-google-<sub>@oauth.flapjack.foo`, the next
OAuth call for that provider+sub yields a 409 with no `"deleted"` signal,
and the deleted-customer policy is silently bypassed for that branch.

**Impact.** Real-world likelihood is low (synthetic emails are sub-scoped,
so collision implies the same provider sub). The asymmetry is the smell:
a single test
(`oauth_exchange_rejects_deleted_customer_with_verified_google_email`)
covers only the verified-email path; the symmetric synthetic path is
unguarded and untested.

**Minimal fix.** In `create_or_find_synthetic_oauth_customer` at
lines 351-360, mirror `create_or_find_oauth_customer`: on
`RepoError::Conflict`, call `find_active_customer_by_email(state,
synthetic_email)` first to surface `oauth_customer_deleted`
consistently; fall back to `find_oauth_identity` only when the conflict
is on an active row. Add
`oauth_exchange_rejects_deleted_customer_via_synthetic_email_conflict` as a
regression test.

---

## DEFECT 2 (medium) — `oauth_state` cookie is not bound to the originating browser; classic OAuth login-CSRF / session-fixation precondition

**File:** `infra/api/src/routes/oauth.rs:79-122` (`start_oauth`),
`infra/api/src/routes/oauth.rs:128-198` (`exchange_oauth_code`).

**Bug.** The encrypted `oauth_state` cookie (AES-256-GCM, HKDF off
`jwt_secret`) is well-formed cryptographically, but the plaintext
(`OAuthState`) contains only `provider`, `csrf_state`, and an optional
`pkce_verifier`. There is no binding to the originating browser session,
no one-time-use marker, and no rejection when an `auth_token` is already
present. Because the encrypted blob is just a static cookie value valid
for `Max-Age=600`, an attacker can:

1. Drive their own OAuth start, harvest the resulting encrypted
   `oauth_state` cookie + the matching `state` query param,
2. Lure the victim to a URL that sets the same encrypted cookie (e.g. via
   a sibling subdomain under `.flapjack.foo` since `cookie_domain` is set
   to the apex) and points to
   `/oauth/callback/google?code=<attacker-code>&state=<attacker-state>`,
3. Victim's browser presents the attacker's cookie, the server validates
   `csrf_state == cookie.csrf_state` (TRUE), exchanges the code, and
   silently logs the victim into the attacker's account.

This is the standard "OAuth login fixation" vector — `state` alone does not
prevent it when the attacker controls both halves.

**Impact.** Login-fixation: any data the victim subsequently uploads
(search-index uploads, billing-plan changes, payment-method attach) accrues
to the attacker's account.

**Minimal fix.** Two options:

1. Add a `bound_session_id` field to `OAuthState` populated at start time
   from a fresh random value also written as a separate (non-encrypted)
   marker cookie (e.g. `oauth_state_binding`). Reject exchange when the
   marker cookie is missing or does not match the encrypted plaintext.
   ~30 LOC.
2. Refuse exchange when the request already presents a valid `auth_token`
   ("you are already logged in — sign out first"). Cheaper, narrower
   coverage.

Add `oauth_exchange_rejects_state_cookie_replayed_from_different_browser`
as a regression test.

---

## DEFECT 3 (low) — GitHub `email` is harvested into `OAuthProviderIdentity.email` but `email_verified` is hardcoded `false`; the field is dead state that future code may trust

**File:** `infra/api/src/routes/oauth.rs:480-491`.

**Bug.** GitHub's `/user` endpoint returns the user's *publicly visible*
email — possibly unverified or a no-reply alias. Current code assigns
`email: payload.email` then sets `email_verified: false`, which causes
`resolve_oauth_customer` to ignore the email entirely and fall to
synthetic-email creation (the safe default). But
`OAuthProviderIdentity.email` is now permanently unread for GitHub —
dead state that a future contributor will reasonably assume is
trustworthy.

**Minimal fix.** Either:

1. Call GitHub's `/user/emails` endpoint with the same access token (scope
   `user:email` is already requested at line 568), find the row where
   `primary=true && verified=true`, populate `email` +
   `email_verified=true` from that row. Restores GitHub auto-link parity
   with Google.
2. Set `email: None` for GitHub and document why.

Test: cover both `verified primary email present` and `only unverified
emails returned` cases.

---

## Worth flagging (no defect)

1. **GitHub does not use PKCE.** `provider_uses_pkce` returns `false` for
   GitHub. GitHub supports PKCE since 2023; the additional defense layer
   is cheap. Not strictly required since `client_secret` is server-side.
2. **`oauth_state` cookie name is fixed.** Predictable cookie names ease
   CSRF-correlation across `.flapjack.foo` subdomains. Pairs with
   Defect 2.
3. **OAuth routes share `auth_rate_limit_middleware`**
   (`route_assembly.rs:30-54`). Good — defends against exchange-code
   grinding. The dependency is load-bearing; any future refactor moving
   OAuth out of `build_auth_rate_limited_routes` reopens the brute-force
   gap.

---

## Test-quality verdict

Tests in `infra/api/tests/oauth_start_routes_test.rs` are NOT smoke tests —
they assert specific `customer_id` values do/don't match (`assert_ne!`),
specific error codes (`oauth_customer_unverified_local_conflict`,
`oauth_synthetic_email_conflict`, `oauth_customer_deleted`), and the mock
fixture `inject_oauth_create_conflict_with_concurrent_unverified_local`
forces the race-window path deterministically.
`oauth_exchange_does_not_auto_link_to_unverified_local_customer` would
fail on a real regression.

**Coverage gaps:** no test seeds a deleted synthetic-email row (Defect 1);
no test replays a state cookie across browser sessions (Defect 2); no
test exercises GitHub's `/user/emails` (Defect 3). No live OAuth
exchange against Google/GitHub in CI — wiremock only. Acceptable per the
testing taxonomy but the real provider userinfo response shape is not
contract-tested.

---

## Files reviewed

- `infra/api/src/routes/oauth.rs` (692 LOC, full)
- `infra/api/src/repos/pg_customer_repo.rs:225-282` (OAuth methods)
- `infra/api/src/repos/customer_repo.rs` (trait surface)
- `infra/api/src/router/route_assembly.rs:30-54` (rate-limit binding)
- `infra/migrations/048_oauth_identities.sql`
- `infra/api/src/main.rs:300-365` (cookie-policy build)
- `infra/api/src/state.rs:45-87` (`OAuthCookieSameSite`, defaults)
- `web/src/routes/oauth/callback/[provider]/+server.ts`
- `web/src/lib/server/auth-cookies.ts`
- `infra/api/tests/oauth_start_routes_test.rs` (848 LOC)
- `infra/api/tests/common/mocks.rs` (mock-repo conflict injection)
- `web/src/routes/oauth/callback/[provider]/oauth-callback.server.test.ts`
- `web/tests/e2e-ui/{full,smoke}/auth.spec.ts`

---

## Disposition

Per the handoff instruction "If you find a real defect: write a small
fix-forward PR rather than reverting" — these three defects warrant a
follow-up lane, NOT a revert. Defect 2 is the highest-priority of the
three (real attacker-controlled fixation primitive). Defect 1 is asymmetry
hardening. Defect 3 is dead-state cleanup.

Recommended next-session lane: `chats/icg/<date>_pm_<n>_oauth_postmerge_hardening.md`
addressing Defect 2 + adding the regression test, with Defects 1 and 3
queued behind it.
