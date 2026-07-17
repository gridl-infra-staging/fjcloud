# Reference Bundle Comparison

Current bundle: `docs/runbooks/evidence/ses-coverage-a1/20260609T174733Z_in_vpc_rerun`
Reference bundle: `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun`

## Artifact Shape

- Current bundle reuses the copied `stage4_integrity.py` parser and validates the same six probe IDs.
- Required parser files are present or generated in the current bundle: `probe_results.tsv`, six per-probe logs, six per-probe sidecars, `all_green.txt`, `failure_classifications.json`, `GAP_SPEC.md`, `run_manifest.txt`, `verification_commands.txt`, `reference_bundle_comparison.md`, `SUMMARY.md`, and `stage4_integrity.py`.
- `probe_results.tsv` keeps the established columns: `probe_id`, `rc`, `pass`, `log_path`.
- Sidecar pass values are parser-owned: each was derived from saved logs via `stage4_integrity.py::detect_from_log`.

## Probe Outcome Comparison

- Reference non-green rows: `{'verify_email_clickthrough': {'rc': '1', 'pass': '0'}, 'password_reset_clickthrough': {'rc': '1', 'pass': '0'}}`.
- Current non-green classifications: `{'verify_email_clickthrough': 'verify_email_not_marked_verified', 'password_reset_clickthrough': 'password_reset_token_not_cleared'}`.
- Current parser-passing rows: `['dunning_email_inbox', 'ses_bounce', 'ses_complaint', 'staging_dunning_delivery']`.
- New classification shapes in this bundle: `[]`.

## Disposition

- The current bundle is not all-green because `verify_email_clickthrough` and `password_reset_clickthrough` are non-green.
- The old 2026-06-05 bundle is used only as a shape and reference comparison input here; current launch-tracking prose should source final status from `docs/runbooks/evidence/ses-coverage-a1/20260609T174733Z_in_vpc_rerun`.
