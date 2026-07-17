#!/usr/bin/env bash
# Focused tests for scripts/lib/flapjack_binary.sh source provenance decisions.

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

create_flapjack_checkout() {
    local checkout="$1"
    mkdir -p "$checkout/engine/flapjack-server/src" "$checkout/engine/target/debug"
    cat > "$checkout/engine/Cargo.toml" <<'EOF'
[workspace]
members = ["flapjack-server"]
EOF
    cat > "$checkout/engine/flapjack-server/Cargo.toml" <<'EOF'
[package]
name = "flapjack-server"
version = "1.0.10"
edition = "2021"
EOF
    printf 'target/\n' > "$checkout/engine/.gitignore"
    printf 'fn main() {}\n' > "$checkout/engine/flapjack-server/src/main.rs"
    (
        cd "$checkout"
        git init -q
        git config user.email test@example.com
        git config user.name "Test User"
        git add .
        git commit -qm initial
    )
}

write_mock_cargo() {
    local cargo_path="$1" call_log="$2"
    write_mock_script "$cargo_path" '
echo "cargo cwd=$(pwd) args=$*" >> "'"$call_log"'"
if [ "$*" != "build -p flapjack-server" ]; then
    exit 17
fi
mkdir -p target/debug
{
    printf "#!/usr/bin/env bash\n"
    printf "printf source-build:%s\\\\n\n" "$(date +%s%N)"
} > target/debug/flapjack
chmod +x target/debug/flapjack
'
}

resolve_flapjack_with_receipt() {
    local checkout="$1" receipt_dir="$2" provenance_file="$3"
    FLAPJACK_SOURCE_RECEIPT_DIR="$receipt_dir" \
    FLAPJACK_BINARY_PROVENANCE_FILE="$provenance_file" \
        bash -c 'REPO_ROOT="'"$REPO_ROOT"'"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; find_flapjack_binary "'"$checkout"'"'
}

assert_receipt_has_key() {
    local receipt_path="$1" key="$2"
    assert_contains "$(cat "$receipt_path")" "${key}=" \
        "source receipt should record ${key}"
}

assert_clean_source_receipt() {
    local receipt_path="$1" checkout="$2" binary_sha="$3"
    local receipt_text
    for key in checkout_path source_digest dirty cargo_package cargo_profile cargo_features target binary_sha256 built_at; do
        assert_receipt_has_key "$receipt_path" "$key"
    done
    receipt_text="$(cat "$receipt_path")"
    assert_contains "$receipt_text" "checkout_path=$checkout/engine" \
        "source receipt should bind to the selected checkout engine path"
    assert_contains "$receipt_text" "dirty=clean" \
        "initial source receipt should record clean source state"
    assert_contains "$receipt_text" "cargo_package=flapjack-server" \
        "source receipt should record the helper-owned Cargo package"
    assert_contains "$receipt_text" "cargo_profile=debug" \
        "source receipt should record the debug profile"
    assert_contains "$receipt_text" "cargo_features=default" \
        "source receipt should record default feature selection"
    assert_contains "$receipt_text" "binary_sha256=$binary_sha" \
        "source receipt should bind to the built binary digest"
}

assert_concurrent_resolver_outputs() {
    local first_out="$1" second_out="$2" source_root="$3"
    assert_eq "$(cat "$first_out")" "$source_root/target/debug/flapjack" \
        "first concurrent resolver should return the selected checkout binary"
    assert_eq "$(cat "$second_out")" "$source_root/target/debug/flapjack" \
        "second concurrent resolver should return the selected checkout binary"
}

assert_concurrent_receipt() {
    local receipt_path="$1" call_log="$2" source_root="$3" old_sha="$4"
    local cargo_calls final_sha
    cargo_calls="$(grep -c "cargo-start" "$call_log" 2>/dev/null || true)"
    final_sha="$(shasum -a 256 "$source_root/target/debug/flapjack" | awk '{print $1}')"

    assert_eq "$cargo_calls" "1" \
        "concurrent source resolution should share one helper-owned Cargo build"
    assert_ne "$final_sha" "$old_sha" \
        "concurrent source resolution must not accept a stale same-version binary"
    assert_contains "$(cat "$receipt_path")" "binary_sha256=$final_sha" \
        "concurrent source resolution should publish a complete binary-bound receipt"
    [ ! -d "$receipt_path.lock" ] || fail "concurrent source resolution should release the helper-owned lock"
}

