#!/usr/bin/env bash
# Contract test: local-dev docs must publish the full local-isolation surface.
#
# Required contract tokens in both docs:
# - COMPOSE_PROJECT_NAME
# - LOCAL_WEB_PORT
# - PLAYWRIGHT_API_PORT
# - LOCAL_DB_PORT
# - LOCAL_S3_PORT
# - LOCAL_MAILPIT_UI_PORT
# - LOCAL_SMTP_PORT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/local_dev_test_state.sh"

RUNBOOK_DOC="$REPO_ROOT/docs/runbooks/local-dev.md"
MIRROR_DOC="$REPO_ROOT/docs/LOCAL_DEV.md"
LOCAL_DEV_ENV_BACKUP=""

setup_repo_state() {
    local tmp_dir="$1"
    LOCAL_DEV_ENV_BACKUP=$(backup_repo_path "$REPO_ROOT/.env.local" "$tmp_dir/.env.local.backup")
}

restore_repo_state() {
    restore_repo_path "$REPO_ROOT/.env.local" "${LOCAL_DEV_ENV_BACKUP:-}"
    LOCAL_DEV_ENV_BACKUP=""
}

assert_doc_contains_token() {
    local doc_path="$1"
    local doc_label="$2"
    local token="$3"

    local doc_content
    doc_content="$(read_file_content "$doc_path")"
    assert_contains "$doc_content" "$token" "$doc_label includes $token"
}

test_docs_publish_full_isolation_contract() {
    local required_tokens=(
        "COMPOSE_PROJECT_NAME"
        "LOCAL_WEB_PORT"
        "PLAYWRIGHT_API_PORT"
        "LOCAL_DB_PORT"
        "LOCAL_S3_PORT"
        "LOCAL_MAILPIT_UI_PORT"
        "LOCAL_SMTP_PORT"
    )

    for token in "${required_tokens[@]}"; do
        assert_doc_contains_token "$RUNBOOK_DOC" "docs/runbooks/local-dev.md" "$token"
        assert_doc_contains_token "$MIRROR_DOC" "docs/LOCAL_DEV.md" "$token"
    done
}

assert_doc_excludes_basename_fallback() {
    local doc_path="$1"
    local doc_label="$2"
    local doc_content
    doc_content="$(read_file_content "$doc_path")"
    assert_not_contains "$doc_content" "\$(basename \"\$PWD\")" "$doc_label avoids basename fallback in compose project guidance"
}

assert_doc_includes_resolver_driven_status_command() {
    local doc_path="$1"
    local doc_label="$2"
    local doc_content
    doc_content="$(read_file_content "$doc_path")"
    assert_contains "$doc_content" "REPO_ROOT=\"\$(git rev-parse --show-toplevel)\"" "$doc_label derives REPO_ROOT for compose status command"
    assert_contains "$doc_content" "source \"\$REPO_ROOT/scripts/lib/compose_project.sh\"" "$doc_label sources compose resolver from repo root path"
    assert_contains "$doc_content" "docker compose --project-name \"\$(resolve_compose_project_name \"\$REPO_ROOT\")\" ps" "$doc_label resolves compose project name from REPO_ROOT"
    assert_not_contains "$doc_content" "resolve_compose_project_name \"\$PWD\"" "$doc_label rejects subdirectory-dependent compose project resolution"
}

test_docs_match_compose_project_contract() {
    assert_doc_excludes_basename_fallback "$RUNBOOK_DOC" "docs/runbooks/local-dev.md"
    assert_doc_excludes_basename_fallback "$MIRROR_DOC" "docs/LOCAL_DEV.md"
    assert_doc_includes_resolver_driven_status_command "$RUNBOOK_DOC" "docs/runbooks/local-dev.md"
    assert_doc_includes_resolver_driven_status_command "$MIRROR_DOC" "docs/LOCAL_DEV.md"
}

assert_doc_publishes_cleanup_first_remediation() {
    local doc_path="$1"
    local doc_label="$2"
    local doc_content
    doc_content="$(read_file_content "$doc_path")"

    assert_contains "$doc_content" "bash scripts/cleanup_dev_orphans.sh" \
        "$doc_label includes cleanup dry-run command"
    assert_contains "$doc_content" "bash scripts/cleanup_dev_orphans.sh --apply" \
        "$doc_label includes explicit cleanup apply command"
    assert_contains "$doc_content" "bash scripts/dev_state_audit.sh" \
        "$doc_label keeps dev_state_audit as post-cleanup verifier"
    assert_contains "$doc_content" "scripts/local-dev-down.sh --clean && scripts/local_demo.sh" \
        "$doc_label documents full local reset as a fallback"
    assert_contains "$doc_content" "broader fallback" \
        "$doc_label labels full local reset as the broader fallback"

    if python3 - "$doc_content" <<'PY'
import sys

doc = sys.argv[1]
needles = [
    "bash scripts/cleanup_dev_orphans.sh",
    "bash scripts/cleanup_dev_orphans.sh --apply",
    "bash scripts/dev_state_audit.sh",
    "scripts/local-dev-down.sh --clean && scripts/local_demo.sh",
]
positions = [doc.find(needle) for needle in needles]
if any(position == -1 for position in positions):
    raise SystemExit(1)
if positions != sorted(positions):
    raise SystemExit(1)
PY
    then
        pass "$doc_label documents cleanup dry-run/apply and audit before full reset fallback"
    else
        fail "$doc_label should publish cleanup dry-run/apply plus audit before full reset fallback"
    fi
}

test_docs_publish_orphan_cleanup_flow() {
    assert_doc_publishes_cleanup_first_remediation "$RUNBOOK_DOC" "docs/runbooks/local-dev.md"
    assert_doc_publishes_cleanup_first_remediation "$MIRROR_DOC" "docs/LOCAL_DEV.md"
}

test_prepare_env_uses_local_port_overrides() {
    local tmp_dir env_text
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_state; rm -rf "'"$tmp_dir"'"' RETURN
    setup_repo_state "$tmp_dir"
    write_local_dev_env_file "$REPO_ROOT/.env.local" "postgres://local-test:local-pass@localhost:5432/local_dev_runbook_currency"

    LOCAL_MAILPIT_UI_PORT=8125 PLAYWRIGHT_API_PORT=3999 \
        bash "$REPO_ROOT/scripts/local_demo.sh" --prepare-env-only >/dev/null

    env_text="$(read_file_content "$REPO_ROOT/.env.local")"
    assert_contains "$env_text" "API_BASE_URL=http://127.0.0.1:3999" \
        "prepare-env should derive API_BASE_URL from PLAYWRIGHT_API_PORT"
    assert_contains "$env_text" "MAILPIT_API_URL=http://localhost:8125" \
        "prepare-env should derive MAILPIT_API_URL from LOCAL_MAILPIT_UI_PORT"
}

main() {
    echo "=== local_dev_runbook_currency_test.sh ==="
    echo ""

    assert_file_exists "$RUNBOOK_DOC" "runbook doc exists"
    assert_file_exists "$MIRROR_DOC" "mirror doc exists"
    test_docs_publish_full_isolation_contract
    test_docs_match_compose_project_contract
    test_docs_publish_orphan_cleanup_flow
    test_prepare_env_uses_local_port_overrides
    run_test_summary
}

main "$@"
