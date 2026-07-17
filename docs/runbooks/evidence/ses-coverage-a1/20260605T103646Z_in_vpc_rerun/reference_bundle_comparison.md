# Reference Bundle Comparison

Current bundle: `docs/runbooks/evidence/ses-coverage-a1/20260605T103646Z_in_vpc_rerun`
Reference bundle: `docs/runbooks/evidence/ses-coverage-a1/20260604T114841Z_in_vpc_rerun`

## Artifact Shape

- Current bundle reuses the copied `stage4_integrity.py` parser from `20260603T033009Z_in_vpc_rerun`.
- Required parser files are present or generated in the current bundle: `probe_results.tsv`, six per-probe logs, six per-probe sidecars, `all_green.txt`, `failure_classifications.json`, `GAP_SPEC.md`, `run_manifest.txt`, `verification_commands.txt`, `reference_bundle_comparison.md`, `SUMMARY.md`, and `stage4_integrity.py`.
- `ec2_instance_discovery.json` is retained as the direct EC2 discovery terminus requested by Stage 2; it is outside `stage4_integrity.py::REQUIRED_FILES`.
- `probe_results.tsv` keeps the established columns: `probe_id`, `rc`, `pass`, `log_path`.
- Sidecar pass values are parser-owned: each was derived from saved logs via `stage4_integrity.py::detect_from_log`.

## Probe Outcome Comparison

- Previous non-green classifications: `{'verify_email_clickthrough': 'verify_email_token_invalid_or_expired', 'password_reset_clickthrough': 'password_reset_token_not_cleared', 'dunning_email_inbox': 'rehearsal_reset_failed', 'staging_dunning_delivery': 'stripe_cli_missing'}`.
- Current non-green classifications: `{'verify_email_clickthrough': 'verify_email_not_marked_verified', 'password_reset_clickthrough': 'password_reset_token_not_cleared'}`.
- Current parser-passing rows: `['dunning_email_inbox', 'ses_bounce', 'ses_complaint', 'staging_dunning_delivery']`.
- New Wave 3 candidate shapes in this bundle: `['verify_email_clickthrough:verify_email_not_marked_verified']`.

## Open Questions

- `verify_email_not_marked_verified` is new relative to the `20260604T114841Z_in_vpc_rerun` pre-authorized partial and needs Wave 3 owner diagnosis if Stage 3 cannot accept it as a residual partial shape.
