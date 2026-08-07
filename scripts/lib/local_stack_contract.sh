#!/usr/bin/env bash
# Compatibility checks for independently running local stack services.

FJCLOUD_API_PREVIEW_EVENTS_CAPABILITY="preview_events_v1"
# No capability is required by default (SSOT with the API constant removed from
# infra/api/src/services/flapjack_proxy/mod.rs). No shipped flapjack build — release
# musl, Docker, or the prod AMI — advertises a vector capability, so a hard
# "vectorSearchLocal" default was unsatisfiable and rejected every real engine as
# missing_capability (the local-dev-up-smoke blocker). Set the env var to require a
# specific capability when local vector search is productized.
FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY="${FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY:-}"

api_supports_capability() {
    local api_base_url="$1" required_capability="$2" body
    body="$(curl -fsS -m 10 "${api_base_url%/}/version" 2>/dev/null)" || return 1
    python3 - "$required_capability" "$body" <<'PY'
import json
import sys
try:
    capabilities = json.loads(sys.argv[2]).get("capabilities")
except (json.JSONDecodeError, TypeError):
    raise SystemExit(1)
if not isinstance(capabilities, list) or sys.argv[1] not in capabilities:
    raise SystemExit(1)
PY
}

api_public_infrastructure_response_is_valid() {
    local body="$1"
    python3 - "$body" <<'PY'
import json
import sys

try:
    payload = json.loads(sys.argv[1])
except (json.JSONDecodeError, TypeError):
    raise SystemExit(1)

if (
    not isinstance(payload, dict)
    or set(payload) != {"regions", "overall"}
    or not isinstance(payload["regions"], list)
    or not isinstance(payload["overall"], dict)
):
    raise SystemExit(1)
PY
}

api_public_infrastructure_is_ready() {
    local api_base_url="$1" route_url response body http_status body_tail curl_status=0
    route_url="${api_base_url%/}/public/infrastructure"
    response="$(curl -sS -m 10 -w $'\n%{http_code}' "$route_url" 2>&1)" || curl_status=$?

    if [ "$curl_status" -eq 0 ]; then
        http_status="${response##*$'\n'}"
        body="${response%$'\n'*}"
    else
        http_status="curl_error_${curl_status}"
        body="$response"
    fi

    if [ "$http_status" = "200" ] && api_public_infrastructure_response_is_valid "$body"; then
        return 0
    fi

    body_tail="$(printf '%s' "$body" | tail -c 1000)"
    printf '[local_stack_contract] public infrastructure readiness failed: base_url=%s route=%s status=%s body_tail=%s\n' \
        "$api_base_url" "$route_url" "$http_status" "$body_tail" >&2
    return 1
}

flapjack_runtime_version() {
    local flapjack_base_url="$1" body
    body="$(curl -fsS -m 10 "${flapjack_base_url%/}/health" 2>/dev/null)" || return 1
    python3 - "$body" <<'PY'
import json
import sys
try:
    version = json.loads(sys.argv[1]).get("version")
except (json.JSONDecodeError, TypeError):
    raise SystemExit(1)
if not isinstance(version, str) or not version:
    raise SystemExit(1)
print(version)
PY
}

