#!/usr/bin/env bash
# Hermetic known-answer tests for scripts/probe_screen_spec_claim_freshness.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/assertions.sh"

PROBE="$REPO_ROOT/scripts/probe_screen_spec_claim_freshness.sh"
TMP_PATHS=()

cleanup() {
    if [ "${#TMP_PATHS[@]}" -gt 0 ]; then
        rm -rf "${TMP_PATHS[@]}"
    fi
}
trap cleanup EXIT

register_tmp_path() {
    TMP_PATHS+=("$1")
}

write_file() {
    local repo_root="$1" rel_path="$2" body="$3"
    mkdir -p "$(dirname "$repo_root/$rel_path")"
    printf '%s\n' "$body" > "$repo_root/$rel_path"
}

seed_fixture_repo() {
    local repo_root="$1"
    mkdir -p "$repo_root/docs/screen_specs" \
        "$repo_root/docs/runbooks/evidence/database-recovery/20260525T231835Z_a4_coverage" \
        "$repo_root/docs/valid" \
        "$repo_root/web/src/routes/admin/customers/[id]" \
        "$repo_root/web/src/routes/console/indexes/[name]/tabs" \
        "$repo_root/web/src/routes/console/indexes/[name]" \
        "$repo_root/web/src/lib/api" \
        "$repo_root/web/tests/e2e-ui/full" \
        "$repo_root/infra/api/src/routes/indexes"

    write_file "$repo_root" "docs/screen_specs/analytics_subtabs.md" '
# Analytics
- Current: no Devices / Geography / Filters / Conversions data path through fjcloud.
  Evidence: `web/src/lib/api/client.ts` (no matches for `getAnalyticsDevices|getAnalyticsCountries|getAnalyticsFilters|getAnalyticsConversionRate` in analytics methods); `infra/api/src/routes/indexes/analytics.rs:77`.
- Current: 0 of upstream analytics e2e tests covered.
  Evidence: `web/tests/e2e-ui/full/` (no analytics.spec.ts file).
'
    write_file "$repo_root" "docs/screen_specs/events.md" '
# Events
- **Refresh-only model:** `web/src/routes/console/indexes/[name]/tabs/EventsTab.svelte:82` is a form with no `setInterval`. No auto-poll.
'
    write_file "$repo_root" "docs/screen_specs/overview.md" '
# Overview
- Current: no analytics summary section.
  Evidence: `web/src/routes/console/indexes/[name]/tabs/OverviewTab.svelte` (no matches for `analytics summary|KPI|sparkline`).
'
    write_file "$repo_root" "docs/screen_specs/synonyms.md" '
# Synonyms
- Current: no Clear All button.
  Evidence: no matches for `Clear All` / `clearSynonyms` in `SynonymsTab.svelte` or `+page.server.ts`.
- Current: no count badge.
  Evidence: no matches for `nbHits` or `synonym-count` in `SynonymsTab.svelte`.
'
    write_file "$repo_root" "docs/screen_specs/suggestions.md" '
# Suggestions
- Current: no build-log display.
  Evidence: `SuggestionsTab.svelte` (no matches for `log|stdout|stderr`).
'
    write_file "$repo_root" "docs/screen_specs/experiments.md" '
# Experiments
- Current: interleaving card, mean-click-rank card, and CUPED badge are absent.
  Evidence: `ExperimentsTab.svelte` (no matches for `interleaving`, `meanClickRank`, `cupedApplied`).
'
    write_file "$repo_root" "docs/screen_specs/presence.md" '
# Presence
- Current: direct editor textarea exists. Evidence: `web/src/routes/console/indexes/[name]/tabs/EditorTab.svelte:1-3` (`textarea`).
- Current: qualitative upstream parity note.
  Evidence: upstream audit narrative only.
'

    write_file "$repo_root" "web/src/lib/api/client.ts" '
getanalyticsdevices()
getAnalyticsCountries()
getAnalyticsFilters()
getAnalyticsConversionRate()
clearSynonyms()
'
    write_file "$repo_root" "web/tests/e2e-ui/full/analytics_subtabs.spec.ts" "test"
    write_file "$repo_root" "infra/api/src/routes/indexes/analytics.rs" "proxy_analytics_endpoint"
    write_file "$repo_root" "web/src/routes/console/indexes/[name]/tabs/EventsTab.svelte" "setInterval(() => refresh(), 5000)"
    write_file "$repo_root" "web/src/routes/console/indexes/[name]/tabs/OverviewTab.svelte" "analytics summary KPI sparkline"
    write_file "$repo_root" "web/src/routes/console/indexes/[name]/tabs/SynonymsTab.svelte" "Clear All"
    write_file "$repo_root" "web/src/routes/console/indexes/[name]/+page.server.ts" "clearSynonyms"
    write_file "$repo_root" "web/src/routes/console/indexes/[name]/tabs/SuggestionsTab.svelte" "no build output here"
    write_file "$repo_root" "web/src/routes/console/indexes/[name]/tabs/ExperimentsTab.svelte" "ordinary experiment table"
    write_file "$repo_root" "web/src/routes/console/indexes/[name]/tabs/EditorTab.svelte" "textarea"

    write_file "$repo_root" "docs/links.md" '
[valid file](valid/file.md)
[valid dir](valid/)
[fragment](valid/file.md#section-one)
[titled valid](valid/file.md "Local title")
[parenthesized title](valid/file.md (Local title))
[external](https://example.com/path)
[anchor](#local)
[commit note](commit abc123)
[percent decoded](valid/space%20name.md)
[encoded route](../web/src/routes/admin/customers/%5Bid%5D/+page.svelte)
[ordinary missing](missing/target.md)
[encoded missing](missing%20target.md)
[titled missing](missing/titled.md "Missing title")
[single-quoted title](missing/single.md '"'"'Missing title'"'"')
[drill static](runbooks/evidence/database-recovery/20260525T231835Z_a4_coverage/drill_static.log)
[drill unit](runbooks/evidence/database-recovery/20260525T231835Z_a4_coverage/drill_unit.log)
[evidence static](runbooks/evidence/database-recovery/20260525T231835Z_a4_coverage/evidence_static.log)
[evidence unit](runbooks/evidence/database-recovery/20260525T231835Z_a4_coverage/evidence_unit.log)
'
    write_file "$repo_root" "docs/valid/file.md" "# valid"
    write_file "$repo_root" "docs/valid/space name.md" "# valid"
    write_file "$repo_root" "web/src/routes/admin/customers/[id]/+page.svelte" "<h1>Customer</h1>"
    write_file "$repo_root" "LAUNCH.md" "# launch"
    write_file "$repo_root" "ROADMAP.md" "# roadmap"
    write_file "$repo_root" "PROJECT_OVERVIEW.md" "# overview"
    write_file "$repo_root" "README.md" "# readme"
}

run_probe() {
    local repo_root="$1"
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(bash "$PROBE" --repo-root "$repo_root" 2>&1)" || RUN_EXIT_CODE=$?
}

test_known_claim_controls_and_link_classes() {
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    seed_fixture_repo "$tmpdir"

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "shadow probe should exit zero with warnings"
    assert_contains "$RUN_OUTPUT" "docs/screen_specs/analytics_subtabs.md:4 class=recheckable-absence result=contradicted" "analytics client methods contradiction should be named"
    assert_contains "$RUN_OUTPUT" "target=web/src/lib/api/client.ts tokens=getAnalyticsDevices reason=unexpected token present" "claim matching should preserve the case-insensitive control contract"
    assert_contains "$RUN_OUTPUT" "docs/screen_specs/analytics_subtabs.md:6 class=recheckable-absence result=contradicted" "analytics e2e files contradiction should be named"
    assert_contains "$RUN_OUTPUT" "docs/screen_specs/events.md:3 class=recheckable-absence result=contradicted" "events auto-poll direct citation should be named"
    assert_contains "$RUN_OUTPUT" "docs/screen_specs/overview.md:4 class=recheckable-absence result=contradicted" "overview analytics tokens contradiction should be named"
    assert_contains "$RUN_OUTPUT" "docs/screen_specs/synonyms.md:4 class=recheckable-absence result=contradicted" "synonyms Clear All contradiction should be named"
    assert_contains "$RUN_OUTPUT" "docs/screen_specs/synonyms.md:4 class=recheckable-absence result=contradicted target=+page.server.ts tokens=clearSynonyms" "synonyms server-action token should be evaluated"
    assert_contains "$RUN_OUTPUT" "docs/screen_specs/suggestions.md:4 class=recheckable-absence result=holds" "suggestions log/stdout/stderr control should hold"
    assert_contains "$RUN_OUTPUT" "target=SuggestionsTab.svelte tokens=log reason=absence predicate still holds" "suggestions log predicate should be counted"
    assert_contains "$RUN_OUTPUT" "target=SuggestionsTab.svelte tokens=stdout reason=absence predicate still holds" "suggestions stdout predicate should be counted"
    assert_contains "$RUN_OUTPUT" "target=SuggestionsTab.svelte tokens=stderr reason=absence predicate still holds" "suggestions stderr predicate should be counted"
    assert_contains "$RUN_OUTPUT" "docs/screen_specs/experiments.md:4 class=recheckable-absence result=holds" "experiments interleaving controls should hold"
    assert_contains "$RUN_OUTPUT" "target=ExperimentsTab.svelte tokens=interleaving reason=absence predicate still holds" "experiments interleaving predicate should be counted"
    assert_contains "$RUN_OUTPUT" "target=ExperimentsTab.svelte tokens=meanClickRank reason=absence predicate still holds" "experiments mean-click-rank predicate should be counted"
    assert_contains "$RUN_OUTPUT" "target=ExperimentsTab.svelte tokens=cupedApplied reason=absence predicate still holds" "experiments CUPED predicate should be counted"
    assert_contains "$RUN_OUTPUT" "CLAIM: docs/screen_specs/presence.md:3 class=recheckable-presence result=holds target=web/src/routes/console/indexes/[name]/tabs/EditorTab.svelte:1-3 tokens=textarea" "inline Evidence token should be verified"
    assert_contains "$RUN_OUTPUT" "WARN: docs/screen_specs/presence.md:5 class=prose result=unparsed" "prose Evidence field should remain visible in shadow mode"
    assert_contains "$RUN_OUTPUT" "LINK: docs/links.md:2 class=clean raw_target=valid/file.md resolved_target=docs/valid/file.md" "valid relative file should be classified clean"
    assert_contains "$RUN_OUTPUT" "LINK: docs/links.md:3 class=clean raw_target=valid/ resolved_target=docs/valid" "valid relative directory should be classified clean"
    assert_contains "$RUN_OUTPUT" "LINK: docs/links.md:4 class=clean raw_target=valid/file.md#section-one resolved_target=docs/valid/file.md" "fragment-bearing local link should be classified clean"
    assert_contains "$RUN_OUTPUT" "LINK: docs/links.md:5 class=clean raw_target=valid/file.md \"Local title\" resolved_target=docs/valid/file.md" "titled local link should be classified clean"
    assert_contains "$RUN_OUTPUT" "LINK: docs/links.md:6 class=clean raw_target=valid/file.md (Local title) resolved_target=docs/valid/file.md" "parenthesized local-link title should remain in the denominator"
    assert_contains "$RUN_OUTPUT" "LINK: docs/links.md:10 class=clean raw_target=valid/space%20name.md resolved_target=docs/valid/space name.md" "percent-decoded space should be classified clean"
    assert_contains "$RUN_OUTPUT" "LINK: docs/links.md:11 class=clean raw_target=../web/src/routes/admin/customers/%5Bid%5D/+page.svelte resolved_target=web/src/routes/admin/customers/[id]/+page.svelte" "percent-decoded SvelteKit route should be classified clean"
    assert_not_contains "$RUN_OUTPUT" "raw_target=https://example.com/path" "external URLs should remain outside local-link scope"
    assert_not_contains "$RUN_OUTPUT" "raw_target=#local" "document anchors should remain outside local-link scope"
    assert_contains "$RUN_OUTPUT" "WARN: docs/links.md:12 class=moved_pointer raw_target=missing/target.md resolved_target=docs/missing/target.md" "ordinary dead link should include source, class, raw target, and resolved target"
    assert_contains "$RUN_OUTPUT" "WARN: docs/links.md:13 class=moved_pointer raw_target=missing%20target.md resolved_target=docs/missing target.md" "encoded-space dead link should be resolved and classified"
    assert_contains "$RUN_OUTPUT" "WARN: docs/links.md:14 class=moved_pointer raw_target=missing/titled.md \"Missing title\" resolved_target=docs/missing/titled.md" "double-quoted dead-link title should remain in the denominator"
    assert_contains "$RUN_OUTPUT" "WARN: docs/links.md:15 class=moved_pointer raw_target=missing/single.md 'Missing title' resolved_target=docs/missing/single.md" "single-quoted dead-link title should remain in the denominator"
    assert_contains "$RUN_OUTPUT" "class=missing_evidence raw_target=runbooks/evidence/database-recovery/20260525T231835Z_a4_coverage/drill_static.log" "database drill_static missing evidence should be distinct"
    assert_contains "$RUN_OUTPUT" "class=missing_evidence raw_target=runbooks/evidence/database-recovery/20260525T231835Z_a4_coverage/drill_unit.log" "database drill_unit missing evidence should be distinct"
    assert_contains "$RUN_OUTPUT" "class=missing_evidence raw_target=runbooks/evidence/database-recovery/20260525T231835Z_a4_coverage/evidence_static.log" "database evidence_static missing evidence should be distinct"
    assert_contains "$RUN_OUTPUT" "class=missing_evidence raw_target=runbooks/evidence/database-recovery/20260525T231835Z_a4_coverage/evidence_unit.log" "database evidence_unit missing evidence should be distinct"
    assert_contains "$RUN_OUTPUT" "claim_evidence_lines=9" "fixture evidence-line denominator should be exact"
    assert_contains "$RUN_OUTPUT" "claim_recheckable_lines=9" "fixture recheckable-line denominator should include legacy event control"
    assert_contains "$RUN_OUTPUT" "claim_atomic_predicates=26" "fixture atomic-predicate denominator should count each target-token pair"
    assert_contains "$RUN_OUTPUT" "claim_holds=15" "fixture holding-predicate count should be exact"
    assert_contains "$RUN_OUTPUT" "claim_contradictions=11" "fixture contradiction count should include every present token"
    assert_contains "$RUN_OUTPUT" "claim_unparsed_lines=1" "fixture prose scope should remain observable"
    assert_contains "$RUN_OUTPUT" "claim_dead_claim_paths=0" "fixture dead-claim-path count should be exact"
    assert_contains "$RUN_OUTPUT" "links_total=15" "local-link denominator should be exact"
    assert_contains "$RUN_OUTPUT" "links_clean=7" "clean local-link count should be exact"
    assert_contains "$RUN_OUTPUT" "links_dead=8" "dead local-link count should be exact"
    assert_contains "$RUN_OUTPUT" "ordinary_dead_links=4" "ordinary dead-link count should be exact"
    assert_contains "$RUN_OUTPUT" "missing_evidence_links=4" "missing-evidence count should be exact"
    # The claim corpus and the link corpus are DIFFERENT sets, and the summary
    # used to name only one of them (`markdown_roots=`) directly above the claim
    # counters. A reader reasonably concluded ROADMAP.md claims were checked;
    # they were not. Both denominators are now named, separately and exactly.
    assert_contains "$RUN_OUTPUT" "claim_roots=docs/screen_specs/*.md,LAUNCH.md,ROADMAP.md,PROJECT_OVERVIEW.md,README.md" "claim denominator should name its own corpus roots"
    assert_contains "$RUN_OUTPUT" "link_roots=docs/**/*.md,LAUNCH.md,ROADMAP.md,PROJECT_OVERVIEW.md,README.md" "link denominator should name its own corpus roots"
    assert_not_contains "$RUN_OUTPUT" "markdown_roots=" "the ambiguous single-corpus label must not survive"
    # Negative control for the cross-repo classifier (handoff arm 4): every claim
    # in this fixture is about a surface the repo owns, so none may be reclassified
    # as cross-repo just because it carries no re-derive command.
    assert_contains "$RUN_OUTPUT" "claim_cross_repo_unverifiable_here=0" "own-surface fixture should record no unverifiable-here claims"
    assert_contains "$RUN_OUTPUT" "claim_cross_repo_unproven=0" "own-surface fixture should record no unproven cross-repo claims"
    assert_not_contains "$RUN_OUTPUT" "class=cross-repo" "own-surface claims must never be classified cross-repo"
}

test_presence_claim_content_is_verified() {
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    seed_fixture_repo "$tmpdir"
    write_file "$tmpdir" "web/src/routes/console/indexes/[name]/tabs/EditorTab.svelte" "ordinary editor"

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "content contradiction should remain a shadow-mode warning"
    assert_contains "$RUN_OUTPUT" "docs/screen_specs/presence.md:3 class=recheckable-presence result=contradicted target=web/src/routes/console/indexes/[name]/tabs/EditorTab.svelte:1-3 tokens=textarea reason=expected token absent" "missing presence token should be contradicted"
}

test_missing_claim_path_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    seed_fixture_repo "$tmpdir"
    rm "$tmpdir/web/src/routes/console/indexes/[name]/tabs/OverviewTab.svelte"

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "2" "missing screen-spec claim path should fail closed"
    assert_contains "$RUN_OUTPUT" "dead_claim_path" "missing claim path should be diagnosed"
    assert_contains "$RUN_OUTPUT" "OverviewTab.svelte" "missing claim path should name exact owner"
}

test_claim_target_escape_fails_closed_without_reading_outside_repo() {
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    seed_fixture_repo "$tmpdir/repo"
    write_file "$tmpdir" "outside_secret.txt" "leakedtoken"
    write_file "$tmpdir/repo" "docs/screen_specs/path_escape.md" '
# Path Escape
- Current: no leaked token.
  Evidence: `docs/../../outside_secret.txt` (no matches for `leakedtoken`).
'

    run_probe "$tmpdir/repo"

    assert_eq "$RUN_EXIT_CODE" "2" "claim targets escaping the repo root should fail closed"
    assert_contains "$RUN_OUTPUT" "docs/screen_specs/path_escape.md:4 class=dead-path result=dead_claim_path target=docs/../../outside_secret.txt tokens=- reason=target escapes repo root" "escaping claim target should be diagnosed without resolving outside"
    assert_not_contains "$RUN_OUTPUT" "tokens=leakedtoken reason=unexpected token present" "escaping target must not be read as a content oracle"
}

test_empty_claim_corpus_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    mkdir -p "$tmpdir/docs/screen_specs"

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "2" "empty screen-spec corpus should fail closed"
    assert_contains "$RUN_OUTPUT" "claim corpus is empty" "empty corpus failure should explain the cause"
}

test_zero_recheckable_claims_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    mkdir -p "$tmpdir/docs/screen_specs"
    write_file "$tmpdir" "docs/screen_specs/prose.md" '
# Prose
- Current: audit-only.
  Evidence: parent audit observation only.
'

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "2" "zero recheckable claims should fail closed"
    assert_contains "$RUN_OUTPUT" "zero parsed recheckable claims" "zero recheckable failure should explain the cause"
}

