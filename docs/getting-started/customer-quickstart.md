# Customer Quickstart (Account Creation to First Search)

This quickstart is the customer-facing source of truth for the first successful search flow.

- API reference: https://api.flapjack.foo/docs
- Pricing details: [Pricing FAQ](./pricing-faq.md)
- Error semantics: [Error Reference](./error-reference.md)

> Maintenance note: before changing any route, credential field, header, or payload example in this file, re-verify against the cited source files/tests at the bottom of this document.

## 1) Control Plane: create and verify your account

Set your control-plane API base URL:

```bash
export API_BASE_URL="https://api.flapjack.foo"
```

Register:

```bash
curl -X POST "$API_BASE_URL/auth/register" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Ada Example","email":"ada@example.com","password":"replace-with-strong-password"}'
```

- `register` requires non-empty `name`, `email`, and `password`.
- Successful `register` returns `201` with `token` and `customer_id`.
- Duplicate emails return `409` with `{"error":"email already registered"}`.

Verify your email (use the token from the verification email):

```bash
curl -X POST "$API_BASE_URL/auth/verify-email" \
  -H 'Content-Type: application/json' \
  -d '{"token":"<token-from-email>"}'
```

- Invalid or expired tokens return `400` with `{"error":"invalid or expired verification token"}`.

If you need a new verification email after login:

```bash
curl -X POST "$API_BASE_URL/auth/resend-verification" \
  -H "Authorization: Bearer $AUTH_TOKEN"
```

- `resend_verification` may return `429` with `Retry-After` when resend cooldown is active.

Login:

```bash
curl -X POST "$API_BASE_URL/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"ada@example.com","password":"replace-with-strong-password"}'
```

- Invalid credentials return `400` with `{"error":"invalid email or password"}`.

## 2) Onboarding status and credential generation

Check onboarding status:

```bash
curl -X GET "$API_BASE_URL/onboarding/status" \
  -H "Authorization: Bearer $AUTH_TOKEN"
```

The response is field-based and includes:

- `has_region`
- `region_ready`
- `has_index`
- `has_api_key`
- `completed`
- `suggested_next_step`

Generate credentials after at least one active endpoint and one customer index exist:

```bash
curl -X POST "$API_BASE_URL/onboarding/credentials" \
  -H "Authorization: Bearer $AUTH_TOKEN"
```

`generate_credentials` returns these fields:

- `endpoint`
- `api_key`
- `application_id`

Set them for data-plane requests:

```bash
export ENDPOINT="https://vm-abc.example.com"
export API_KEY="fj_search_xxx"
export APPLICATION_ID="flapjack"
export INDEX_NAME="my-first-index"
```

## 3) Data Plane: add your first document (`/batch`)

Use the Algolia-compatible headers and the verified `requests[]` batch envelope:

```bash
curl -X POST "$ENDPOINT/1/indexes/$INDEX_NAME/batch" \
  -H "X-Algolia-API-Key: $API_KEY" \
  -H "X-Algolia-Application-Id: $APPLICATION_ID" \
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

## 4) Data Plane: run your first search (`/query`)

```bash
curl -X POST "$ENDPOINT/1/indexes/$INDEX_NAME/query" \
  -H "X-Algolia-API-Key: $API_KEY" \
  -H "X-Algolia-Application-Id: $APPLICATION_ID" \
  -H 'Content-Type: application/json' \
  -d '{"query":"hello"}'
```

A successful response includes fields such as `hits` and `nbHits`.

## Source Evidence

- Canonical public API origin and docs URL: `web/src/lib/public_api.ts` (`CANONICAL_PUBLIC_API_BASE_URL`, `CANONICAL_PUBLIC_API_DOCS_URL`).
- Auth handlers and error semantics: `infra/api/src/routes/auth.rs` (`register`, `login`, `verify_email`, `resend_verification`).
- Shared JSON error envelope: `infra/api/src/errors.rs` (`ErrorResponse`, `ApiError::into_response`).
- Onboarding status and credentials ownership: `infra/api/src/routes/onboarding.rs` (`get_status`, `generate_credentials`).
- Data-plane headers and index proxy behavior: `infra/api/src/services/flapjack_proxy/mod.rs`, `infra/api/src/routes/indexes/mod.rs`.
