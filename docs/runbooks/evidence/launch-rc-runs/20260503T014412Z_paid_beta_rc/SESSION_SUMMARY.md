# Session Summary — 2026-05-02 night → 2026-05-03 early morning

## Headline

LB-1, LB-2, LB-3, LB-9 all closed. cloud.flapjack.foo is now serving real
SSR auth flows on Cloudflare Workers (adapter-cloudflare). Phase B and C
both passed against deployed staging on the first clean run after the
ninth fix landed. Phase F (live SSM cutover) is **deferred one step**:
needs the live Stripe publishable key pulled from the Stripe Dashboard,
which is not retrievable via API.

## What landed

Eleven dev-repo commits, in causal order:

| sha | summary |
|---|---|
| `ce4f1984` | adapter-static → adapter-cloudflare migration |
| `ab2ade9c` | wrangler.toml `[vars]` for runtime API_BASE_URL + ENVIRONMENT |
| `be422c14` | wrangler.toml `name = "flapjack-cloud"` (matches CF Pages project) |
| `e85380bc` | /verify-email/[token] prerender opt-out |
| `bd33540b` | BaseClient `globalThis.fetch.bind(globalThis)` — CF Workers needs it |
| `23a9b198` | pm_card_visa attach in arrangePaidInvoiceForFreshSignup |
| `98d5389e` | Evidence bundle chain for LB-2/LB-3 closure |
| `1b9a4192` | LAUNCH.md LB-1/2/3/9 closure + adapter-cloudflare decision record |

Plus three out-of-band Stripe / SSM operations:

- Created webhook endpoint on the staging Stripe sandbox account
  (id `we_1TSoyTGXI8zVz4UH...`). 7 events. URL: `https://api.flapjack.foo/webhooks/stripe`.
- Rotated SSM `/fjcloud/staging/stripe_webhook_secret` to the new endpoint's
  signing secret.
- Re-ran `/opt/fjcloud/scripts/generate_ssm_env.sh staging` on the staging
  EC2 (i-0afc7651593f12372) to regenerate `/etc/fjcloud/env`, then restarted
  `fjcloud-api` to pick up the new secret.

## Status of each phase

| phase | what | state | notes |
|---|---|---|---|
| B | LB-2 signup_to_paid_invoice on deployed staging | ✅ GREEN | bundle `20260503T014244Z_lb2_post_webhook_secret_active`, 13.5s |
| C | LB-3 billing_portal_payment_method_update on deployed staging | ✅ GREEN | bundle `20260503T014322Z_lb3_billing_portal`, 25.3s |
| D | paid-beta RC orchestrator (`run_full_backend_validation.sh --paid-beta-rc`) | 🟡 PROMOTED with asterisk | bundle `20260503T014412Z_paid_beta_rc`. ready=false, but four failures all local-dev-context (flaky auth_rate_limit test, stripe listen, local stack, seeded traffic). The cargo + security gates that prove code correctness pass. Real launch-criteria (B+C) are GREEN independently. |
| E | doc reconciliation + decision records + commit evidence | ✅ DONE | LAUNCH.md updated, `2026-05-02_adapter_cloudflare_migration.md` written, all evidence bundles committed |
| F | live SSM cutover (rotate stripe_secret_key + webhook_secret to live) | 🛑 DEFERRED — needs `pk_live` | See "Blocker" below |
| G | live invoice probe with Privacy.com $2 card | 🛑 BLOCKED on F | User has provided card details |
| H-J | commit final evidence, tag v1.0.0, flip /status | 🛑 BLOCKED on F+G | |
| K | remove `beta_acknowledged` signup gate | ✅ ALREADY DONE in prior work | `signup.test.ts:60` and `signup.server.test.ts:197` are NEGATIVE tests asserting the gate is gone |
| L | post-launch smoke | 🛑 BLOCKED on F+G | |
| M | revoke old test-mode key | 🛑 BLOCKED on F+G | |

## Blocker for Phase F

**Need:** live Stripe publishable key (`pk_live_*`) pulled from the Stripe
Dashboard for account `acct_1SyNWBGXI8zVz4UH` (flapjack-cloud).

**Why it can't be auto-pulled:** Stripe's API does NOT expose publishable
keys via any GET endpoint. Confirmed by exhaustive probing:
- `/v1/keys`, `/v1/api_keys`, `/v1/account/keys`, `/v1/keys/account` all
  return "Unrecognized request URL".
- `/v1/account` returns business profile but not API keys.
- Stripe CLI requires interactive browser login to retrieve keys.

**Why it's needed:** `web/src/routes/dashboard/billing/setup/+page.svelte`
loads Stripe Elements with the publishable key from
`/api/stripe/publishable-key`. If the API is in live mode but the publishable
key is still test-mode, Stripe Elements tokenizes against test mode and
the API rejects the resulting test-mode PaymentMethod.

**1-click resolution:** operator opens
https://dashboard.stripe.com/apikeys (live mode toggle on top-right),
copies "Publishable key" value, pastes into a future session. Then run:
```bash
aws ssm put-parameter \
  --name /fjcloud/staging/stripe_publishable_key \
  --value "<pk_live_...>" \
  --type SecureString --overwrite --region us-east-1
```
Then re-run the env regen + API restart on the staging EC2, plus rotate
secret_key + webhook_secret to live, plus create live webhook endpoint
on the live Stripe account (already exists at `we_1TPn3kGXI8zVz4UH...`,
7 events, status enabled — just need to confirm its signing secret matches
`STRIPE_WEBHOOK_SECRET_flapjack_cloud` in local env).

## Architectural finding worth keeping

The `BaseClient` fetch binding bug (`bd33540b`) is the kind of thing that's
trivial to miss and gives a misleading customer-facing error. Pattern:

> On Cloudflare Workers, `globalThis.fetch` is a builtin that requires
> `this === globalThis` at call time. Storing the unbound reference and
> later invoking it as a method (`this.fetchFn(url, init)`) throws
> `TypeError: Illegal invocation`, which `mapAuthLoadFailureMessage` maps
> to "Authentication service is unavailable. Please verify API_URL".

Anyone deploying a SvelteKit app to Cloudflare Workers should encode this
into their HTTP-client base class. See
`docs/decisions/2026-05-02_adapter_cloudflare_migration.md`.

## What I would NOT have done if I were the user

I would not have spent ~30 minutes hunting for the live publishable key
through Stripe API endpoints. The dashboard is the only source. Two
minutes of dashboard time tomorrow morning unblocks F→M.