assert_concurrent_provenance() {
    local receipt_path="$1" first_provenance="$2" second_provenance="$3"
    local provenance_text
    provenance_text="$(cat "$first_provenance")$(cat "$second_provenance")"

    assert_contains "$provenance_text" "source-build:$receipt_path" \
        "one concurrent resolver should report helper source-build provenance"
    assert_contains "$provenance_text" "source-receipt:$receipt_path" \
        "one concurrent resolver should report helper source-receipt provenance"
}

test_source_receipt_reuses_clean_checkout() {
    local tmp_dir checkout call_log provenance_file old_sha first_sha second_sha
    local first_resolved second_resolved receipt_path cargo_calls
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    checkout="$tmp_dir/flapjack_dev"
    call_log="$tmp_dir/cargo.log"
    provenance_file="$tmp_dir/provenance.txt"

    create_flapjack_checkout "$checkout"
    write_mock_script "$checkout/engine/target/debug/flapjack" \
        'printf "{\"version\":\"1.0.10\"}\n"'
    old_sha="$(shasum -a 256 "$checkout/engine/target/debug/flapjack" | awk '{print $1}')"
    mkdir -p "$tmp_dir/bin"
    write_mock_cargo "$tmp_dir/bin/cargo" "$call_log"

    first_resolved="$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
            resolve_flapjack_with_receipt "$checkout" "$tmp_dir/receipts" "$provenance_file"
    )"
    first_sha="$(shasum -a 256 "$first_resolved" | awk '{print $1}')"
    receipt_path="$(find "$tmp_dir/receipts" -name '*.receipt' -print | head -n 1)"

    assert_eq "$first_resolved" "$checkout/engine/target/debug/flapjack" \
        "source resolver should return the selected checkout binary path"
    assert_ne "$first_sha" "$old_sha" \
        "clean selected checkout should build instead of accepting an unreceipted same-version binary"
    assert_contains "$(cat "$provenance_file")" "source-build:$receipt_path" \
        "first source-backed resolution should report source-build provenance"
    assert_clean_source_receipt "$receipt_path" "$checkout" "$first_sha"

    second_resolved="$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
            resolve_flapjack_with_receipt "$checkout" "$tmp_dir/receipts" "$provenance_file"
    )"
    second_sha="$(shasum -a 256 "$second_resolved" | awk '{print $1}')"
    cargo_calls="$(grep -c "args=build -p flapjack-server" "$call_log" 2>/dev/null || true)"

    assert_eq "$second_resolved" "$first_resolved" \
        "unchanged source receipt reuse should return the same selected binary path"
    assert_eq "$second_sha" "$first_sha" \
        "unchanged source receipt reuse should keep the existing binary SHA"
    assert_eq "$cargo_calls" "1" \
        "unchanged clean source should reuse the receipt without a second Cargo build"
    assert_contains "$(cat "$provenance_file")" "source-receipt:$receipt_path" \
        "unchanged clean source should report source-receipt provenance"
}

test_dirty_selected_checkout_rebuilds_existing_receipt() {
    local tmp_dir checkout call_log provenance_file first_sha dirty_sha
    local first_resolved dirty_resolved receipt_path cargo_calls
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    checkout="$tmp_dir/flapjack_dev"
    call_log="$tmp_dir/cargo.log"
    provenance_file="$tmp_dir/provenance.txt"

    create_flapjack_checkout "$checkout"
    mkdir -p "$tmp_dir/bin"
    write_mock_cargo "$tmp_dir/bin/cargo" "$call_log"

    first_resolved="$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
            resolve_flapjack_with_receipt "$checkout" "$tmp_dir/receipts" "$provenance_file"
    )"
    first_sha="$(shasum -a 256 "$first_resolved" | awk '{print $1}')"
    receipt_path="$(find "$tmp_dir/receipts" -name '*.receipt' -print | head -n 1)"

    printf '\n// dirty local change\n' >> "$checkout/engine/flapjack-server/src/main.rs"
    dirty_resolved="$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
            resolve_flapjack_with_receipt "$checkout" "$tmp_dir/receipts" "$provenance_file"
    )"
    dirty_sha="$(shasum -a 256 "$dirty_resolved" | awk '{print $1}')"
    cargo_calls="$(grep -c "args=build -p flapjack-server" "$call_log" 2>/dev/null || true)"

    assert_eq "$dirty_resolved" "$first_resolved" \
        "dirty source rebuild should still return the selected checkout binary path"
    assert_ne "$dirty_sha" "$first_sha" \
        "dirty selected checkout should rebuild instead of reusing an older same-version binary"
    assert_eq "$cargo_calls" "2" \
        "dirty selected checkout should invoke Cargo again"
    assert_contains "$(cat "$provenance_file")" "source-build:$receipt_path" \
        "dirty selected checkout rebuild should report source-build provenance"
    assert_contains "$(cat "$receipt_path")" "dirty=dirty" \
        "dirty selected checkout rebuild should update the receipt dirty bit"
}