test_zero_evidence_lines_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    mkdir -p "$tmpdir/docs/screen_specs"
    write_file "$tmpdir" "docs/screen_specs/claims.md" "# Claims without evidence"

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "2" "zero evidence lines should fail closed"
    assert_contains "$RUN_OUTPUT" "claim evidence corpus is empty" "zero-evidence failure should explain the cause"
}

test_invalid_root_and_malformed_cli_fail_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"

    run_probe "$tmpdir/missing"
    assert_eq "$RUN_EXIT_CODE" "2" "invalid repo root should fail closed"
    assert_contains "$RUN_OUTPUT" "repo root is not a readable directory" "invalid-root failure should explain the cause"

    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(bash "$PROBE" --unknown "$tmpdir" 2>&1)" || RUN_EXIT_CODE=$?
    assert_eq "$RUN_EXIT_CODE" "2" "malformed CLI should fail closed"
    assert_contains "$RUN_OUTPUT" "usage: probe_screen_spec_claim_freshness.sh" "malformed CLI should print usage"
}

test_probe_parses_under_default_bash() {
    # The probe embeds a python heredoc whose regexes contain backticks. Nesting that
    # heredoc inside $( ) makes bash 3.2 read the backticks as command substitution and
    # abort before the script runs, while bash 5 parses it fine — so a reviewer on a
    # newer bash cannot see the break. Parse with the same `bash` the gate invokes.
    local parse_output parse_exit=0
    parse_output="$(bash -n "$PROBE" 2>&1)" || parse_exit=$?

    assert_eq "$parse_exit" "0" "probe must parse under the default bash on PATH"
    assert_eq "$parse_output" "" "probe parse must emit no syntax diagnostics"
}