# Classify a runtime `/health` identity payload (already fetched) against the
# required Stage 1 identity env. This is the single comparison implementation;
# both the live URL path (flapjack_runtime_identity_reason) and out-of-band
# collectors (e.g. the SSM-driven build-identity probe) delegate here so runtime
# identity comparison is never re-implemented in a caller.
flapjack_classify_health_json() {
    local body="$1"
    python3 - "$body" \
        "${FJCLOUD_FLAPJACK_VERSION:-}" \
        "${FJCLOUD_FLAPJACK_REQUIRED_REVISION:-}" \
        "${FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID:-}" \
        "${FJCLOUD_FLAPJACK_REQUIRED_SHA256:-}" \
        "${FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY:-}" <<'PY'
import json
import sys


def fail(reason):
    print(reason)
    raise SystemExit(0)


def first_string(payload, *names):
    for name in names:
        value = payload.get(name)
        if isinstance(value, str) and value:
            return value
    return ""


def parse_version(value):
    """Parse a strict MAJOR.MINOR.PATCH numeric version, or return None.

    Deliberately strict, and deliberately NOT lenient about suffixes. fjcloud
    pins published flapjack releases, which are always three numeric components.
    A `-rc` suffix is refused rather than stripped: semver orders 1.0.12-rc.1
    BELOW 1.0.12, so a suffix-stripping parser would rank a release candidate as
    equal to the finished release and let it satisfy a floor it does not meet.
    Anything unparseable fails closed at the call site.

    isascii() guards against non-ASCII digit characters, which isdigit() accepts
    and int() would then happily convert.
    """
    parts = value.split(".")
    if len(parts) != 3:
        return None
    numbers = []
    for part in parts:
        if not part.isascii() or not part.isdigit():
            return None
        numbers.append(int(part))
    return tuple(numbers)


try:
    health = json.loads(sys.argv[1])
except (json.JSONDecodeError, TypeError):
    fail("legacy_malformed_health")
if not isinstance(health, dict):
    fail("legacy_malformed_health")

build = health.get("build") if isinstance(health.get("build"), dict) else health
version = first_string(build, "version") or first_string(health, "version")
revision = first_string(build, "producer_revision", "revision")
build_id = first_string(build, "build_id", "workspaceDigest")
dirty = build.get("dirty")
capabilities = build.get("capabilities", health.get("capabilities"))

# Runtime /health identity is anchored on the fields Flapjack actually emits:
# version + revision + build_id/workspaceDigest + dirty + capabilities (see the
# engine's build_info.rs BuildInfo schema and its /health allowlist test, which
# deliberately excludes any binary hash). The compiled binary's FILE sha256 is an
# ARTIFACT-layer anchor and is verified where the binary is obtained (CI
# `sha256sum -c`, flapjack_binary.sh manifest/receipt comparison, and
# probe_flapjack_build_identity.sh's installed-vs-expected sha) — NOT via /health,
# which a running process cannot self-report. required_sha is therefore
# intentionally NOT part of the runtime-identity requirement below; requiring it
# here made this classifier fail `legacy_malformed_health` for every real engine.
required_version, required_revision, required_build_id, required_sha, required_capability = sys.argv[2:7]
exact_identity_required = bool(required_revision or required_build_id)
if not version:
    fail("legacy_malformed_health")
# FJCLOUD_FLAPJACK_VERSION is a FLOOR, not an equality target. An engine that
# reports the pinned release or anything newer is accepted; older is refused.
#
# It cannot be an equality target, because the same constant is ALSO the exact
# release tag CI downloads (.github/workflows/ci.yml, scripts/devbox/
# fetch_flapjack_release.sh). flapjack `main` bumps its version the moment work
# lands and the matching release is cut later, so between those two moments no
# value of the pin satisfies both consumers: pointing it at the unpublished
# version 404s CI's download (which gates both deploy jobs), and leaving it
# behind rejects every locally source-built engine. Equality was measured
# rejecting correct checkouts and provoking lanes to repoint FLAPJACK_DEV_DIR at
# a stale checkout instead — a false green. A floor closes that window while
# still refusing genuinely too-old engines.
#
# The shared spec for this rule, read by this suite AND by the Rust
# implementation in infra/api/src/services/flapjack_proxy/mod.rs, lives at
# scripts/tests/fixtures/flapjack_version_floor_cases.json.
if required_version:
    observed_version = parse_version(version)
    floor_version = parse_version(required_version)
    if observed_version is None or floor_version is None:
        fail("version_unparseable")
    if observed_version < floor_version:
        fail("version_mismatch")
if dirty is True:
    fail("dirty_local_build")
if exact_identity_required and not isinstance(dirty, bool):
    fail("legacy_malformed_health")

if required_revision and not revision:
    fail("legacy_malformed_health")
if required_build_id and not build_id:
    fail("legacy_malformed_health")

if required_revision and revision != required_revision:
    fail("revision_mismatch")
if required_build_id and build_id != required_build_id:
    fail("build_id_mismatch")

if required_capability:
    capability_present = False
    if isinstance(capabilities, list):
        capability_present = required_capability in capabilities
    elif isinstance(capabilities, dict):
        capability_present = capabilities.get(required_capability) is True
    if not capability_present:
        fail("missing_capability")

if exact_identity_required and not (revision and build_id):
    fail("legacy_malformed_health")
print("match")
PY
}

