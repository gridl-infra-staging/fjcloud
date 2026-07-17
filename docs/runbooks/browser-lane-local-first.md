# Browser lanes: iterate locally, gate on staging once

**TL;DR — when you touch the LB-2/LB-3 specs or the Stripe billing flows they
cover, iterate with the LOCAL lane and run the staging lane only once at the
end.** The local lane runs the *same* specs against a local stack in ~1 minute
with no deploy; the staging lane is a 30–60 min-per-iteration deploy cycle.
Using the staging lane as the debug loop is the anti-pattern this runbook
exists to kill.

## The two lanes

| | Local lane | Staging lane |
|---|---|---|
| Script | `scripts/launch/run_browser_lane_locally.sh` | `scripts/launch/run_browser_lane_against_staging.sh` |
| Target | local stack (SvelteKit + Rust API + flapjack on localhost) | deployed `cloud.staging.flapjack.foo` / `api.staging.flapjack.foo` |
| Specs | `signup_to_paid_invoice` (LB-2), `billing_portal_payment_method_update` (LB-3) — **identical** to staging | same specs |
| Stripe | real **test mode** — `pk_test`/`sk_test` hydrated from SSM (`/fjcloud/staging/stripe_*`) | real test mode via the deployed API |
| Loop time | ~1 min/run (after the first `cargo build`) | ~30–60 min/run (push → `debbie sync` → mirror CI → SSM/Pages deploy → run) |
| Role | **inner debug loop** — where you actually fix things | **final gate** — one run to capture launch-gate evidence |

## Why local is faithful (and where it isn't)

The local lane hydrates its Stripe keys from the **same SSM parameters as
staging**, which resolve to the **same Stripe sandbox** (verified: both
`.secret`'s `sk_test` and SSM's `pk_test`/`sk_test` are account
`acct_1Sy…`). Because the Stripe Payment Element and its available
payment-method set are driven by that sandbox's dashboard config, Payment
Element behavior — including account-level automatic payment methods (Pix,
Klarna, …) that caused the LB-3 hang — **reproduces identically locally**. So a
local green on a code fix is a trustworthy predictor of staging green for that
fix.

The one thing local **cannot** prove is the deploy itself and anything that
differs by *deployment* rather than *code*: the API binary actually shipping to
the EC2 fleet, the web bundle actually reaching the Cloudflare Pages alias, and
any staging-only Stripe **webhook** wiring. That is exactly why the staging lane
remains a required launch gate ([LAUNCH.md](../../LAUNCH.md): "validated on
staging, delivered on prod") — not something the local lane replaces.

## The workflow

1. **Iterate locally.** Make the code/spec change, then:
   ```bash
   set -a; source .secret/.env.secret; set +a   # AWS creds for SSM hydrate
   bash scripts/launch/run_browser_lane_locally.sh --lane billing_portal_payment_method_update
   ```
   Repeat until the lane exits 0. (Requires Postgres up on the `.env.local`
   `DATABASE_URL` and a reachable `flapjack` binary; the launcher hydrates
   Stripe test keys, starts the stack in real-test-Stripe mode, runs the spec,
   and tears down only its own processes.)
2. **Land + deploy** the fix through the normal path (dev `main` → `debbie sync
   staging` → mirror CI, which now deploys **both** the API plane and the web
   plane — see [deploy_surfaces.md](deploy_surfaces.md)).
3. **Gate on staging — once.** After the fix is green locally *and* deployed,
   run `scripts/launch/run_browser_lane_against_staging.sh --lane both` a single
   time to capture the launch-gate evidence bundle. Do **not** use this run to
   discover what's broken — that discovery belongs in step 1.

## Why this runbook exists

A stage that was scoped as "re-run the staging browser lane" instead used the
staging lane as its *debug loop*: it edited the Stripe flow, redeployed to
shared staging, and re-ran — repeatedly — each ~30–60 min lap revealing one more
Stripe-Element quirk, and several laps lost entirely to a stale Cloudflare Pages
deploy. That consumed a ~12-hour session. Every one of those quirks reproduces
locally in ~1 minute. The fix is not more discipline in the moment — it is
making the local lane the default and writing it down here so future stage
checklists inherit "iterate locally, gate on staging once" instead of
re-encoding the anti-pattern.
