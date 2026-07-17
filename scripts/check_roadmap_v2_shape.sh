#!/usr/bin/env bash
# check_roadmap_v2_shape.sh — assert ROADMAP.md follows the v2 owner contract.
#
# Stage 2 of the doc-system v2 wave reshapes ROADMAP.md from its older
# `## Current Focus` + `## Feature Status` + `## Planned (Next Up)` +
# `## Open / Not Yet Implemented` layout into a `## Active` + `## Planned`
# owner shape, with a tight `## Archive` pointer to the implemented/ directory.
# Several other repo seams (LAUNCH.md, contract tests) quote priority and
# open-work item titles by their exact text, so the reshape must preserve
# those titles verbatim.
#
# This gate is the structural-contract owner. It is independent from
# scripts/check-sizes.sh (which does not currently track ROADMAP.md size)
# and from scripts/check_status_doc_consistency.sh (which owns LAUNCH.md vs.
# LAUNCH.md freshness, not roadmap shape).
#
# Invariants enforced:
#   1. Required top-level headings present: `## Active`, `## Planned`,
#      `## Archive`.
#   2. Retired top-level headings absent: `## Current Focus`,
#      `## Feature Status`, `## Planned (Next Up)`,
#      `## Open / Not Yet Implemented`.
#   3. Each `REQUIRED_LIVE_TITLE` from the captured live-item registry
#      below appears somewhere in ROADMAP.md verbatim.
#   4. ROADMAP.md is <= 200 lines.
#   5. ROADMAP.md points archive readers to implemented/ and does not point at
#      the retired compatibility file.
#
# Exit codes:
#   0 — all invariants pass
#   1 — drift detected (or missing file)
#
# Env vars:
#   FJCLOUD_DOC_ROOT  override the repo root for testing (defaults to the
#                     script's repo root).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_DOC_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ROADMAP_MD="$REPO_ROOT/ROADMAP.md"
REQUIRED_ARCHIVE_OWNER="implemented/"
RETIRED_ARCHIVE_OWNER="roadmap/""implemented.md"

if [ ! -f "$ROADMAP_MD" ]; then
    echo "FAIL: ROADMAP.md not found at $ROADMAP_MD" >&2
    exit 1
fi

# ============================================================
# Captured live-item registry. These titles were extracted from the
# pre-reshape ROADMAP.md `## Planned (Next Up)` priority rows and the
# `## Open / Not Yet Implemented` bullets on 2026-06-05 (Stage 2 of
# `jun04_pm_8_doc_system_v2_wave4_fjcloud_dev`). They must survive the
# reshape verbatim; downstream lanes quote them.
# ============================================================
REQUIRED_LIVE_TITLES=(
    # ## Planned priority rows
    # Restated 2026-07-08 (jul06/jul07 release + dev-velocity batch reconciliation):
    #   - "Current-main redeploy and relaunch proof rerun" -> "Public-release completion (active orchestration)"
    #   - "Fresh current-main RC rerun and rollout proof" -> folded into the same public-release completion row
    #   - "Execute staging billing rehearsal / paid-beta RC" -> "Execute staging billing rehearsal rerun"
    "Public-release completion (active orchestration)"
    "Execute staging billing rehearsal rerun"
    "Web-plane deploy automation"
    "AWS live-infra E2E remaining guardrails"
    "Live RDS restore proof (2026-04-23 captured)"
    # Narrowed 2026-07-08: panic coverage shipped (jul07_3pm_11); only the alarm follow-up remains.
    #   - "Extended crash coverage beyond route and browser seams" -> "\`panics_total\` monitoring alarm wiring"
    "\`panics_total\` monitoring alarm wiring"
    # Narrowed 2026-07-08: account-data side complete (infra/retention-job shipped by jul07_3pm_10).
    #   - "SES deliverability and account-data completion" -> "SES deliverability proof"
    "SES deliverability proof"
    "Reintroduce Linux-Playwright Firefox/WebKit"
    # ## Open / Not Yet Implemented bullet titles
    # Closed 2026-07-07 by jul07_3pm_8_editor_dialog_dictionaries_split:
    #   - "EditorDialog size debt remains open." -> split shipped, overrides removed; residual below
    "DictionariesTab size override remains."
    # Closed 2026-06-11 by jun11_am_2_pricing_disclaimer_and_oauth_alert_wiring:
    #   - "Pricing legal disclaimer follow-up remains open." -> verified row in ROADMAP.md
    #   - "Prod-env OAuth staging-app follow-ups remain open." -> verified row in ROADMAP.md
    "SES bounce/complaint live probe rerun remains open."
    "Account-retention automation implemented."
    # Closed 2026-06-12 by jun11_pm_7_aws_live_infra_e2e (Stage 4):
    #   - "AWS live-infra E2E destructive-proof gap remains open." -> evidence passed
    #   - "Runtime-smoke wrapper needs fresh current-main artifact." -> collapsed into wrapper evidence
    "AWS live-infra E2E current-main wrapper evidence passed."
    # Closed 2026-07-07 by jul07_3pm_11_panic_coverage:
    #   - "Panic/crash coverage beyond route/browser seams remains open." -> panics_total P2 row above
    "Staging billing rehearsal current-main rerun remains open."
    "Playwright CI local Stripe-mode regression remains open."
    # Closed 2026-07-08 by jul07_3pm_13_admin_customers_polish_and_stale_docs:
    #   - "Admin customers MAINT ergonomics cluster remains open." -> reachable states landed
    # Narrowed 2026-07-08 (Metrics slice shipped; see jul07_3pm_13 stale-doc refresh):
    "June 3 customer-release rerun follow-ups remain open (narrowed)."
    "\`e2e-deployed\` deploy-currency gate remains open."
)

