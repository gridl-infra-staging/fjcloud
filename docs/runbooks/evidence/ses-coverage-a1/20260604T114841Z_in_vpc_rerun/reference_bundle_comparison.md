# Reference Bundle Comparison

Current bundle: `docs/runbooks/evidence/ses-coverage-a1/20260604T114841Z_in_vpc_rerun`
Reference bundle: `docs/runbooks/evidence/ses-coverage-a1/20260603T033009Z_in_vpc_rerun`

## Artifact Shape

- Current file count: 34.
- Reference file count: 33.
- Added files relative to reference: `COMMAND_PROVENANCE.md`, `ec2_instance_discovery.json`.
- Removed files relative to reference: `DIRMAP.md`.
- Required parser files are present in the current bundle: `probe_results.tsv`, six per-probe logs, six per-probe sidecars, `all_green.txt`, `failure_classifications.json`, `GAP_SPEC.md`, `run_manifest.txt`, `verification_commands.txt`, `reference_bundle_comparison.md`, `SUMMARY.md`, and `stage4_integrity.py`.
- `probe_results.tsv` keeps the same columns as the reference: `probe_id`, `rc`, `pass`, `log_path`.
- Per-probe sidecars keep the same top-level fields as the reference: `probe_id`, `detect_kind`, `rc`, `pass`, `log_path`, and `parsed_evidence`.
- `COMMAND_PROVENANCE.md` is an extra research deliverable for the checklist's command-provenance item. It documents why the tenant allowlist is read from the local secret source at reproduction time instead of being committed as a literal.
- `ec2_instance_discovery.json` is an extra direct AWS discovery terminus for the checklist's EC2 lookup. It is intentionally outside `stage4_integrity.py::REQUIRED_FILES`.
- `DIRMAP.md` is absent from the current bundle. It is directory-summary scaffolding, not an integrity input.

## Probe Outcome Comparison

- `verify_email_clickthrough`: current rc=1 pass=0 classification=`verify_email_token_invalid_or_expired`; reference classification=`repo_owned_prerequisite`.
- `password_reset_clickthrough`: current rc=1 pass=0 classification=`password_reset_token_not_cleared`; reference classification=`repo_owned_prerequisite`.
- `dunning_email_inbox`: current rc=1 pass=0 classification=`rehearsal_reset_failed`; reference classification=`repo_owned_prerequisite`.
- `ses_bounce`: current rc=0 pass=1; reference rc=1 pass=0 classification=`repo_owned_prerequisite`.
- `ses_complaint`: current rc=0 pass=1; reference rc=1 pass=0 classification=`repo_owned_prerequisite`.
- `staging_dunning_delivery`: current rc=1 pass=0 classification=`stripe_cli_missing`; reference classification=`repo_owned_prerequisite`.

## Schema Differences

- No TSV schema differences were introduced.
- No per-probe sidecar schema differences were introduced.
- The current bundle has one added infrastructure terminus (`ec2_instance_discovery.json`), one added command-provenance note (`COMMAND_PROVENANCE.md`), and one removed generated directory-summary file (`DIRMAP.md`); none changes the parser contract.

## Open Questions

- `verify_email_token_invalid_or_expired` is a new observed failure shape relative to the reference bundle and still needs a code-owner diagnosis before Section 1 is flipped live.
- `stripe_cli_missing` was a new observed failure shape in this run. The saved log remains authoritative for this bundle; a later code fix can only be proven by a fresh dunning reset/probe run.
