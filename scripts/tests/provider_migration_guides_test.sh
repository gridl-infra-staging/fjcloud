#!/usr/bin/env bash
# Fail-capable contract test for provider migration guide coverage and citations.
# Shared helpers resolve from the executing checkout.
# Literal Markdown code-span markers must not execute as shell substitutions.
# shellcheck disable=SC1091,SC2016

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="${FJCLOUD_REPO_ROOT:-$DEFAULT_REPO_ROOT}"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$DEFAULT_REPO_ROOT/scripts/tests/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$DEFAULT_REPO_ROOT/scripts/tests/lib/assertions.sh"

TEST_SCRIPT="$SCRIPT_DIR/provider_migration_guides_test.sh"
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

create_scratch_guide_root() {
    local owner_parent="${1:-}"

    SCRATCH_GUIDE_ROOT="$(mktemp -d)"
    register_tmp_path "$SCRATCH_GUIDE_ROOT"
    mkdir -p \
        "$SCRATCH_GUIDE_ROOT/docs/getting-started" \
        "$SCRATCH_GUIDE_ROOT/web/src/routes/console/migrate"
    if [ -n "$owner_parent" ]; then
        mkdir -p "$SCRATCH_GUIDE_ROOT/$owner_parent"
    fi
    : > "$SCRATCH_GUIDE_ROOT/docs/getting-started/migrating_from_meilisearch.md"
    : > "$SCRATCH_GUIDE_ROOT/docs/getting-started/migrating_from_typesense.md"
}

write_scratch_algolia_guide() {
    local heading="$1"
    shift

    printf '%s\n' "$heading" 'migration_indexes_batch_add_object' \
        > "$SCRATCH_GUIDE_ROOT/docs/getting-started/migrating_from_algolia.md"
    for code_span in "$@"; do
        printf '\140%s\140\n' "$code_span" \
            >> "$SCRATCH_GUIDE_ROOT/docs/getting-started/migrating_from_algolia.md"
    done
    printf '\140%s\140\n' '/console/migrate' \
        >> "$SCRATCH_GUIDE_ROOT/docs/getting-started/migrating_from_algolia.md"
}

assert_contract_markers() {
    local contract_file="$1" contract_label="$2"
    shift 2

    if [ ! -f "$contract_file" ]; then
        fail "missing provider migration contract: $contract_label ($contract_file)"
        return
    fi

    local contract_content marker
    contract_content="$(read_file_content "$contract_file")"
    for marker in "$@"; do
        assert_contains "$contract_content" "$marker" \
            "$contract_label preserves required boundary copy: $marker"
    done
}

assert_provider_boundary_contracts() {
    assert_contract_markers \
        "$REPO_ROOT/docs/getting-started/migrating_from_algolia.md" \
        "Algolia guide" \
        "fails closed" \
        'capabilities force `resume` to `false`'
    assert_contract_markers \
        "$REPO_ROOT/docs/getting-started/migrating_from_meilisearch.md" \
        "Meilisearch guide" \
        '`SourceImportProvider::has_adapter` returns `false`' \
        'fail JSON extraction before `validate_source_provider` runs' \
        "cannot discover or preview"
    assert_contract_markers \
        "$REPO_ROOT/docs/getting-started/migrating_from_typesense.md" \
        "Typesense guide" \
        '`SourceImportProvider::has_adapter` returns `false`' \
        'fail JSON extraction before `validate_source_provider` runs' \
        "cannot discover or preview"
    assert_contract_markers \
        "$REPO_ROOT/deliverables/stage_01_provider_migration_research_closeout.md" \
        "Stage 1 research closeout" \
        "can fail JSON extraction before" \
        "does not show the exact source" \
        "ROADMAP CORRECTION REQUIRED: hosted-provider error sequencing"
}