test_contradiction_counter_is_fail_capable() {
    local tmpdir mutated_probe original_probe
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    seed_fixture_repo "$tmpdir/fixture"
    mkdir -p "$tmpdir/repo/scripts"
    original_probe="$PROBE"
    mutated_probe="$tmpdir/repo/scripts/probe_screen_spec_claim_freshness.sh"
    cp "$original_probe" "$mutated_probe"
    python3 - "$mutated_probe" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
needle = 'contradictions = [d for d in claim_diagnostics if d.result == "contradicted"]'
replacement = 'contradictions = []'
if needle not in text:
    raise SystemExit("mutation target missing")
path.write_text(text.replace(needle, replacement))
PY
    chmod +x "$mutated_probe"

    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(bash "$mutated_probe" --repo-root "$tmpdir/fixture" 2>&1)" || RUN_EXIT_CODE=$?

    assert_eq "$RUN_EXIT_CODE" "0" "mutated shadow probe still exits zero"
    assert_contains "$RUN_OUTPUT" "claim_contradictions=0" "deliberate mutation should expose incorrect contradiction value"
    assert_ne "$(printf '%s\n' "$RUN_OUTPUT" | awk -F= '/^claim_contradictions=/{print $2}')" "11" "deliberate mutation should fail the expected contradiction count"
}

