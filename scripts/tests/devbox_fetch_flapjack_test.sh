#!/usr/bin/env bash
# Tests for scripts/devbox/fetch_flapjack_release.sh — acquires the prebuilt
# Linux flapjack engine binary so the devbox can run the browser stack without
# syncing and building the ~10G engine workspace.
#
# The load-bearing test is test_checksum_mismatch_refuses_to_install. This
# downloads an executable from a public release page and runs it as the search
# engine behind the browser suite; installing one whose published checksum does
# not match would be a supply-chain hole. The CI job this mirrors
# (.github/workflows/ci.yml, "Download flapjack release binary") verifies the
# checksum, so the verification is the contract being preserved here, not an
# embellishment.
#
# The `sha256sum` stub encodes the REAL tool's contract per rule 5: `sha256sum -c`
# exits non-zero and prints "FAILED" on mismatch. A stub that merely returned
# whatever the caller wanted would let a broken verification pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/test_helpers.sh"

FETCH="$REPO_ROOT/scripts/devbox/fetch_flapjack_release.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Stubs for curl and sha256sum. Behaviour driven by:
#   FJ_MOCK_CHECKSUM_OK   1 => `sha256sum -c` succeeds, 0 => real FAILED shape
#   FJ_MOCK_CURL_FAIL     1 => download exits non-zero, as curl -f does on 404
mock_bin_dir() {
    local dir
    dir="$(mktemp -d)"

    cat > "$dir/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FJ_CURL_LOG:-/dev/null}"
if [ "${FJ_MOCK_CURL_FAIL:-0}" = "1" ]; then
    echo "curl: (22) The requested URL returned error: 404" >&2
    exit 22
fi
# Emulate `-o <path>`: write a placeholder artifact at the requested path.
out=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-o" ]; then out="$a"; fi
    prev="$a"
done
[ -n "$out" ] || exit 0
case "$out" in
    *.sha256) printf 'deadbeef  %s\n' "$(basename "${out%.sha256}")" > "$out" ;;
    *)        printf 'fake-tarball-bytes' > "$out" ;;
esac
MOCK

    cat > "$dir/sha256sum" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
# Real contract: `sha256sum -c FILE` prints "<name>: FAILED" and exits 1 when the
# digest does not match, and exits 0 when it does.
if [ "${1:-}" = "-c" ]; then
    if [ "${FJ_MOCK_CHECKSUM_OK:-1}" = "1" ]; then
        echo "artifact: OK"; exit 0
    fi
    echo "artifact: FAILED" >&2
    echo "sha256sum: WARNING: 1 computed checksum did NOT match" >&2
    exit 1
fi
exit 0
MOCK

    # `tar -xzf` on our fake tarball would fail, so emulate extraction by
    # dropping a file named like the real binary into the target directory.
    cat > "$dir/tar" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FJ_TAR_LOG:-/dev/null}"
dest=""
prev=""
for a in "$@"; do
    if [ "$prev" = "-C" ]; then dest="$a"; fi
    prev="$a"
done
[ -n "$dest" ] || exit 0
mkdir -p "$dest"
printf '#!/bin/sh\necho flapjack\n' > "$dest/flapjack"
MOCK

    chmod +x "$dir/curl" "$dir/sha256sum" "$dir/tar"
    echo "$dir"
}

run_fetch() {
    local mock_dir rc out
    mock_dir="$(mock_bin_dir)"
    FJ_CURL_LOG="$(mktemp)"
    set +e
    out="$(
        PATH="$mock_dir:$PATH" \
        FJ_CURL_LOG="$FJ_CURL_LOG" \
        FJ_MOCK_CHECKSUM_OK="${FJ_MOCK_CHECKSUM_OK:-1}" \
        FJ_MOCK_CURL_FAIL="${FJ_MOCK_CURL_FAIL:-0}" \
        bash "$FETCH" "$@" 2>&1
    )"
    rc=$?
    set -e
    LAST_OUTPUT="$out"
    LAST_CURL_LOG="$(cat "$FJ_CURL_LOG")"
    rm -rf "$mock_dir" "$FJ_CURL_LOG"
    return $rc
}

test_system_under_test_exists() {
    assert_file_exists "$FETCH" "the fetch script exists"
}

