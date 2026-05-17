---
created: 2026-05-15
updated: 2026-05-15
---

# GitHub `/user/emails` API Contract

## Endpoint

`GET https://api.github.com/user/emails`

Authorization: `Bearer <access_token>` (requires `user:email` scope, requested at `infra/api/src/routes/oauth.rs` in the GitHub `authorize_url` construction).

## Response Schema

Returns a JSON array of email entry objects:

```json
[
  {
    "email": "octocat@github.com",
    "primary": true,
    "verified": true,
    "visibility": "public"
  },
  {
    "email": "octocat-backup@example.com",
    "primary": false,
    "verified": false,
    "visibility": null
  }
]
```

## Fields Used by fjcloud

| Field      | Type   | Usage                                                                 |
|------------|--------|-----------------------------------------------------------------------|
| `email`    | String | Used as the customer email when `primary == true && verified == true`  |
| `primary`  | bool   | Selects which entry to use (first where `primary == true`)            |
| `verified` | bool   | Drives `OAuthProviderIdentity.email_verified` — unverified triggers synthetic email path |

## Source

GitHub REST API docs: "List email addresses for the authenticated user"
(`GET /user/emails`, OAuth scope `user:email`).

## Contract Test

An inline `#[test]` in `infra/api/src/routes/oauth.rs` deserializes a captured fixture matching this schema into `Vec<GitHubEmailEntry>` and asserts field values, validating our deserialization contract against the documented schema.