run_missing_provider_boundary_copy_mutation() {
    local scratch output mutation_exit
    create_scratch_guide_root
    scratch="$SCRATCH_GUIDE_ROOT"
    mkdir -p "$scratch/deliverables"
    printf '%s\n' \
        'fails closed' \
        'capabilities force `resume` to `false`' \
        > "$scratch/docs/getting-started/migrating_from_algolia.md"
    printf '%s\n' \
        '`SourceImportProvider::has_adapter` returns `false`' \
        'cannot discover or preview' \
        > "$scratch/docs/getting-started/migrating_from_meilisearch.md"
    printf '%s\n' \
        '`SourceImportProvider::has_adapter` returns `false`' \
        'fail JSON extraction before `validate_source_provider` runs' \
        'cannot discover or preview' \
        > "$scratch/docs/getting-started/migrating_from_typesense.md"
    printf '%s\n' \
        'can fail JSON extraction before `validate_source_provider` runs' \
        'does not show the exact source provider' \
        'ROADMAP CORRECTION REQUIRED: hosted-provider error sequencing' \
        > "$scratch/deliverables/stage_01_provider_migration_research_closeout.md"

    mutation_exit=0
    output="$(
        FJCLOUD_PROVIDER_GUIDE_SEMANTIC_ONLY=1 \
            FJCLOUD_PROVIDER_GUIDE_MUTATION_CHILD=1 \
            FJCLOUD_REPO_ROOT="$scratch" \
            bash "$TEST_SCRIPT" 2>&1
    )" || mutation_exit=$?

    assert_ne "$mutation_exit" "0" \
        "removing hosted-provider extraction warning fails coverage"
    assert_contains "$output" \
        'Meilisearch guide preserves required boundary copy: fail JSON extraction before `validate_source_provider` runs' \
        "missing hosted-provider extraction warning is reported"
}

run_missing_backticked_owner_mutation() {
    local owner_path="$1" owner_parent="$2" scratch output mutation_exit
    create_scratch_guide_root "$owner_parent"
    scratch="$SCRATCH_GUIDE_ROOT"
    write_scratch_algolia_guide '## Operation mapping' "$owner_path"

    mutation_exit=0
    output="$(
        FJCLOUD_PROVIDER_GUIDE_MUTATION_CHILD=1 \
            FJCLOUD_REPO_ROOT="$scratch" \
            bash "$TEST_SCRIPT" 2>&1
    )" || mutation_exit=$?

    assert_ne "$mutation_exit" "0" \
        "missing backticked owner fails coverage: $owner_path"
    assert_contains "$output" \
        "migrating_from_algolia.md cites nonexistent repo path: $owner_path" \
        "missing backticked owner is reported without omission or truncation: $owner_path"
    assert_contains "$output" "repo paths extracted: 1" \
        "missing backticked owner contributes exactly one extracted path: $owner_path"
    assert_contains "$output" "repo paths verified: 0" \
        "missing backticked owner cannot increment the verified denominator: $owner_path"
}

run_heading_level_mutation() {
    local scratch output mutation_exit
    create_scratch_guide_root
    scratch="$SCRATCH_GUIDE_ROOT"
    : > "$scratch/README.md"
    write_scratch_algolia_guide '### Operation mapping' 'README.md'

    mutation_exit=0
    output="$(
        FJCLOUD_PROVIDER_GUIDE_MUTATION_CHILD=1 \
            FJCLOUD_REPO_ROOT="$scratch" \
            bash "$TEST_SCRIPT" 2>&1
    )" || mutation_exit=$?

    assert_ne "$mutation_exit" "0" \
        "demoted Algolia operation-mapping heading fails coverage"
    assert_contains "$output" \
        "Algolia prior-art operation mapping remains present as an exact level-two heading" \
        "heading demotion reports the exact-heading contract"
}

run_ordinary_dotted_literal_specimen() {
    local scratch output specimen_exit
    create_scratch_guide_root
    scratch="$SCRATCH_GUIDE_ROOT"
    : > "$scratch/README.md"
    write_scratch_algolia_guide '## Operation mapping' 'README.md' 'v1.2'

    specimen_exit=0
    output="$(
        FJCLOUD_PROVIDER_GUIDE_MUTATION_CHILD=1 \
            FJCLOUD_REPO_ROOT="$scratch" \
            bash "$TEST_SCRIPT" 2>&1
    )" || specimen_exit=$?

    assert_eq "$specimen_exit" "0" \
        "ordinary dotted literal does not become a repo-path claim"
    assert_contains "$output" "repo paths extracted: 1" \
        "ordinary dotted literal is excluded while README.md remains extracted"
    assert_not_contains "$output" "nonexistent repo path: v1.2" \
        "ordinary dotted literal is not reported as a missing repo path"
}

run_missing_console_route_mutation() {
    local missing_route="/console/provider-migration-missing"
    local scratch output mutation_exit
    create_scratch_guide_root
    scratch="$SCRATCH_GUIDE_ROOT"
    : > "$scratch/README.md"
    write_scratch_algolia_guide '## Operation mapping' 'README.md'
    printf '\140%s\140\n' "$missing_route" \
        >> "$scratch/docs/getting-started/migrating_from_algolia.md"

    mutation_exit=0
    output="$(
        FJCLOUD_PROVIDER_GUIDE_MUTATION_CHILD=1 \
            FJCLOUD_REPO_ROOT="$scratch" \
            bash "$TEST_SCRIPT" 2>&1
    )" || mutation_exit=$?

    assert_ne "$mutation_exit" "0" \
        "missing non-migration console route fails coverage"
    assert_contains "$output" \
        "claims console route without SvelteKit directory: $missing_route" \
        "missing non-migration console route is reported"
    assert_contains "$output" "console routes extracted: 2" \
        "all console route claims contribute to the extracted denominator"
}

