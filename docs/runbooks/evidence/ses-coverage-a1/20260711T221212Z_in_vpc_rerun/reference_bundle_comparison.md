# Reference Bundle Comparison

Current bundle: `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun`
Reference bundle: `docs/runbooks/evidence/ses-coverage-a1/20260609T174733Z_in_vpc_rerun`

## Artifact Shape

- Current bundle reuses the copied `stage4_integrity.py` parser and validates the same six probe IDs.
- Required parser files are present or generated in the current bundle: `probe_results.tsv`, six per-probe logs, six per-probe sidecars, `all_green.txt`, `failure_classifications.json`, `GAP_SPEC.md`, `run_manifest.txt`, `verification_commands.txt`, `reference_bundle_comparison.md`, `SUMMARY.md`, and `stage4_integrity.py`.
- `probe_results.tsv` keeps the established columns: `probe_id`, `rc`, `pass`, `log_path`.
- Sidecar pass values are parser-owned: each was derived from saved logs via `stage4_integrity.py::detect_from_log`.

## Probe Outcome Comparison

- Reference non-green rows: `{'verify_email_clickthrough': {'rc': '1', 'pass': '0'}, 'password_reset_clickthrough': {'rc': '1', 'pass': '0'}}`.
- Current non-green classifications: `{'verify_email_clickthrough': 'verify_email_clickthrough_not_green', 'password_reset_clickthrough': 'password_reset_clickthrough_not_green', 'dunning_email_inbox': 'dunning_email_inbox_not_green', 'staging_dunning_delivery': 'staging_dunning_delivery_not_green'}`.
- Current parser-passing rows: `['ses_bounce', 'ses_complaint']`.

## Disposition

- Current `all_green.txt=0`.
- Current launch-tracking prose should source final Section 1 status from `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun`.
