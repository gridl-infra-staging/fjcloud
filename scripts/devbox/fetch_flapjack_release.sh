#!/usr/bin/env bash
# Fetch the prebuilt Linux flapjack engine binary for the devbox.
#
# WHY DOWNLOAD RATHER THAN BUILD
#   The browser stack needs a running flapjack engine, but the engine lives in a
#   separate repo whose workspace is ~10G of source before any build. The
#   operator's local build is darwin/arm64 and useless on an x86_64 Linux box.
#   The public release page already publishes exactly the artifact CI consumes,
#   so the devbox consumes the same one.
#
# SAME CONTRACT AS CI
#   .github/workflows/ci.yml, job `local-dev-up-smoke`, step "Download flapjack
#   release binary" does this inline: same asset name, same version source, and
#   the same published-SHA256 verification. The checksum step is the reason this
#   is a script with tests rather than three lines inline — the binary is
#   downloaded from the internet and then run as the search engine behind every
#   browser proof, so installing an unverified one would be a supply-chain hole.
#   NOTE: the CI copy is still inline. De-duplicating it means editing a workflow
#   that only runs on the public mirrors, so it is deliberately left for a
#   change that can watch the result rather than being done blind.
#
# VERSION OWNERSHIP
#   FJCLOUD_FLAPJACK_VERSION in scripts/lib/flapjack_binary.sh is the single
#   owner. This script is one of its EXACT-tag consumers: it downloads
#   precisely v${FJCLOUD_FLAPJACK_VERSION}, so that value must always name a
#   published release. The runtime identity check treats the same value as a
#   FLOOR and accepts newer engines, so a hardcoded version here would not
#   necessarily be rejected at startup — it could silently install an engine
#   other than the one the repository pins, which is worse than a loud failure.
#
# USAGE
#   fetch_flapjack_release.sh --dest <flapjack_dev_dir>
#   Then run the stack with FLAPJACK_DEV_DIR=<flapjack_dev_dir>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Single exit path for every precondition and verification failure. The
# FLAPJACK_FETCH_REFUSED: prefix is machine-readable so tests can distinguish a
# deliberate refusal from an incidental crash, both of which exit non-zero.
refuse() {
    echo "FLAPJACK_FETCH_REFUSED: $*" >&2
    exit 2
}

DEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dest) DEST="${2:-}"; shift 2 ;;
        *) refuse "unknown argument '$1'" ;;
    esac
done

[ -n "$DEST" ] || refuse "--dest is required (the FLAPJACK_DEV_DIR to populate)"

# REPO_ROOT is required by flapjack_binary.sh's candidate helpers.
# shellcheck source=../lib/flapjack_binary.sh
source "$REPO_ROOT/lib/flapjack_binary.sh"
[ -n "${FJCLOUD_FLAPJACK_VERSION:-}" ] || refuse "FJCLOUD_FLAPJACK_VERSION is not set by scripts/lib/flapjack_binary.sh"

FLAPJACK_VERSION="v${FJCLOUD_FLAPJACK_VERSION}"
# Named explicitly rather than derived from `uname`: this script always targets
# the x86_64 Linux devbox, and deriving it would happily fetch a macOS build
# when run from the operator's machine.
FLAPJACK_ASSET="flapjack-x86_64-unknown-linux-musl.tar.gz"
BASE="https://github.com/flapjackhq/flapjack/releases/download/${FLAPJACK_VERSION}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

curl -fsSL --retry 5 --retry-delay 2 \
    "${BASE}/${FLAPJACK_ASSET}" -o "$workdir/${FLAPJACK_ASSET}" \
    || refuse "could not download ${FLAPJACK_ASSET} from ${BASE}"

curl -fsSL --retry 5 --retry-delay 2 \
    "${BASE}/${FLAPJACK_ASSET}.sha256" -o "$workdir/${FLAPJACK_ASSET}.sha256" \
    || refuse "could not download the published checksum for ${FLAPJACK_ASSET}"

# Verify BEFORE extracting. Extracting first and checking after would leave an
# unverified executable on disk at the exact path the stack resolves.
( cd "$workdir" && sha256sum -c "${FLAPJACK_ASSET}.sha256" >/dev/null 2>&1 ) \
    || refuse "published SHA256 does not match the downloaded ${FLAPJACK_ASSET}"

# target/release/ is where scripts/lib/flapjack_binary.sh looks under a
# FLAPJACK_DEV_DIR candidate, so the layout is part of the contract.
install_dir="$DEST/target/release"
mkdir -p "$install_dir"
tar -xzf "$workdir/${FLAPJACK_ASSET}" -C "$install_dir" \
    || refuse "could not extract ${FLAPJACK_ASSET}"
chmod +x "$install_dir/flapjack"

echo "FLAPJACK_INSTALLED=$install_dir/flapjack"
echo "FLAPJACK_VERSION=$FJCLOUD_FLAPJACK_VERSION"
