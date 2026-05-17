# Privacy.com Contract Evidence Index

## Purpose

This directory is the canonical evidence index for the live Privacy.com
contract and related live-card validation runs. It captures reproducible CLI
probes and redacted raw artifacts used by
`docs/runbooks/privacy_com_contract.md`, plus linked Stage 5 rerun summaries.

## Evidence Runs

### 2026-05-16 live probe (`20260516T001549Z_live_probe`)

- Runner: `docs/runbooks/evidence/privacy_com_contract/20260516T001549Z_live_probe/run_live_probe.sh`
- Command:

```bash
set -a
source .secret/.env.secret
set +a
bash docs/runbooks/evidence/privacy_com_contract/20260516T001549Z_live_probe/run_live_probe.sh \
  docs/runbooks/evidence/privacy_com_contract/20260516T001549Z_live_probe
```

- Request templates (with placeholder secrets):
  - `docs/runbooks/evidence/privacy_com_contract/20260516T001549Z_live_probe/probe_commands.sh`

### 2026-05-16 Stage 5 prod rerun failure (`live_card_e2e/fjcloud_live_e2e_evidence_20260516T032223Z_49117`)
- Summary: `docs/runbooks/evidence/privacy_com_contract/live_card_e2e/fjcloud_live_e2e_evidence_20260516T032223Z_49117/summary.json` (`classification=privacy_card_create_failed`)

## Stage 6 Canonical Operator Sequence Pointer

- Operator runbook owner: `docs/runbooks/live_card_e2e.md`
- Canonical command chain:
  - `bash scripts/lib/privacy_com_client_test.sh`
  - `bash scripts/launch/privacy_card_sweeper_test.sh`
  - `bash scripts/launch/live_card_e2e_test.sh --env=prod`
  - `bash scripts/check-sizes.sh`
  - `bash scripts/local-ci.sh --full`
- External blocker terminology is fixed to
  `classification=privacy_card_create_failed` + Privacy.com `HTTP 405 max allowed Card limit`.

### Captured artifacts

- Auth contract probes:
  - `01_list_cards_auth_raw.*`
  - `02_list_cards_auth_api_key.*`
  - `03_list_cards_missing_auth.*`
- Card lifecycle probes:
  - `04_create_card.*`
  - `05_update_card_closed.*`
  - `06_get_card_after_close.*`
- Rollup summary:
  - `summary.json`

All response bodies are redacted for PAN/CVV/cardholder identifiers and UUID
resource tokens. Header captures redact session cookie values.
