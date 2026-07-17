#!/usr/bin/env bash
# Compatibility checks for independently running local stack services.

FJCLOUD_API_PREVIEW_EVENTS_CAPABILITY="preview_events_v1"
FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY="${FJCLOUD_FLAPJACK_REQUIRED_CAPABILITY:-vectorSearchLocal}"

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
binary_sha = first_string(build, "binary_sha256", "sha256")
dirty = build.get("dirty")
capabilities = build.get("capabilities", health.get("capabilities"))

required_version, required_revision, required_build_id, required_sha, required_capability = sys.argv[2:7]
exact_identity_required = bool(required_revision or required_build_id or required_sha)
if not version:
    fail("legacy_malformed_health")
if required_version and version != required_version:
    fail("version_mismatch")
if dirty is True:
    fail("dirty_local_build")
if exact_identity_required and not isinstance(dirty, bool):
    fail("legacy_malformed_health")

if required_revision and not revision:
    fail("legacy_malformed_health")
if required_build_id and not build_id:
    fail("legacy_malformed_health")
if required_sha and not binary_sha:
    fail("legacy_malformed_health")

if required_revision and revision != required_revision:
    fail("revision_mismatch")
if required_build_id and build_id != required_build_id:
    fail("build_id_mismatch")
if required_sha and binary_sha != required_sha:
    fail("checksum_mismatch")

if required_capability:
    capability_present = False
    if isinstance(capabilities, list):
        capability_present = required_capability in capabilities
    elif isinstance(capabilities, dict):
        capability_present = capabilities.get(required_capability) is True
    if not capability_present:
        fail("missing_capability")

if exact_identity_required and not (revision and build_id and binary_sha):
    fail("legacy_malformed_health")
print("match")
PY
}

# Fetch runtime `/health` and classify it. Thin URL wrapper over the shared
# flapjack_classify_health_json comparison.
flapjack_runtime_identity_reason() {
    local flapjack_base_url="$1" body
    body="$(curl -fsS -m 10 "${flapjack_base_url%/}/health" 2>/dev/null)" || {
        printf 'runtime_unreachable\n'
        return 0
    }
    flapjack_classify_health_json "$body"
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