# ---------------------------------------------------------------------------
# Claim-corpus boundary.
#
# Until 2026-08-01 the CLAIM corpus was docs/screen_specs/*.md alone, while the
# summary advertised `markdown_roots=...,ROADMAP.md,...` — which was the LINK
# corpus, printed one line above the claim counters. The two were measurably
# different: an identical `Evidence:` claim citing a missing path exited 0 in
# ROADMAP.md and exited 2 in docs/screen_specs/. Agents are told ROADMAP.md and
# LAUNCH.md are canonical, so claims recorded there must be checked. These two
# tests pin the corpus in both directions — what is scanned, and what is not.
# ---------------------------------------------------------------------------
test_canonical_status_docs_are_claim_scanned() {
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    seed_fixture_repo "$tmpdir"
    write_file "$tmpdir" "ROADMAP.md" '
# Roadmap
- Current: the preview route is absent.
  Evidence: `infra/api/src/routes/migration/preview.rs` (no matches for `preview_handler`).
'

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "2" "a dead claim path in ROADMAP.md must fail closed exactly like one in a screen spec"
    assert_contains "$RUN_OUTPUT" "WARN: ROADMAP.md:4 class=dead-path result=dead_claim_path target=infra/api/src/routes/migration/preview.rs" "ROADMAP.md claims must be classified, not silently skipped"
}