test_checksum_mismatch_refuses_to_install() {
    local dest rc=0
    dest="$(mktemp -d)"
    FJ_MOCK_CHECKSUM_OK=0 run_fetch --dest "$dest" || rc=$?
    assert_ne "$rc" "0" "a checksum mismatch fails the fetch"
    assert_contains "$LAST_OUTPUT" "FLAPJACK_FETCH_REFUSED:" \
        "the refusal is an explicit diagnostic, not an incidental non-zero exit"
    # The decisive assertion: nothing installed. A script that verified the
    # checksum but installed anyway would pass an exit-code-only check.
    if [ -e "$dest/target/release/flapjack" ]; then
        fail "a binary was installed despite the checksum mismatch"
    else
        pass "no binary is installed when the checksum does not match"
    fi
    rm -rf "$dest"
}

test_happy_path_installs_where_the_resolver_looks() {
    local dest
    dest="$(mktemp -d)"
    run_fetch --dest "$dest"
    # scripts/lib/flapjack_binary.sh looks for target/{debug,release}/flapjack
    # under the FLAPJACK_DEV_DIR candidate, so the layout is the contract.
    assert_file_exists "$dest/target/release/flapjack" \
        "the binary lands at target/release/flapjack where the resolver looks"
    if [ -x "$dest/target/release/flapjack" ]; then
        pass "the installed binary is executable"
    else
        fail "the installed binary is not executable"
    fi
    rm -rf "$dest"
}

test_version_comes_from_the_shared_constant() {
    # FJCLOUD_FLAPJACK_VERSION in scripts/lib/flapjack_binary.sh is the repo's
    # single owner of the engine version. Hardcoding it here would let the devbox
    # drift from CI and from the identity check the stack enforces at startup.
    local dest expected
    dest="$(mktemp -d)"
    # shellcheck disable=SC1091
    expected="$(REPO_ROOT="$REPO_ROOT"; source "$REPO_ROOT/scripts/lib/flapjack_binary.sh"; printf '%s' "$FJCLOUD_FLAPJACK_VERSION")"
    run_fetch --dest "$dest"
    assert_contains "$LAST_CURL_LOG" "v${expected}" \
        "the download URL carries the version from FJCLOUD_FLAPJACK_VERSION ($expected)"
    rm -rf "$dest"
}

test_inherited_version_env_does_not_override_shared_constant() {
    local dest
    dest="$(mktemp -d)"
    FJCLOUD_FLAPJACK_VERSION=9.9.9-bogus run_fetch --dest "$dest"
    assert_contains "$LAST_CURL_LOG" "v1.0.10" \
        "the canonical dependency version ignores inherited shell values"
    assert_not_contains "$LAST_CURL_LOG" "v9.9.9-bogus" \
        "the devbox download URL is not retargeted by an inherited version"
    rm -rf "$dest"
}

test_downloads_the_linux_asset_not_the_host_arch() {
    # The devbox is x86_64 Linux while the operator's machine is arm64 darwin.
    # Naming the asset explicitly keeps a future "just use uname" refactor from
    # silently fetching a macOS build onto the box.
    local dest
    dest="$(mktemp -d)"
    run_fetch --dest "$dest"
    assert_contains "$LAST_CURL_LOG" "flapjack-x86_64-unknown-linux-musl.tar.gz" \
        "the x86_64 linux musl asset is requested"
    rm -rf "$dest"
}

test_checksum_is_actually_downloaded_and_checked() {
    local dest
    dest="$(mktemp -d)"
    run_fetch --dest "$dest"
    assert_contains "$LAST_CURL_LOG" ".sha256" \
        "the published checksum file is fetched alongside the artifact"
    rm -rf "$dest"
}

test_download_failure_refuses() {
    local dest rc=0
    dest="$(mktemp -d)"
    FJ_MOCK_CURL_FAIL=1 run_fetch --dest "$dest" || rc=$?
    assert_ne "$rc" "0" "a failed download fails the fetch"
    if [ -e "$dest/target/release/flapjack" ]; then
        fail "a binary was installed despite the download failing"
    else
        pass "no binary is installed when the download fails"
    fi
    rm -rf "$dest"
}

test_requires_a_destination() {
    local rc=0
    run_fetch || rc=$?
    assert_ne "$rc" "0" "a missing --dest is refused"
    assert_contains "$LAST_OUTPUT" "FLAPJACK_FETCH_REFUSED:" \
        "the missing-dest refusal is an explicit diagnostic"
}

for t in \
    test_system_under_test_exists \
    test_checksum_mismatch_refuses_to_install \
    test_happy_path_installs_where_the_resolver_looks \
    test_version_comes_from_the_shared_constant \
    test_inherited_version_env_does_not_override_shared_constant \
    test_downloads_the_linux_asset_not_the_host_arch \
    test_checksum_is_actually_downloaded_and_checked \
    test_download_failure_refuses \
    test_requires_a_destination \
    ; do
    "$t"
done

echo
echo "$PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