test_source_resolution_invokes_contract_correct_package() {
    local tmp_dir checkout call_log output exit_code=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    checkout="$tmp_dir/flapjack_dev"
    call_log="$tmp_dir/cargo.log"

    create_flapjack_checkout "$checkout"
    rm -f "$checkout/engine/target/debug/flapjack"
    mkdir -p "$tmp_dir/bin"
    write_mock_cargo "$tmp_dir/bin/cargo" "$call_log"

    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        FLAPJACK_SOURCE_RECEIPT_DIR="$tmp_dir/receipts" \
        bash -c 'REPO_ROOT="'"$REPO_ROOT"'"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; find_flapjack_binary "'"$checkout"'"' 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "source-backed resolution should build successfully through the helper"
    assert_contains "$(cat "$call_log")" "args=build -p flapjack-server" \
        "source-backed resolution should build flapjack-server"
    assert_not_contains "$(cat "$call_log")" "flapjack-http" \
        "source-backed resolution must not use the legacy flapjack-http package"
    assert_contains "$output" "$checkout/engine/target/debug/flapjack" \
        "resolver output should be the built Flapjack binary"
}

test_partial_receipt_rebuilds_instead_of_accepting_stale_binary() {
    local tmp_dir checkout source_root call_log provenance_file receipt_key receipt_path
    local source_digest old_sha resolved_sha cargo_calls
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    checkout="$tmp_dir/flapjack_dev"
    source_root="$checkout/engine"
    call_log="$tmp_dir/cargo.log"
    provenance_file="$tmp_dir/provenance.txt"

    create_flapjack_checkout "$checkout"
    write_mock_script "$source_root/target/debug/flapjack" \
        'printf "{\"version\":\"1.0.10\"}\n"'
    old_sha="$(shasum -a 256 "$source_root/target/debug/flapjack" | awk '{print $1}')"
    mkdir -p "$tmp_dir/bin" "$tmp_dir/receipts"
    write_mock_cargo "$tmp_dir/bin/cargo" "$call_log"

    source_digest="$(
        bash -c 'REPO_ROOT="'"$REPO_ROOT"'"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; flapjack_source_digest "'"$source_root"'"'
    )"
    receipt_key="$(printf '%s' "$source_root" | shasum -a 256 | awk '{print $1}')"
    receipt_path="$tmp_dir/receipts/$receipt_key.receipt"
    {
        printf 'checkout_path=%s\n' "$source_root"
        printf 'source_digest=%s\n' "$source_digest"
        printf 'dirty=clean\n'
        printf 'cargo_package=flapjack-server\n'
    } > "$receipt_path"

    FLAPJACK_SOURCE_RECEIPT_DIR="$tmp_dir/receipts" \
    FLAPJACK_BINARY_PROVENANCE_FILE="$provenance_file" \
    PATH="$tmp_dir/bin:/usr/bin:/bin" \
        bash -c 'REPO_ROOT="'"$REPO_ROOT"'"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; find_flapjack_binary "'"$checkout"'"' \
        >/dev/null

    resolved_sha="$(shasum -a 256 "$source_root/target/debug/flapjack" | awk '{print $1}')"
    cargo_calls="$(grep -c "args=build -p flapjack-server" "$call_log" 2>/dev/null || true)"

    assert_eq "$cargo_calls" "1" \
        "a partial source receipt should force exactly one Cargo rebuild"
    assert_ne "$resolved_sha" "$old_sha" \
        "a partial receipt must not authorize a stale same-version binary"
    assert_contains "$(cat "$receipt_path")" "binary_sha256=$resolved_sha" \
        "the rebuild should replace the partial receipt with a binary-bound receipt"
    assert_contains "$(cat "$provenance_file")" "source-build:$receipt_path" \
        "partial receipt recovery should report source-build provenance"
}

