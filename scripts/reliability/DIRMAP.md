<!-- [scrai:start] -->
## reliability

| File | Summary |
| --- | --- |
| capture-all.sh | capture-all.sh — Run profiling for all three tiers and produce summary.json.
Usage: RELIABILITY=1 ./capture-all.sh

Prerequisites: integration stack running (scripts/integration-up.sh). |
| run-profile.sh | run-profile.sh — Run a capacity profiling session for a single document tier.
Usage: run-profile.sh <tier>
  tier: 1k | 10k | 100k

Prerequisites: integration stack running (scripts/integration-up.sh)
Set RELIABILITY=1 to enable; otherwise exits gracefully. |
| run_backend_reliability_gate.sh | Aggregate backend reliability gate.

Runs Stage 1-4 reliability/security checks plus the existing
`live-backend-gate.sh` checks as a single machine-readable JSON summary. |
| security_checks.sh | Security automation gate — orchestrates all security checks and produces
a machine-readable JSON summary.

Usage:
  scripts/reliability/security_checks.sh [--check <name>]

Options:
  --check cargo_audit       Run only cargo audit check
  --check secret_scan       Run only secret scan check
  --check unsafe_code       Run only unsafe code patterns check
  (no flags)                Run all three checks

Output:
  stdout: JSON summary with per-check pass/fail, reason codes, and timing
  stderr: Per-check progress

Exit codes:
  0 — all checks passed (cargo_audit skip is still treated as non-pass)
  1 — one or more checks failed or skipped. |
| seed-documents.sh | seed-documents.sh — Deterministically insert N documents into a test index.
Usage: seed-documents.sh <tier> [api_base]
  tier: 1k | 10k | 100k
  api_base: defaults to http://localhost:3099. |
| seed-profiles.sh | Seed deterministic capacity profile artifacts for CI and local development.

Writes 12 per-metric JSON files (3 tiers × 4 metrics) and a summary.json
to scripts/reliability/profiles/. |
| seed-test-profiles.sh | Generates minimal valid profile JSON files for CI/dev use.

Produces all 12 per-metric artifacts ({tier}_{metric}.json for 3 tiers x 4 metrics)
AND summary.json under scripts/reliability/profiles/.

Uses the current PROFILE_*K constant values from infra/api/tests/common/capacity_profiles.rs
as the "measured" values so Rust drift tests pass without a live flapjack stack.

For real profiling data, run:
  RELIABILITY=1 scripts/reliability/capture-all.sh

Usage:
  scripts/reliability/seed-test-profiles.sh. |

| Directory | Summary |
| --- | --- |
| fixtures | — |
| lib | This library directory contains utilities for backend reliability profiling and validation, including shared metric capture functions, capacity profile parsing, and security checks for the reliability gate. |
<!-- [scrai:end] -->