test_non_claim_root_docs_are_not_claim_scanned() {
    # Negative control for the widening above. docs/ is the LINK corpus; only
    # docs/screen_specs/ plus the four canonical root docs are CLAIM roots. If
    # this arm ever goes red the corpus has silently become "every markdown
    # file", which measured 87.5% false positives on the real tree (dated
    # `<UTC>` placeholder paths in archived checklists) — the noise failure that
    # gets a probe switched off.
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    seed_fixture_repo "$tmpdir"
    write_file "$tmpdir" "docs/notes.md" '
# Notes
- Current: nothing is wired here yet.
  Evidence: `infra/api/src/routes/does_not_exist.rs` (no matches for `handler`).
'

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "a claim outside the claim roots must not fail the probe"
    assert_not_contains "$RUN_OUTPUT" "docs/notes.md:4" "docs/ is the link corpus and must not be claim-scanned"
}

# ---------------------------------------------------------------------------
# Cross-repo claims.
#
# fjcloud's migration feature depends on an engine that lives in flapjack_dev.
# An agent here cannot run flapjack's tests, so claims about it are written down
# and trusted. Before this change such a claim produced NO diagnostic at all:
# its target failed the repo-local prefix test and was dropped, so "I could not
# check this" was indistinguishable from "this is fine". A claim that records a
# re-derive command is reported in its own state and passes — someone in the
# right locality can run it. A claim that records none can never be checked by
# anyone, so it fails closed.
# ---------------------------------------------------------------------------
test_cross_repo_claim_with_command_is_reported_unverifiable_here() {
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    seed_fixture_repo "$tmpdir"
    write_file "$tmpdir" "docs/screen_specs/upstream.md" '
# Upstream
- Current: the engine publishes a preview route for all three providers.
  Evidence: `flapjack_dev` — `git show origin/main:engine/docs2/openapi.json` lists the three preview paths.
'

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "a cross-repo claim that records a re-derive command must not fail the probe"
    assert_contains "$RUN_OUTPUT" "CLAIM: docs/screen_specs/upstream.md:4 class=cross-repo result=unverifiable_here target=flapjack_dev" "a cross-repo claim must be reported in its own state, not dropped"
    assert_contains "$RUN_OUTPUT" "claim_cross_repo_unverifiable_here=1" "unverifiable-here claims must be counted"
    assert_not_contains "$RUN_OUTPUT" "docs/screen_specs/upstream.md:4 class=prose" "a cross-repo claim must not be filed as unparsed prose"
}

