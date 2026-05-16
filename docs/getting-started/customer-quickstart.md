# Customer Quickstart (Account Creation to First Search)

This quickstart is the customer-facing source of truth for the first successful search flow.

> Maintenance note: before changing any route, credential field, header, or payload example in this file, re-verify against the cited source files/tests at the bottom of this document.

## 1) Control Plane: create and verify your account

Set your control-plane API base URL:

```bash
export API_BASE_URL="https://api.example.com"
```

Register:

```bash
curl -X POST "$API_BASE_URL/auth/register" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Ada Example","email":"ada@example.com","password":"replace-with-strong-password"}'
```

Verify your email (use the token from the verification email):

```bash
curl -X POST "$API_BASE_URL/auth/verify-email" \
  -H 'Content-Type: application/json' \
  -d '{"token":"<token-from-email>"}'
```

Login:

```bash
curl -X POST "$API_BASE_URL/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"ada@example.com","password":"replace-with-strong-password"}'
```

The quickstart intentionally excludes password-reset and resend-verification flows so this section stays focused on reaching the dashboard.

## 2) Onboarding: create first index and get credentials

From the dashboard onboarding wizard:

1. Choose a region and index name.
2. Submit the create step (backend route: `POST /indexes`).
3. Retrieve credentials (backend route: `POST /onboarding/credentials`).

Credentials returned by onboarding are:

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

- Control-plane route usage (`/auth/register`, `/auth/login`, `/auth/verify-email`): `web/src/lib/api/client.ts` lines 162-172.
- Control-plane payload contracts (`RegisterRequest`, `LoginRequest`, `VerifyEmailRequest`): `web/src/lib/api/types.ts` lines 15-28.
- Control-plane route registrations: `infra/api/src/router/route_assembly.rs` lines 24-25 and 71-72.
- Onboarding create index and credential routes: `web/src/lib/api/client.ts` lines 278-280 and 655-656; `infra/api/src/router/route_assembly.rs` lines 181-183 and 371-374.
- Credential field names (`endpoint`, `api_key`, `application_id`): `web/src/lib/api/types.ts` lines 698-702; `infra/api/tests/onboarding_credentials_test.rs` lines 150-153.
- Required data-plane headers: `infra/api/src/services/flapjack_proxy/mod.rs` lines 111-114.
- `/batch` payload contract (`requests[]`) and rejection of legacy `documents[]`: `web/src/routes/dashboard/indexes/[name]/document-management.server.ts` lines 136-152 and 246-248; `infra/api/tests/indexes_test.rs` lines 6908-6913, 6940, and 6948-6971.
- `/query` engine route shape: `infra/api/tests/indexes_test.rs` line 3794.