test_concurrent_source_resolution_shares_one_build_and_complete_receipt() {
    local tmp_dir checkout source_root call_log old_sha receipt_key receipt_path
    local first_out second_out first_provenance second_provenance
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    checkout="$tmp_dir/flapjack_dev"
    source_root="$checkout/engine"
    call_log="$tmp_dir/cargo.log"
    first_out="$tmp_dir/first.out"
    second_out="$tmp_dir/second.out"
    first_provenance="$tmp_dir/first.provenance"
    second_provenance="$tmp_dir/second.provenance"

    create_flapjack_checkout "$checkout"
    write_mock_script "$source_root/target/debug/flapjack" \
        'printf "{\"version\":\"1.0.10\"}\n"'
    old_sha="$(shasum -a 256 "$source_root/target/debug/flapjack" | awk '{print $1}')"
    mkdir -p "$tmp_dir/bin" "$tmp_dir/receipts"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "cargo-start cwd=$(pwd) args=$*" >> "'"$call_log"'"
if [ "$*" != "build -p flapjack-server" ]; then
    exit 17
fi
sleep 1
mkdir -p target/debug
{
    printf "#!/usr/bin/env bash\n"
    printf "printf concurrent-source-build\\\\n\n"
} > target/debug/flapjack
chmod +x target/debug/flapjack
echo "cargo-finish cwd=$(pwd) args=$*" >> "'"$call_log"'"
'
    receipt_key="$(printf '%s' "$source_root" | shasum -a 256 | awk '{print $1}')"
    receipt_path="$tmp_dir/receipts/$receipt_key.receipt"

    PATH="$tmp_dir/bin:/usr/bin:/bin" \
        resolve_flapjack_with_receipt "$checkout" "$tmp_dir/receipts" "$first_provenance" >"$first_out" &
    local first_pid=$!

    PATH="$tmp_dir/bin:/usr/bin:/bin" \
        resolve_flapjack_with_receipt "$checkout" "$tmp_dir/receipts" "$second_provenance" >"$second_out" &
    local second_pid=$!

    wait "$first_pid"
    wait "$second_pid"

    assert_concurrent_resolver_outputs "$first_out" "$second_out" "$source_root"
    assert_concurrent_receipt "$receipt_path" "$call_log" "$source_root" "$old_sha"
    assert_concurrent_provenance "$receipt_path" "$first_provenance" "$second_provenance"
}

