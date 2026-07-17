# Customer Quickstart (Account Creation to First Search)

This quickstart is the customer-facing source of truth for the first successful search flow.

- API reference: https://api.flapjack.foo/docs
- Pricing details: [Pricing FAQ](./pricing-faq.md)
- Error semantics: [Error Reference](./error-reference.md)
- Route-mapping evidence: [Algolia to fjcloud Route Mapping and Gaps](../runbooks/evidence/algolia_api_mapping/20260603T180703Z/gaps.md)

> Maintenance note: before changing any route, credential field, header, or payload example in this file, re-verify against the cited source files/tests at the bottom of this document.

## 1) Set the API base URL

```bash
export API_BASE_URL="https://api.flapjack.foo"
export INDEX_NAME="my-first-index"
export INDEX_REGION="us-east-1"
```

## 2) Register

<!-- validate_customer_quickstart: auth_register -->
```bash
curl -X POST "$API_BASE_URL/auth/register" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Ada Example","email":"ada@example.com","password":"replace-with-strong-password"}'
```

`register` requires non-empty `name`, `email`, and `password`. A successful response returns `201` with a JWT `token` and `customer_id`.

```bash
export AUTH_TOKEN="<token-from-register-response>"
```

Duplicate emails return `409` with `{"error":"email already registered"}`.

## 3) Verify your email

Use the token from the verification email.

<!-- validate_customer_quickstart: auth_verify_email -->
```bash
curl -X POST "$API_BASE_URL/auth/verify-email" \
  -H 'Content-Type: application/json' \
  -d '{"token":"<token-from-email>"}'
```

Invalid or expired verification tokens return `400` with `{"error":"invalid or expired verification token"}`.

## 4) Create an index

Email verification is required before index creation succeeds.

<!-- validate_customer_quickstart: indexes_create -->
```bash
curl -X POST "$API_BASE_URL/indexes" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"$INDEX_NAME\",\"region\":\"$INDEX_REGION\"}"
```

Use an available region from your environment. Invalid regions return `400`; duplicate index names return `409`.

## 5) Add your first document

The control-plane batch route accepts a `requests[]` envelope. Use `addObject` to add a document.

<!-- validate_customer_quickstart: indexes_batch_add_object -->
```bash
curl -X POST "$API_BASE_URL/indexes/$INDEX_NAME/batch" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "requests": [
      {
        "action": "addObject",
        "body": {
          "objectID": "doc-1",
          "title": "My first document",
          "body": "Hello, world!"
        }
      }
    ]
  }'
```

## 6) Run your first search

<!-- validate_customer_quickstart: indexes_search -->
```bash
curl -X POST "$API_BASE_URL/indexes/$INDEX_NAME/search" \
  -H "Authorization: Bearer $AUTH_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"query":"hello"}'
```

A successful response includes fields such as `hits` and `nbHits`.

## Secondary account and credential notes

The first-search sequence above uses the registration JWT returned by `POST /auth/register`. Existing customers can sign in through the login route to obtain a fresh JWT, and unverified customers can request a new verification email through the resend-verification route after authenticating.

Onboarding status remains useful for dashboard guidance, but it is not required for the first-search path. The optional credential-generation seam in `infra/api/src/routes/onboarding.rs::generate_credentials` creates search/browse keys after a running deployment and at least one customer index exist; it is covered by `infra/api/tests/integration/onboarding_credentials_test.rs:19-221` and is not the default write/search path in this quickstart.

## Source Evidence

- Canonical public API origin and docs URL: `web/src/lib/public_api.ts` (`CANONICAL_PUBLIC_API_BASE_URL`, `CANONICAL_PUBLIC_API_DOCS_URL`).
- Stage 1 route mapping source of truth: `docs/runbooks/evidence/algolia_api_mapping/20260603T180703Z/gaps.md`.
- Route registration: `infra/api/src/router/route_assembly.rs` (`add_index_lifecycle_and_replica_routes`, `add_index_configuration_routes`, `add_onboarding_routes`).
- Auth handlers and error semantics: `infra/api/src/routes/auth.rs` (`register`, `verify_email`, `login`, `resend_verification`).
- Index handlers: `infra/api/src/routes/indexes/lifecycle.rs` (`create_index`), `infra/api/src/routes/indexes/documents.rs` (`batch_documents`), and `infra/api/src/routes/indexes/search.rs` (`test_search`).
- Optional credential-generation seam: `infra/api/src/routes/onboarding.rs` (`generate_credentials`) and `infra/api/tests/integration/onboarding_credentials_test.rs`.
- Canary-backed customer flow: `scripts/canary/customer_loop_synthetic.sh` (`run_signup_step`, `run_verify_email_step`, `run_index_create_step`, `run_index_batch_step`, `run_index_search_step`).