if [ "${FJCLOUD_PROVIDER_GUIDE_SEMANTIC_ONLY:-0}" = "1" ]; then
    assert_provider_boundary_contracts
    run_test_summary
    exit $?
fi

if [ "${FJCLOUD_PROVIDER_GUIDE_MUTATION_CHILD:-0}" != "1" ]; then
    run_missing_backticked_owner_mutation "README.md" "."
    run_missing_backticked_owner_mutation \
        "web/src/routes/provider-migration-fixture/+page.svelte" \
        "web/src/routes/provider-migration-fixture"
    run_heading_level_mutation
    run_ordinary_dotted_literal_specimen
    run_missing_console_route_mutation
    run_missing_provider_boundary_copy_mutation
    assert_provider_boundary_contracts
fi

GUIDES=(
    "algolia:docs/getting-started/migrating_from_algolia.md"
    "meilisearch:docs/getting-started/migrating_from_meilisearch.md"
    "typesense:docs/getting-started/migrating_from_typesense.md"
)

REQUIRED_GUIDES_FOUND=0
REPO_PATHS_EXTRACTED=0
REPO_PATHS_VERIFIED=0
CONSOLE_ROUTES_EXTRACTED=0
CONSOLE_ROUTES_VERIFIED=0
PRESENT_GUIDES=()

for guide_spec in "${GUIDES[@]}"; do
    provider="${guide_spec%%:*}"
    guide_rel="${guide_spec#*:}"
    guide_abs="$REPO_ROOT/$guide_rel"

    if [ -f "$guide_abs" ]; then
        pass "required provider guide found: $provider"
        REQUIRED_GUIDES_FOUND=$((REQUIRED_GUIDES_FOUND + 1))
        PRESENT_GUIDES+=("$guide_rel")
    else
        fail "missing required provider guide: $provider ($guide_rel)"
    fi
done

ALGOLIA_GUIDE="$REPO_ROOT/docs/getting-started/migrating_from_algolia.md"
if [ -f "$ALGOLIA_GUIDE" ]; then
    algolia_content="$(read_file_content "$ALGOLIA_GUIDE")"
    if grep -Fqx -- '## Operation mapping' "$ALGOLIA_GUIDE"; then
        pass "Algolia prior-art operation mapping remains present as an exact level-two heading"
    else
        fail "Algolia prior-art operation mapping remains present as an exact level-two heading"
    fi
    assert_contains "$algolia_content" "migration_indexes_batch_add_object" \
        "Algolia prior-art route example marker remains present"
fi

EXTRACTIONS_FILE="$(mktemp)"
register_tmp_path "$EXTRACTIONS_FILE"

if [ "${#PRESENT_GUIDES[@]}" -gt 0 ]; then
    python3 - "$REPO_ROOT" "${PRESENT_GUIDES[@]}" > "$EXTRACTIONS_FILE" <<'PY'
import os
import re
import sys

repo_root = os.path.realpath(sys.argv[1])
guide_paths = sys.argv[2:]
repo_root_entries = set(os.listdir(repo_root))
rust_owner_suffix = re.compile(
    r"^(?P<path>.+\.[^/]+)::(?:[A-Za-z_][A-Za-z0-9_]*|"
    r"\{[A-Za-z_][A-Za-z0-9_]*(?:,[A-Za-z_][A-Za-z0-9_]*)*\})$"
)
http_operation = re.compile(r"^(?:DELETE|GET|HEAD|OPTIONS|PATCH|POST|PUT)\s+/")
repo_filename = re.compile(
    r"^[A-Za-z0-9_+@-][A-Za-z0-9_.+@-]*\.[A-Za-z][A-Za-z0-9]*$"
)


def emit(kind: str, guide: str, value: str) -> None:
    print(f"{kind}\t{guide}\t{value}")


def repo_claim_escapes_root(repo_path: str) -> bool:
    resolved_path = os.path.realpath(os.path.join(repo_root, repo_path))
    try:
        return os.path.commonpath((repo_root, resolved_path)) != repo_root
    except ValueError:
        return True


