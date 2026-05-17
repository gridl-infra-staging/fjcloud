# Privacy.com Contract (Stage 1 Canonical Note)

## Purpose

Stage 1 locks external Privacy.com API contract truth and internal fjcloud
billing/reconciliation owners before Stage 2-4 implementation work.

## Scope

- In scope: documented live API shape backed by reproducible probe evidence.
- In scope: locked internal billing trigger and webhook reconciliation owners.
- Out of scope: introducing any alternate charge path or runtime code changes.

## Evidence Sources

- Live probe bundle: `docs/runbooks/evidence/privacy_com_contract/20260516T001549Z_live_probe/`
- Evidence index: `docs/runbooks/evidence/privacy_com_contract/README.md`
- Privacy docs (reference-only, verified against live probes):
  - https://developers.privacy.com/docs/cards
  - https://developers.privacy.com/docs/api-basics
  - https://developers.privacy.com/reference/get_cards-1

## Live API Contract (Verified 2026-05-16)

### Auth header contract

Observed against `GET https://api.privacy.com/v1/cards?page=1&page_size=2`:

- `Authorization: <api_key>` returned `HTTP/2 200`.
  Evidence: `01_list_cards_auth_raw.meta`, `01_list_cards_auth_raw.headers.txt`
- `Authorization: api-key <api_key>` returned `HTTP/2 200`.
  Evidence: `02_list_cards_auth_api_key.meta`, `02_list_cards_auth_api_key.headers.txt`
- Missing Authorization header returned `HTTP/2 403` (HTML body).
  Evidence: `03_list_cards_missing_auth.meta`, `03_list_cards_missing_auth.body.redacted.txt`

Stage 2 drift checks should accept both header forms as live-compatible and treat
missing auth as failure.

### Endpoint paths and request shapes

- List cards: `GET /v1/cards?page=<int>&page_size=<int>`
  - Response wrapper includes top-level `data`, `page`, `total_entries`, `total_pages`.
  - Evidence: `01_list_cards_auth_raw.body.redacted.json`
- Create card: `POST /v1/cards`
  - Probe request fields: `type`, `memo`, `spend_limit`, `spend_limit_duration`, `state`
  - Evidence: `probe_commands.sh`, `04_create_card.meta`, `04_create_card.body.redacted.json`
- Update card: `PATCH /v1/cards/{card_token}`
  - Probe request field: `state`.
  - Evidence: `probe_commands.sh`, `05_update_card_closed.meta`, `05_update_card_closed.body.redacted.json`
- Get single card: `GET /v1/cards/{card_token}`
  - Evidence: `06_get_card_after_close.meta`, `06_get_card_after_close.body.redacted.json`

### Required response fields (from live payloads)

At minimum, Stage 2 checks should assert existence and non-empty values for:

- Top-level list wrapper: `data`, `page`, `total_entries`, `total_pages`
- Card object: `token`, `state`, `type`, `spend_limit`, `spend_limit_duration`,
  `created`, `funding`, `exp_month`, `exp_year`
- Funding object: `token`, `state`, `type`, `created`

## OPEN -> CLOSED State Transition Semantics

Verified with a live create/update/get sequence:

1. Create card returned state `OPEN` (`04_create_card.body.redacted.json`).
2. Patch same card with `{"state":"CLOSED"}` returned state `CLOSED`
   (`05_update_card_closed.body.redacted.json`).
3. Follow-up GET returned state `CLOSED`
   (`06_get_card_after_close.body.redacted.json`).

Contract truth for this lane: `CLOSED` is terminal for this state transition
sequence and is observable immediately in follow-up GET.

## Internal Billing Owners

The only accepted in-system billing execution path for this lane is:

- Route wiring: `POST /admin/billing/run` in
  `infra/api/src/routes/admin/mod.rs` (line 89)
- Implementation owner: `infra/api/src/routes/admin/invoices.rs::run_batch_billing`
  (line 174)

Any alternate charge path is out-of-scope for Stage 1.

## Webhook Reconciliation Owners

The accepted downstream reconciliation surface is locked to:

- `infra/api/src/routes/webhooks.rs::stripe_webhook` (line 82)
- `infra/api/src/routes/webhooks.rs::handle_payment_succeeded` (line 209)
- `infra/api/src/routes/webhooks.rs::handle_payment_failed` (line 274)
- `infra/api/src/routes/webhooks.rs::handle_payment_action_required` (line 315)
- `infra/api/src/routes/webhooks.rs::handle_charge_refunded` (line 354)

No additional webhook reconciliation owners are introduced in this stage.

## Stage 2 Contract Assertions (SSOT)

`scripts/lib/privacy_com_client_test.sh` should assert exactly:

1. Auth/header checks:
- Raw header (`Authorization: <api_key>`) returns 2xx on list-cards probe.
- Prefixed header (`Authorization: api-key <api_key>`) returns 2xx.
- Missing auth returns non-2xx (observed 403).

2. Schema wrapper checks on list response:
- Top-level keys: `data`, `page`, `total_entries`, `total_pages`
- `data` is an array.

3. Card object key checks:
- Required keys: `token`, `state`, `type`, `spend_limit`, `spend_limit_duration`,
  `created`, `funding`, `exp_month`, `exp_year`
- Funding required keys: `token`, `state`, `type`, `created`

4. State transition checks:
- POST-created card state is `OPEN`.
- PATCH state update to `CLOSED` returns `CLOSED`.
- Follow-up GET for that card returns `CLOSED`.

## Open Questions

- The probe requested `spend_limit_duration: "TRANSACTION"` on create, but the
  response returned `"FOREVER"` (`04_create_card.body.redacted.json`).
  Stage 2 should include an explicit assertion to detect whether this is fixed
  server normalization behavior for this account/card type or transient drift.
- Checklist references `scripts/lib/privacy_com_client_test.sh`, but that file
  does not exist at current HEAD. Stage 2 needs to confirm target path/owner
  before adding the contract test harness.