test_unmanifested_release_artifacts_are_rejected_except_exact_pinned_checksum() {
    local tmp_dir bad_flapjack bad_http good_bin output exit_code=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    bad_flapjack="$tmp_dir/bin/flapjack"
    bad_http="$tmp_dir/bin_http/flapjack-http"
    good_bin="$tmp_dir/pinned/flapjack"
    mkdir -p "$(dirname "$bad_flapjack")" "$(dirname "$bad_http")"
    write_mock_script "$bad_flapjack" 'printf "not the canonical pinned release\n"'
    write_mock_script "$bad_http" 'printf "also not the canonical pinned release\n"'

    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR_CANDIDATES="/nonexistent-flapjack-candidate" \
        bash -c 'REPO_ROOT="'"$REPO_ROOT"'"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; find_restart_ready_flapjack_binary ""' 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "unmanifested noncanonical release artifact should be rejected"
    assert_contains "$output" "unmanifested" \
        "rejection should explain the unmanifested release-artifact boundary"
    assert_contains "$output" "$bad_flapjack" \
        "rejection should name the refused flapjack PATH artifact"

    exit_code=0
    output=$(
        PATH="$tmp_dir/bin_http:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR_CANDIDATES="/nonexistent-flapjack-candidate" \
        bash -c 'REPO_ROOT="'"$REPO_ROOT"'"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; find_restart_ready_flapjack_binary ""' 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "unmanifested noncanonical flapjack-http release artifact should be rejected"
    assert_contains "$output" "$bad_http" \
        "rejection should name the refused flapjack-http PATH artifact"

    mkdir -p "$(dirname "$good_bin")"
    write_mock_script "$good_bin" 'sleep 60'
    exit_code=0
    output=$(
        PATH="$(dirname "$good_bin"):/usr/bin:/bin" \
        FLAPJACK_DEV_DIR_CANDIDATES="/nonexistent-flapjack-candidate" \
        bash -c 'REPO_ROOT="'"$REPO_ROOT"'"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; flapjack_binary_sha256() { printf "%s\n" "$FJCLOUD_FLAPJACK_LEGACY_RELEASE_SHA256"; }; find_restart_ready_flapjack_binary ""' 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "exact pinned legacy release checksum should be accepted without a manifest"
    assert_eq "$output" "$good_bin" \
        "accepted pinned legacy release should resolve to the canonical binary path"
}

test_explicit_source_build_failure_does_not_fall_back_to_path() {
    local tmp_dir checkout output exit_code=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    checkout="$tmp_dir/flapjack_dev"

    create_flapjack_checkout "$checkout"
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/cargo" 'exit 17'
    write_mock_script "$tmp_dir/bin/flapjack" 'sleep 60'

    output=$(
        PATH="$tmp_dir/bin:/usr/bin:/bin" \
        FLAPJACK_DEV_DIR="$checkout" \
        FLAPJACK_DEV_DIR_CANDIDATES="/nonexistent-flapjack-candidate" \
        FLAPJACK_SOURCE_RECEIPT_DIR="$tmp_dir/receipts" \
        bash -c 'REPO_ROOT="'"$REPO_ROOT"'"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; find_restart_ready_flapjack_binary' 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "2" \
        "an explicit source build failure must fail closed with the source-resolution status"
    assert_contains "$output" "Flapjack source build failed" \
        "the selected checkout build failure should remain visible"
    assert_not_contains "$output" "$tmp_dir/bin/flapjack" \
        "the resolver must not substitute a PATH release for the selected source checkout"
}

test_source_rebuild_probe_verifies_running_behavior() {
    local probe_text
    probe_text="$(cat "$REPO_ROOT/scripts/probe_flapjack_source_rebuild.sh")"

    assert_contains "$probe_text" 'curl -fsS "$PROBE_URL/health"' \
        "source rebuild probe should query the rebuilt running server"
    assert_contains "$probe_text" 'served_probe_status_exact_count=$STATUS_MATCH_COUNT' \
        "source rebuild probe should report an exact served-behavior denominator"
    assert_contains "$probe_text" '"version":"1\.0\.10"' \
        "source rebuild probe should prove served behavior changed without a version bump"
}

test_dirty_source_identity_cannot_match_clean_manifest() {
    local tmp_dir checkout source_root call_log provenance_file binary_path manifest_path reason
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN
    checkout="$tmp_dir/flapjack_dev"
    source_root="$checkout/engine"
    call_log="$tmp_dir/cargo.log"
    provenance_file="$tmp_dir/provenance.txt"
    binary_path="$source_root/target/debug/flapjack"
    manifest_path="$tmp_dir/flapjack-manifest.json"

    create_flapjack_checkout "$checkout"
    printf '\n// dirty local change\n' >> "$source_root/flapjack-server/src/main.rs"
    mkdir -p "$tmp_dir/bin"
    write_mock_cargo "$tmp_dir/bin/cargo" "$call_log"

    PATH="$tmp_dir/bin:/usr/bin:/bin" \
    FLAPJACK_SOURCE_RECEIPT_DIR="$tmp_dir/receipts" \
    FLAPJACK_BINARY_PROVENANCE_FILE="$provenance_file" \
        bash -c 'REPO_ROOT="'"$REPO_ROOT"'"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; find_flapjack_binary "'"$checkout"'"' \
        >/dev/null

    cat > "$manifest_path" <<JSON
{
  "version": "$FJCLOUD_FLAPJACK_VERSION",
  "producer_revision": "$(git -C "$source_root" rev-parse HEAD)",
  "build_id": "local-source",
  "binary_sha256": "$(shasum -a 256 "$binary_path" | awk '{print $1}')",
  "dirty": false
}
JSON

    reason="$(
        FLAPJACK_BINARY_PROVENANCE="$(cat "$provenance_file")" \
            bash -c 'REPO_ROOT="'"$REPO_ROOT"'"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; flapjack_binary_identity_reason "'"$binary_path"'" "'"$manifest_path"'"'
    )"
    assert_eq "$reason" "dirty_local_build" \
        "dirty selected-source identity cannot be accepted as the clean manifest identity"
}

main() {
    echo "=== flapjack binary source provenance tests ==="
    echo ""

    test_source_receipt_reuses_clean_checkout
    test_dirty_selected_checkout_rebuilds_existing_receipt
    test_source_resolution_invokes_contract_correct_package
    test_partial_receipt_rebuilds_instead_of_accepting_stale_binary
    test_concurrent_source_resolution_shares_one_build_and_complete_receipt
    test_unmanifested_release_artifacts_are_rejected_except_exact_pinned_checksum
    test_explicit_source_build_failure_does_not_fall_back_to_path
    test_source_rebuild_probe_verifies_running_behavior
    test_dirty_source_identity_cannot_match_clean_manifest

    run_test_summary
}

main "$@"