test_cross_repo_claim_without_command_fails_closed() {
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    seed_fixture_repo "$tmpdir"
    write_file "$tmpdir" "docs/screen_specs/upstream.md" '
# Upstream
- Current: the engine declares no preview route for any provider.
  Evidence: `flapjack_dev` origin/main publishes no such path.
'

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "2" "a cross-repo claim with no re-derive command must fail closed"
    assert_contains "$RUN_OUTPUT" "WARN: docs/screen_specs/upstream.md:4 class=cross-repo result=unproven target=flapjack_dev" "an unprovable cross-repo claim must name the repo it cannot reach"
    assert_contains "$RUN_OUTPUT" "claim_cross_repo_unproven=1" "unproven cross-repo claims must be counted"
    assert_contains "$RUN_OUTPUT" "cross-repo claim records no re-derive command" "the failure must say what is missing"
    # Three distinct states, not one bucket: cannot-check-here, target-missing,
    # and claim-is-false must never collapse into each other.
    assert_not_contains "$RUN_OUTPUT" "docs/screen_specs/upstream.md:4 class=recheckable" "an unverifiable claim must not be reported as a checked one"
    assert_not_contains "$RUN_OUTPUT" "docs/screen_specs/upstream.md:4 class=dead-path" "a cross-repo claim is not a dead repo-local path"
}

