# Operator Action Required — Stripe cutover prerequisites

The Stage 1 prerequisite gate failed. Update the operator secret source and re-run:
FJCLOUD_SECRET_FILE="${FJCLOUD_SECRET_FILE:-.secret/.env.secret}" bash scripts/stripe_cutover_prereqs.sh

Secret source: .secret/.env.secret
Generated UTC: 20260429T053054Z
Repo SHA: de778a7370a8285f5e0cf4c8d1b3468fde8bc7eb

Missing inputs:
- STRIPE_SECRET_KEY_RESTRICTED is missing
- Comment marker is missing: # STRIPE_RESTRICTED_KEY_ID=<stripe_key_id>
- Comment marker is missing: # STRIPE_OLD_KEY_ID=<stripe_key_id>
