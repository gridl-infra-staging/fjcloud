# Reference Bundle Comparison

Current bundle: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun`
Reference bundle: `docs/runbooks/evidence/ses-coverage-a1/20260609T174733Z_in_vpc_rerun`

## Artifact Shape

- Current bundle reuses the copied `stage4_integrity.py` parser and validates the same six probe IDs.
- Sidecar pass values are parser-owned: each was derived from saved logs via `stage4_integrity.py::detect_from_log`.

## Probe Outcome Comparison

- Current parser-passing rows: `['ses_bounce', 'ses_complaint']`.
- Current non-green classifications: `['verify_email_not_marked_verified', 'password_reset_token_not_cleared', 'dunning_email_inbox_non_green', 'staging_dunning_delivery_non_green']`.