REQUIRED_HEADINGS=(
    "## Active"
    "## Planned"
    "## Archive"
)

RETIRED_HEADINGS=(
    "## Current Focus"
    "## Feature Status"
    "## Planned (Next Up)"
    "## Open / Not Yet Implemented"
)

fail_count=0

# ------------------------------------------------------------
# 1. Required headings present.
# ------------------------------------------------------------
for heading in "${REQUIRED_HEADINGS[@]}"; do
    if ! grep -Fxq "$heading" "$ROADMAP_MD"; then
        echo "FAIL: ROADMAP.md is missing required heading '$heading'" >&2
        fail_count=$((fail_count + 1))
    fi
done

# ------------------------------------------------------------
# 2. Retired headings absent.
# ------------------------------------------------------------
for heading in "${RETIRED_HEADINGS[@]}"; do
    if grep -Fxq "$heading" "$ROADMAP_MD"; then
        echo "FAIL: ROADMAP.md still contains retired heading '$heading'" >&2
        fail_count=$((fail_count + 1))
    fi
done

# ------------------------------------------------------------
# 3. Each captured live title appears verbatim.
# ------------------------------------------------------------
for title in "${REQUIRED_LIVE_TITLES[@]}"; do
    if ! grep -Fq "$title" "$ROADMAP_MD"; then
        echo "FAIL: ROADMAP.md is missing required live item title: $title" >&2
        fail_count=$((fail_count + 1))
    fi
done

# ------------------------------------------------------------
# 4. Line-count budget.
# ------------------------------------------------------------
actual_lines="$(wc -l < "$ROADMAP_MD" | tr -d ' ')"
if [ "$actual_lines" -gt 200 ]; then
    echo "FAIL: ROADMAP.md has $actual_lines lines; expected <= 200" >&2
    fail_count=$((fail_count + 1))
fi

# ------------------------------------------------------------
# 5. Archive pointer owner.
# ------------------------------------------------------------
if ! grep -Fq "$REQUIRED_ARCHIVE_OWNER" "$ROADMAP_MD"; then
    echo "FAIL: ROADMAP.md archive pointer must reference $REQUIRED_ARCHIVE_OWNER" >&2
    fail_count=$((fail_count + 1))
fi

if grep -Fq "$RETIRED_ARCHIVE_OWNER" "$ROADMAP_MD"; then
    echo "FAIL: ROADMAP.md still points at retired archive owner; use $REQUIRED_ARCHIVE_OWNER" >&2
    fail_count=$((fail_count + 1))
fi

if [ "$fail_count" -gt 0 ]; then
    echo "" >&2
    echo "ROADMAP.md failed $fail_count v2 shape invariant(s)." >&2
    exit 1
fi

echo "OK: ROADMAP.md satisfies v2 shape contract (${actual_lines} lines)"
exit 0
