# Upgrade Trust-Ratchet Evidence

Evidence bundle for the self-service  trust-ratchet contracts.

## Contracts Tested

| Contract | Payment Method | Expected HTTP | Evidence Dir |
|----------|---------------|---------------|--------------|
| success-paid |  | 200 |  |
| declined-402 |  | 402 |  |
| requires_action-402 |  | 402 |  |

## Per-Contract Artifacts

Each subdirectory contains:
-  — customer_id and stripe_customer_id audit identifiers
-  —  before upgrade attempt
-  — raw response body from 
-  — HTTP status code
-  —  after upgrade attempt
-  — pass/fail summary
-  (success path only) — Stripe invoice confirming paid status

## Trust-Ratchet Verification

- **success-paid**: Plan transitions free→shared,  is set, Stripe invoice is 
- **declined-402**: Plan stays ,  remains  (customer can retry), response contains 
- **requires_action-402**: Plan stays ,  remains , response contains 