test_pasted_tool_output_is_not_mistaken_for_a_re_derive_command() {
    # `test result: ok. 894 passed; 0 failed; ...` is cargo's summary line, and
    # this repo's docs quote it 34 times. It starts with the word `test`, which
    # is also a real shell command used here as `test -f` / `test -s` / `test -x`.
    # Recognising the pasted line as a command would let a cross-repo claim quote
    # OUTPUT as though it were a re-derivable PROOF and pass the gate — the exact
    # rumour-accepted-as-measurement failure this classifier exists to stop.
    # The discriminator is a flag: real `test`/`make` invocations take one,
    # result lines and prose ("make sure ...") do not.
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    seed_fixture_repo "$tmpdir"
    write_file "$tmpdir" "docs/screen_specs/upstream.md" '
# Upstream
- Current: the engine suite is green.
  Evidence: `flapjack_dev` — `test result: ok. 894 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out`.
'

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "2" "quoted tool output must not satisfy the re-derive-command requirement"
    assert_contains "$RUN_OUTPUT" "WARN: docs/screen_specs/upstream.md:4 class=cross-repo result=unproven target=flapjack_dev" "a claim quoting output records no way to re-derive it"

    # Positive control: the same head IS a command when it carries a flag, so the
    # fix must not reject genuine `test -f` evidence.
    write_file "$tmpdir" "docs/screen_specs/upstream.md" '
# Upstream
- Current: the engine publishes its bundle.
  Evidence: `flapjack_dev` — `test -f engine/docs2/openapi.json` succeeds on origin/main.
'

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "a genuine flagged invocation must still count as a re-derive command"
    assert_contains "$RUN_OUTPUT" "CLAIM: docs/screen_specs/upstream.md:4 class=cross-repo result=unverifiable_here target=flapjack_dev" "flagged test invocation should be accepted as proof"
}

test_home_relative_link_is_outside_repo_scope() {
    # `~/.matt/scrai/globals/standards/*.md` is a home-directory pointer to the
    # shared scrai tree, not a repo-relative link. Resolving it against the
    # citing document's directory produced `docs/live-state/<stamp>/~/.matt/...`
    # and reported a dead pointer for a target that was never in the repo. Two
    # such false positives existed on main, and they are exactly the noise that
    # would have to be triaged away before this probe could gate anything.
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    seed_fixture_repo "$tmpdir"
    write_file "$tmpdir" "docs/home_links.md" '
[globals standard](~/.matt/scrai/globals/standards/live_state_discipline.md)
[genuinely missing](really/missing.md)
'

    run_probe "$tmpdir"

    assert_not_contains "$RUN_OUTPUT" "raw_target=~/.matt/scrai/globals/standards/live_state_discipline.md" "home-relative pointers must be outside local-link scope"
    assert_contains "$RUN_OUTPUT" "WARN: docs/home_links.md:3 class=moved_pointer raw_target=really/missing.md" "a genuinely missing repo-relative link must still be reported"
}

test_claim_corpus_tolerates_absent_canonical_docs() {
    # The public mirrors are a strict whitelist: `.debbie.toml` syncs ROADMAP.md
    # and README.md but NOT LAUNCH.md or PROJECT_OVERVIEW.md, while scripts/ —
    # this probe included — ships in full. A claim root that is merely absent
    # must therefore be skipped, not treated as a hard requirement. That exact
    # breakage already happened once for docs/screen_specs/, which is why
    # .debbie.toml carries a comment pinning it into the sync list.
    local tmpdir
    tmpdir="$(mktemp -d)"; register_tmp_path "$tmpdir"
    seed_fixture_repo "$tmpdir"
    rm "$tmpdir/LAUNCH.md" "$tmpdir/PROJECT_OVERVIEW.md"

    run_probe "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "an absent canonical claim root must be skipped, not crash the probe"
    assert_contains "$RUN_OUTPUT" "claim_evidence_lines=9" "the surviving corpus must still be classified in full"
}