def resolve_backticked_repo_path(code_span: str, guide_rel: str):
    candidate = code_span.strip()
    if (
        not candidate
        or candidate.startswith(("#", "/"))
        or "://" in candidate
        or candidate.startswith("mailto:")
        or http_operation.match(candidate)
    ):
        return None

    # A Rust owner may cite symbols after the filename. Recognize only the
    # complete owner-suffix grammar; other punctuation remains part of the
    # candidate so it fails visibly instead of verifying a truncated prefix.
    owner_match = rust_owner_suffix.fullmatch(candidate)
    if owner_match:
        candidate = owner_match.group("path")

    if candidate.startswith(("./", "../")):
        return os.path.normpath(os.path.join(os.path.dirname(guide_rel), candidate))
    if "/" in candidate:
        return os.path.normpath(candidate)
    if repo_filename.fullmatch(candidate):
        return os.path.normpath(candidate)
    return None


for guide_rel in guide_paths:
    guide_abs = os.path.join(repo_root, guide_rel)
    with open(guide_abs, encoding="utf-8") as guide_file:
        text = guide_file.read()

    repo_paths = set()
    for target in re.findall(r"\]\(([^)]+)\)", text):
        target = target.strip().split()[0]
        target = target.split("#", 1)[0].split("?", 1)[0]
        if not target or target.startswith(("#", "/", "http://", "https://", "mailto:")):
            continue
        if target.startswith(("./", "../")):
            resolved = os.path.normpath(os.path.join(os.path.dirname(guide_rel), target))
        elif target.split("/", 1)[0] in repo_root_entries and "/" in target:
            resolved = os.path.normpath(target)
        else:
            resolved = os.path.normpath(os.path.join(os.path.dirname(guide_rel), target))
        repo_paths.add(resolved)

    for code_span in re.findall(r"`([^`\n]+)`", text):
        candidate = resolve_backticked_repo_path(code_span, guide_rel)
        if candidate is not None:
            repo_paths.add(candidate)

    for repo_path in sorted(repo_paths):
        claim_type = "repo_escape" if repo_claim_escapes_root(repo_path) else "repo"
        emit(claim_type, guide_rel, repo_path)

    console_routes = {
        route.split("?", 1)[0].rstrip(".,;:")
        for route in re.findall(
            r"(?<![A-Za-z0-9])/console(?:/[A-Za-z0-9_\[\]-]+)*"
            r"(?:\?[A-Za-z0-9_.=&%-]+)?",
            text,
        )
    }
    for route in sorted(console_routes):
        emit("route", guide_rel, route)
PY
    extractor_exit=$?
    if [ "$extractor_exit" -ne 0 ]; then
        fail "provider guide claim extraction failed (exit=$extractor_exit)"
    fi
fi

while IFS=$'\t' read -r claim_type guide_rel claim_value; do
    [ -n "$claim_type" ] || continue
    case "$claim_type" in
        repo|repo_escape)
            REPO_PATHS_EXTRACTED=$((REPO_PATHS_EXTRACTED + 1))
            if [ "$claim_type" = "repo_escape" ]; then
                fail "$guide_rel cites path outside repo root: $claim_value"
            elif [ -e "$REPO_ROOT/$claim_value" ]; then
                REPO_PATHS_VERIFIED=$((REPO_PATHS_VERIFIED + 1))
            else
                fail "$guide_rel cites nonexistent repo path: $claim_value"
            fi
            ;;
        route)
            CONSOLE_ROUTES_EXTRACTED=$((CONSOLE_ROUTES_EXTRACTED + 1))
            route_dir="$REPO_ROOT/web/src/routes${claim_value}"
            if [ -d "$route_dir" ]; then
                CONSOLE_ROUTES_VERIFIED=$((CONSOLE_ROUTES_VERIFIED + 1))
            else
                fail "$guide_rel claims console route without SvelteKit directory: $claim_value"
            fi
            ;;
        *)
            fail "unknown extracted claim type '$claim_type' for $guide_rel"
            ;;
    esac
done < "$EXTRACTIONS_FILE"

if [ "$REPO_PATHS_EXTRACTED" -eq 0 ]; then
    fail "zero repo paths extracted from provider migration guides"
fi
if [ "$CONSOLE_ROUTES_EXTRACTED" -eq 0 ]; then
    fail "zero console routes extracted from provider migration guides"
fi

echo ""
echo "=== Falsifiability denominators ==="
echo "required guides found: $REQUIRED_GUIDES_FOUND"
echo "repo paths extracted: $REPO_PATHS_EXTRACTED"
echo "repo paths verified: $REPO_PATHS_VERIFIED"
echo "console routes extracted: $CONSOLE_ROUTES_EXTRACTED"
echo "console routes verified: $CONSOLE_ROUTES_VERIFIED"

run_test_summary
