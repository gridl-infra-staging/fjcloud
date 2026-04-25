<!-- [scrai:start] -->
## stripe

| File | Summary |
| --- | --- |
| configure_billing_portal.sh | Configure the canonical Stripe Customer Portal configuration against a
specific Stripe account, while keeping return_url ownership outside this
script (owned by app/server session creation paths).

Account selection (see docs/design/secret_sources.md#stripe-multi-account):
  --account <name>     Resolve STRIPE_SECRET_KEY_<name> from env.
                       Operators working with multiple Stripe accounts
                       keep each account's key under a namespaced name
                       in .secret/.env.secret (e.g. |
| create_catalog.sh | Stub summary for create_catalog.sh. |
<!-- [scrai:end] -->