test_local_ci_registration_is_complete() {
    # The probe spent its whole life classifying claims that nothing ever read:
    # `grep -c probe_screen_spec_claim_freshness scripts/local-ci.sh` was 0, so
    # it gated nothing. Its *test* ran via the reachability manifest, which is
    # what made the gap easy to miss — a green test on a probe no one invokes.
    # This arm pins every registration site so the wiring cannot rot back out.
    # Static assertions only, deliberately. Actually invoking `local-ci.sh
    # --summary-only` here would reach the network: it calls render_prod_drift ->
    # scripts/launch/post_wave_a_sync_prod.sh -> scripts/deploy_status.sh, which
    # curls https://api.flapjack.foo/version and the staging equivalent. This
    # suite is hermetic and its gate runs on every --fast, so it must not make
    # external calls. `--summary-only` behaviour already has an owner that mocks
    # the probe properly — scripts/tests/local_ci_summary_only_test.sh — and
    # duplicating that invocation here would be a second, worse-behaved owner.
    local local_ci="$REPO_ROOT/scripts/local-ci.sh"
    local gate_name="claim-freshness-contract"

    assert_eq "$(grep -Fxc '#                    claim-freshness-contract,' "$local_ci" || true)" "1" \
        "local-ci usage comments name the claim gate exactly once"
    assert_eq "$(grep -Fxc 'gate_claim_freshness_contract() {' "$local_ci" || true)" "1" \
        "local-ci defines the exact claim gate function once"
    assert_eq "$(grep -Fxc 'schedule claim-freshness-contract' "$local_ci" || true)" "1" \
        "local-ci fast scheduler names the claim gate exactly once"
    assert_eq "$(grep -Fxc '            claim-freshness-contract) run_gate claim-freshness-contract gate_claim_freshness_contract ;;' "$local_ci" || true)" "1" \
        "local-ci dispatches the exact claim gate once"
    assert_eq "$(grep -F "    printf 'Known gates:" "$local_ci" | grep -Fc "$gate_name" || true)" "1" \
        "local-ci summary-only inventory names the claim gate exactly once"
    assert_eq "$(grep -F '        echo "Known gates:' "$local_ci" | grep -Fc "$gate_name" || true)" "1" \
        "local-ci unknown-gate help names the claim gate exactly once"
    assert_eq "$(grep -Fo "$gate_name" "$local_ci" | wc -l | tr -d ' ')" "6" \
        "local-ci has exactly the six intended claim gate registrations"
}

test_every_defined_case_is_invoked() {
    # A test function that is defined but never called is a guard that cannot
    # fail, and nothing else in the repo catches it: probe_test_reachability.sh
    # audits test FILES, not the cases inside one. This was not hypothetical —
    # test_pasted_tool_output_is_not_mistaken_for_a_re_derive_command was added
    # here and sat inert, with the suite still reporting all green.
    local self="$SCRIPT_DIR/probe_screen_spec_claim_freshness_test.sh"
    local defined invoked
    defined="$(grep -oE '^test_[a-z0-9_]+\(\) \{' "$self" | sed 's/() {//' | sort)"
    invoked="$(grep -oE '^test_[a-z0-9_]+$' "$self" | sort -u)"

    assert_eq "$(comm -23 <(printf '%s\n' "$defined") <(printf '%s\n' "$invoked") | tr '\n' ' ' | sed 's/ *$//')" "" \
        "every defined test case must appear in the invocation list"
}

test_every_defined_case_is_invoked
test_known_claim_controls_and_link_classes
test_pasted_tool_output_is_not_mistaken_for_a_re_derive_command
test_local_ci_registration_is_complete
test_claim_corpus_tolerates_absent_canonical_docs
test_canonical_status_docs_are_claim_scanned
test_non_claim_root_docs_are_not_claim_scanned
test_cross_repo_claim_with_command_is_reported_unverifiable_here
test_cross_repo_claim_without_command_fails_closed
test_home_relative_link_is_outside_repo_scope
test_presence_claim_content_is_verified
test_missing_claim_path_fails_closed
test_claim_target_escape_fails_closed_without_reading_outside_repo
test_empty_claim_corpus_fails_closed
test_zero_recheckable_claims_fails_closed
test_zero_evidence_lines_fails_closed
test_invalid_root_and_malformed_cli_fail_closed
test_contradiction_counter_is_fail_capable
test_probe_parses_under_default_bash

run_test_summary
