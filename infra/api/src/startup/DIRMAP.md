<!-- [scrai:start] -->
## startup

| File | Summary |
| --- | --- |
| unconfigured_stripe.rs | Stub `StripeService` returning `NotConfigured` for every operation.



Extracted from `startup.rs` so that file stays within the 800-line

limit enforced by `scripts/check-sizes.sh` in the staging CI pipeline.

Used when `STRIPE_SECRET_KEY` is not set; the rest of the API can

still bootstrap (free-tier signups, admin tooling, etc.) and any

Stripe-gated handler returns the `NotConfigured` variant cleanly. |
<!-- [scrai:end] -->
