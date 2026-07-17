# Reference Bundle Comparison

Current bundle: `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun`
Reference bundle: `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun`

## Artifact Shape

- Current bundle reuses the copied `stage4_integrity.py` parser from `20260605T103646Z_in_vpc_rerun`.
- Required parser files are present or generated in the current bundle: `probe_results.tsv`, six per-probe logs, six per-probe sidecars, `all_green.txt`, `failure_classifications.json`, `GAP_SPEC.md`, `run_manifest.txt`, `verification_commands.txt`, `reference_bundle_comparison.md`, `SUMMARY.md`, and `stage4_integrity.py`.
- `probe_results.tsv` keeps the established columns: `probe_id`, `rc`, `pass`, `log_path`.
- Sidecar pass values are parser-owned: each was derived from saved logs via `stage4_integrity.py::detect_from_log`.

## Probe Outcome Comparison

- Previous non-green classifications: `{'verify_email_clickthrough': 'verify_email_not_marked_verified', 'password_reset_clickthrough': 'password_reset_token_not_cleared'}`.
- Current non-green classifications: `{'verify_email_clickthrough': 'verify_email_not_marked_verified', 'password_reset_clickthrough': 'password_reset_token_not_cleared'}`.
- Current parser-passing rows: `['dunning_email_inbox', 'ses_bounce', 'ses_complaint', 'staging_dunning_delivery']`.
- New classification shapes in this bundle: `[]`.

## Open Questions

- `verify_email_not_marked_verified` remains non-green in the fresh bundle and needs owner diagnosis before Section 1 can become all-green.
