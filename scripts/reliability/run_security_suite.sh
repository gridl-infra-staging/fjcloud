#!/usr/bin/env bash
# Stable machine-readable CLI for the consolidated security suite.
#
# stdout: one JSON summary document
# stderr: diagnostics that prevent the suite from producing a summary
# exit 0: every security check passed or skipped non-fatally
# exit 1: one or more security checks failed
# exit 2: the suite could not produce a trustworthy summary

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/reliability/lib/security_checks.sh"

run_security_suite
