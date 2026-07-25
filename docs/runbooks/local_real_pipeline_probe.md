# Local Real-Pipeline Probe

## Purpose

Use this runbook to prove that one manually driven local metering and
aggregation run produces the exact `usage_daily` row for that run.
`scripts/local_real_pipeline_probe.sh` is the behavior owner; this runbook
defines the operational proof boundary without copying its classifier branches
or orchestration.

Run every command from the repository root. The probe prepares the local
environment, starts the local stack it needs, and tears down the processes it
started.

## Positive Proof

```bash
bash scripts/local_real_pipeline_probe.sh
```

PASS requires exit code 0 and
`LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified`. The output must also show
concrete `PRE`, `POST`, and `delta=POST-PRE` counters plus
`rows_affected` greater than or equal to 1. This means the freshly produced
`usage_daily` value exactly matches the Flapjack `/metrics` POST-minus-PRE
counters across the two-scrape bracket.

## Negative Proofs

The seeded-row proof must exit nonzero and classify the deliberately uncleared
seed:

```bash
(
  output_file="$(mktemp "${TMPDIR:-/tmp}/local_real_pipeline_negative_seeded.XXXXXX")"
  trap 'test ! -e "$output_file" || unlink "$output_file"' EXIT
  set +e
  bash scripts/local_real_pipeline_probe.sh --negative-seeded >"$output_file" 2>&1
  probe_rc=$?
  set -e
  cat "$output_file"
  test "$probe_rc" -ne 0
  grep -Fx 'LOCAL_REAL_PIPELINE_STATUS: FAIL reason=not_cleared' "$output_file"
)
```

The no-traffic proof must exit nonzero and classify the deliberately absent
row:

```bash
(
  output_file="$(mktemp "${TMPDIR:-/tmp}/local_real_pipeline_negative_nodrive.XXXXXX")"
  trap 'test ! -e "$output_file" || unlink "$output_file"' EXIT
  set +e
  bash scripts/local_real_pipeline_probe.sh --negative-nodrive >"$output_file" 2>&1
  probe_rc=$?
  set -e
  cat "$output_file"
  test "$probe_rc" -ne 0
  grep -Fx 'LOCAL_REAL_PIPELINE_STATUS: FAIL reason=absent' "$output_file"
)
```

Neither negative verdict is an operational failure: each command proves the
classifier rejects its named defect specimen. A zero exit from either probe, a
different reason, or a missing status line fails the proof.

## Proof Boundary

Parked: the production systemd timer firing on a real host is out of scope for this local harness — this proves the job PRODUCES correctly when driven manually.

This procedure does not exercise AWS, CloudWatch, staging, EC2, Stripe, or the
web frontend. It proves local production behavior only through the probe owner
above.
