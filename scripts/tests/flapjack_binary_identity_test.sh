#!/usr/bin/env bash
# Focused tests for helper-owned Flapjack binary/artifact identity matching.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"
# shellcheck source=../../scripts/lib/flapjack_binary.sh
source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"

write_identity_binary() {
    local binary_path="$1" payload="$2"
    write_mock_script "$binary_path" "printf '%s\n' '$payload'"
}

classify_binary_identity() {
    local binary_path="$1" manifest_path="$2" provenance="$3"
    FLAPJACK_BINARY_PROVENANCE="$provenance" \
        flapjack_binary_identity_reason "$binary_path" "$manifest_path"
}

write_manifest_for_binary() {
    local manifest_path="$1" binary_path="$2" revision="$3" build_id="$4" dirty="$5"
    local sha
    sha="$(flapjack_binary_sha256 "$binary_path")"
    cat > "$manifest_path" <<JSON
{
  "version": "$FJCLOUD_FLAPJACK_VERSION",
  "producer_revision": "$revision",
  "build_id": "$build_id",
  "binary_sha256": "$sha",
  "dirty": $dirty
}
JSON
}

write_source_receipt_for_binary() {
    local receipt_path="$1" binary_path="$2" revision="$3" build_id="$4" dirty="$5"
    mkdir -p "$(dirname "$receipt_path")"
    cat > "$receipt_path" <<RECEIPT
git_revision=$revision
source_digest=$build_id
build_id=$build_id
dirty=$dirty
binary_sha256=$(flapjack_binary_sha256 "$binary_path")
RECEIPT
}

test_clean_matching_release_identity() {
    local tmp_dir binary_path manifest_path reason
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    binary_path="$tmp_dir/flapjack"
    manifest_path="$tmp_dir/flapjack-manifest.json"

    write_identity_binary "$binary_path" "clean release"
    write_manifest_for_binary "$manifest_path" "$binary_path" "abc123" "build-1" "false"

    reason="$(classify_binary_identity "$binary_path" "$manifest_path" "release:$binary_path:revision:abc123:build_id:build-1")"
    assert_eq "$reason" "match" \
        "clean matching release should satisfy the helper-owned identity contract"
}

test_same_semver_different_revision_or_build_id_rejected() {
    local tmp_dir binary_path manifest_path revision_reason build_reason
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    binary_path="$tmp_dir/flapjack"
    manifest_path="$tmp_dir/flapjack-manifest.json"

    write_identity_binary "$binary_path" "same semver different producer"
    write_manifest_for_binary "$manifest_path" "$binary_path" "abc123" "build-1" "false"

    revision_reason="$(classify_binary_identity "$binary_path" "$manifest_path" "release:$binary_path:revision:def456:build_id:build-1")"
    build_reason="$(classify_binary_identity "$binary_path" "$manifest_path" "release:$binary_path:revision:abc123:build_id:build-2")"

    assert_eq "$revision_reason" "revision_mismatch" \
        "same semver with a different producer revision should be rejected by exact reason"
    assert_eq "$build_reason" "build_id_mismatch" \
        "same semver with a different build id should be rejected by exact reason"
}

test_source_receipt_revision_or_build_id_mismatch_rejected() {
    local tmp_dir binary_path manifest_path revision_receipt build_receipt
    local revision_reason build_reason
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    binary_path="$tmp_dir/flapjack"
    manifest_path="$tmp_dir/flapjack-manifest.json"
    revision_receipt="$tmp_dir/receipts/revision.receipt"
    build_receipt="$tmp_dir/receipts/build.receipt"

    write_identity_binary "$binary_path" "source-backed producer identity"
    write_manifest_for_binary "$manifest_path" "$binary_path" "abc123" "build-1" "false"
    write_source_receipt_for_binary "$revision_receipt" "$binary_path" "def456" "build-1" "clean"
    write_source_receipt_for_binary "$build_receipt" "$binary_path" "abc123" "build-2" "clean"

    revision_reason="$(classify_binary_identity "$binary_path" "$manifest_path" "source-receipt:$revision_receipt")"
    build_reason="$(classify_binary_identity "$binary_path" "$manifest_path" "source-receipt:$build_receipt")"

    assert_eq "$revision_reason" "revision_mismatch" \
        "real source receipt producer revision should be enforced without token injection"
    assert_eq "$build_reason" "build_id_mismatch" \
        "real source receipt build id should be enforced without token injection"
}

test_checksum_mismatch_rejected() {
    local tmp_dir binary_path manifest_path reason
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    binary_path="$tmp_dir/flapjack"
    manifest_path="$tmp_dir/flapjack-manifest.json"

    write_identity_binary "$binary_path" "expected payload"
    write_manifest_for_binary "$manifest_path" "$binary_path" "abc123" "build-1" "false"
    write_identity_binary "$binary_path" "tampered payload"

    reason="$(classify_binary_identity "$binary_path" "$manifest_path" "release:$binary_path:revision:abc123:build_id:build-1")"
    assert_eq "$reason" "checksum_mismatch" \
        "checksum mismatch should be rejected by exact reason"
}

test_nested_build_manifest_artifact_checksum_mismatch_rejected() {
    local tmp_dir binary_path manifest_path expected_sha matching_reason mismatch_reason
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    binary_path="$tmp_dir/flapjack"
    manifest_path="$tmp_dir/flapjack-manifest.json"

    write_identity_binary "$binary_path" "expected nested-manifest payload"
    expected_sha="$(flapjack_binary_sha256 "$binary_path")"
    cat > "$manifest_path" <<JSON
{
  "build": {
    "version": "$FJCLOUD_FLAPJACK_VERSION",
    "producer_revision": "abc123",
    "build_id": "build-1",
    "dirty": false
  },
  "artifact": {
    "sha256": "$expected_sha"
  }
}
JSON
    matching_reason="$(classify_binary_identity "$binary_path" "$manifest_path" "release:$binary_path:revision:abc123:build_id:build-1")"
    write_identity_binary "$binary_path" "tampered nested-manifest payload"

    mismatch_reason="$(classify_binary_identity "$binary_path" "$manifest_path" "release:$binary_path:revision:abc123:build_id:build-1")"
    assert_eq "$matching_reason" "match" \
        "nested build manifests should accept the matching sibling artifact checksum"
    assert_eq "$mismatch_reason" "checksum_mismatch" \
        "nested build manifests should enforce the sibling artifact checksum"
}

test_dirty_local_build_identity_rejected() {
    local tmp_dir binary_path manifest_path receipt_path reason
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    binary_path="$tmp_dir/flapjack"
    manifest_path="$tmp_dir/flapjack-manifest.json"
    receipt_path="$tmp_dir/source.receipt"

    write_identity_binary "$binary_path" "dirty source payload"
    write_manifest_for_binary "$manifest_path" "$binary_path" "abc123" "build-1" "false"
    write_source_receipt_for_binary "$receipt_path" "$binary_path" "abc123" "build-1" "dirty"

    reason="$(classify_binary_identity "$binary_path" "$manifest_path" "source-build:$receipt_path")"
    assert_eq "$reason" "dirty_local_build" \
        "dirty selected-source identity must not satisfy a clean manifest identity"
}

main() {
    echo "=== flapjack binary identity tests ==="
    echo ""

    test_clean_matching_release_identity
    test_same_semver_different_revision_or_build_id_rejected
    test_source_receipt_revision_or_build_id_mismatch_rejected
    test_checksum_mismatch_rejected
    test_nested_build_manifest_artifact_checksum_mismatch_rejected
    test_dirty_local_build_identity_rejected

    run_test_summary
}

main "$@"
