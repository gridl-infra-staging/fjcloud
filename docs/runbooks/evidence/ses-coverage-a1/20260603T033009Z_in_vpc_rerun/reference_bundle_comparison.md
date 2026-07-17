# Reference Bundle Comparison

Fresh bundle: `docs/runbooks/evidence/ses-coverage-a1/20260603T033009Z_in_vpc_rerun/`

## Sources Compared

- `docs/runbooks/evidence/ses-coverage-a1/20260529T194224Z_in_vpc_rerun/`
- `docs/runbooks/evidence/ses-coverage-a1/20260528T025334Z_in_vpc_rerun/`

## Artifact Shape Findings

- May 29 preserves local logs for all six `probe_results.tsv` rows:
  `verify_email_clickthrough.log`, `password_reset_clickthrough.log`,
  `dunning_email_inbox.log`, `ses_bounce.log`, `ses_complaint.log`, and
  `staging_dunning_delivery.log`.
- May 29 uses per-probe `*.classification.txt` files rather than structured
  sidecar JSON. The fresh June 3 bundle keeps the same six-row TSV shape but
  replaces classification text files with parseable `*.json` sidecars.
- May 28 has the same six-row `probe_results.tsv` schema, but its TSV log paths
  reference files that are not present in the local bundle directory. Local
  artifact existence checks are therefore mandatory before trusting any TSV row.
- May 28 includes `failure_classifications.json` but does not include local
  per-probe logs or sidecars. Its result rows are useful for schema comparison,
  not for saved-log reparse evidence.

## Fresh Bundle Contract Derived From Current Source

- `probe_results.tsv` keeps the established six-row schema:
  `probe_id`, `rc`, `pass`, `log_path`.
- The fresh bundle requires every referenced log path to exist and be non-empty.
- The fresh bundle requires every sidecar JSON to parse and agree with its
  referenced saved log.
- The fresh bundle preserves `GAP_SPEC.md` and
  `failure_classifications.json` because `all_green.txt` is `0`.

## Open Questions

None for artifact shape. The non-green probe causes are listed separately in
`GAP_SPEC.md`.