# Fetch runtime `/health` and classify it. A runtime started and owned by the
# current wrapper has already had its exact source receipt and executable bytes
# validated before launch, so its public health response only needs to prove the
# version/capability contract. Pre-existing and remote runtimes must continue to
# carry exact identity in health because this process does not own their launch.
flapjack_runtime_identity_reason() {
    local flapjack_base_url="$1" locally_owned="${2:-0}" body
    body="$(curl -fsS -m 10 "${flapjack_base_url%/}/health" 2>/dev/null)" || {
        printf 'runtime_unreachable\n'
        return 0
    }
    if [ "$locally_owned" = "1" ]; then
        FJCLOUD_FLAPJACK_REQUIRED_REVISION="" \
            FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="" \
            flapjack_classify_health_json "$body"
        return
    fi
    flapjack_classify_health_json "$body"
}

# Build the operator-facing text for a rejected Flapjack runtime identity.
#
# ONE owner, because the two launchers used to print two different messages and
# both were wrong the same way: they told the reader to "rebuild the checkout",
# which cannot change a version, and neither named the version actually
# observed. The measured consequence of an unactionable rejection was a lane
# repointing FLAPJACK_DEV_DIR at an older checkout and reporting a green whose
# engine nobody can reproduce — so the remedy text is part of the contract here,
# not decoration.
#
# Args: <reason> <base_url> [binary_path]
flapjack_identity_rejection_message() {
    local reason="$1" base_url="$2" binary_path="${3:-}"
    local observed provenance
    # The engine answered health a moment ago (that is how we got a reason), so
    # a failure here means it just went away; say so rather than printing blank.
    observed="$(flapjack_runtime_version "$base_url" 2>/dev/null || printf 'unreported')"
    # Provenance lives in scripts/lib/flapjack_binary.sh, which every real caller
    # sources; guard so this file stays usable on its own.
    if command -v flapjack_source_provenance_summary >/dev/null 2>&1; then
        provenance="$(flapjack_source_provenance_summary 2>/dev/null || printf 'unknown')"
    else
        provenance="unknown"
    fi

    printf 'Flapjack engine at %s rejected: %s\n' "$base_url" "$reason"
    printf '  engine reports version : %s\n' "$observed"
    printf '  fjcloud minimum (floor): %s  (owner: scripts/lib/flapjack_binary.sh)\n' \
        "${FJCLOUD_FLAPJACK_VERSION:-<unset>}"
    printf '  selected binary        : %s\n' "${binary_path:-<not recorded>}"
    printf '  binary provenance      : %s\n' "$provenance"
    printf '  The pin is a MINIMUM. An engine NEWER than it is accepted.\n'
    case "$reason" in
        version_mismatch)
            printf '  Remedy: update the FLAPJACK_DEV_DIR checkout to a release at or above the\n'
            printf '          floor, or lower the floor - but only to a version that already has a\n'
            printf '          published flapjack release, because CI downloads that exact tag.\n'
            ;;
        version_unparseable)
            printf '  Remedy: this engine reports a version fjcloud cannot order against the floor\n'
            printf '          (a prerelease, or not MAJOR.MINOR.PATCH). Run a published release\n'
            printf '          build, or correct the pin.\n'
            ;;
        *)
            printf '  Remedy: rebuild or reselect the checkout so its runtime identity matches the\n'
            printf '          receipt fjcloud recorded when it selected that binary.\n'
            ;;
    esac
    printf '  NOT a remedy: repointing FLAPJACK_DEV_DIR at an OLDER checkout. That changes\n'
    printf '          what is under test and yields evidence for an engine nobody can\n'
    printf '          reproduce. It has happened before; do not do it.\n'
}

flapjack_required_runtime_identity_evidence_available() {
    [ -n "${FJCLOUD_FLAPJACK_REQUIRED_REVISION:-}" ] && \
        [ -n "${FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID:-}" ] && \
        [ -n "${FJCLOUD_FLAPJACK_REQUIRED_SHA256:-}" ]
}

flapjack_fleet_identity_reason() {
    local base_url reason
    for base_url in "$@"; do
        reason="$(flapjack_runtime_identity_reason "$base_url")"
        [ "$reason" = "match" ] || {
            printf 'mixed_fleet\n'
            return 0
        }
    done
    printf 'match\n'
}

flapjack_runtime_matches_required_version() {
    [ "$(flapjack_runtime_identity_reason "$1")" = "match" ]
}
