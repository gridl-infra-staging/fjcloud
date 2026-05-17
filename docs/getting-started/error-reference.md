# Error Reference

This reference lists verified response envelopes, status codes, and ownership seams for customer-facing API errors.

## Shared error envelope

The shared API error envelope is:

```json
{"error":"<message>"}
```

This shape is defined by `ErrorResponse` and emitted by `ApiError::into_response`.

## Auth route examples

From `infra/api/src/routes/auth.rs`:

- `POST /auth/register`
- `400` `{"error":"name, email, and password are required"}` for missing required fields.
- `409` `{"error":"email already registered"}` for duplicate email.

- `POST /auth/login`
- `400` `{"error":"invalid email or password"}` for credential mismatch.

- `POST /auth/verify-email`
- `400` `{"error":"invalid or expired verification token"}` for invalid token.

- `POST /auth/resend-verification`
- `400` `{"error":"email already verified"}` when already verified.
- `429` `{"error":"verification email recently sent; retry later"}` with `Retry-After` header during cooldown.
- `503` `{"error":"verification email temporarily unavailable"}` when email service is unavailable.

## Onboarding route examples

From `infra/api/src/routes/onboarding.rs`:

- `POST /onboarding/credentials`
- `400` `{"error":"No active endpoint yet"}` when no running deployment exists.
- `400` `{"error":"Create at least one index before generating credentials"}` when no customer indexes exist.

## Index route status behavior

Index routes share rate-limit enforcement utilities in `infra/api/src/routes/indexes/mod.rs`:

- `429` is returned by query and write limit checks.
- `Retry-After` is included on these 429 responses.
- Body shape for 429 follows the shared envelope (`{"error":"..."}`).

Index routes also use shared `ApiError` mapping from `infra/api/src/errors.rs`:

- `410` is represented by `ApiError::Gone`.
- `503` is represented by `ApiError::ServiceUnavailable`.

## Request ID troubleshooting

`infra/api/src/middleware/request_id.rs` defines UUID request-id generation for requests that do not already include an `x-request-id` header. Treat request IDs as middleware-owned and not always server-generated, because incoming headers may already provide one.

## Source Evidence

- Shared envelope and status mapping: `infra/api/src/errors.rs` (`ErrorResponse`, `ApiError`, `IntoResponse`).
- Auth error examples and cooldown headers: `infra/api/src/routes/auth.rs` (`register`, `login`, `verify_email`, `resend_verification`).
- Onboarding error examples: `infra/api/src/routes/onboarding.rs` (`generate_credentials`).
- Index 429 + `Retry-After`: `infra/api/src/routes/indexes/mod.rs` (`rate_limited_response`, `enforce_query_rate_limit`, `enforce_write_rate_limit`).
- Request ID ownership: `infra/api/src/middleware/request_id.rs` (`UuidRequestId`).
