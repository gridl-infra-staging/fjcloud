#!/usr/bin/env bash
# Regression test: Stage 5 lockout proof artifacts must be sanitized and helper-seam compliant.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EVID_DIR="$REPO_ROOT/docs/runbooks/evidence/may16_wave_deploy_verify/20260518T231734Z/stage5_auth_lockout_proof"
RUN2_SCRIPT="$EVID_DIR/stage5_probe_capture_only.sh"

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

test_run2_probe_uses_mandated_helper_seams() {
    local script_content

    script_content="$(cat "$RUN2_SCRIPT")"

    assert_contains "$script_content" "source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)" \
        "run2 probe should hydrate env via source <(hydrate_seeder_env_from_ssm.sh staging)"
    assert_contains "$script_content" "source scripts/lib/http_json.sh" \
        "run2 probe should source scripts/lib/http_json.sh"
    assert_contains "$script_content" "source scripts/lib/staging_db.sh" \
        "run2 probe should source scripts/lib/staging_db.sh"
    assert_contains "$script_content" "api_json_call" \
        "run2 probe should route requests through scripts/lib/http_json.sh helpers"
    assert_contains "$script_content" 'tenant_call "$method" "$path" "$CANARY_TOKEN"' \
        "run2 probe cleanup should reuse account delete seam"
    assert_contains "$script_content" 'admin_call "$method" "$path"' \
        "run2 probe cleanup should reuse admin cleanup seam"

    assert_not_contains "$script_content" "hydrate_out=" \
        "run2 probe should not bypass hydrator via temp export file"
    assert_not_contains "$script_content" 'curl -sS -X DELETE "${API_URL}/admin/tenants/' \
        "run2 probe should not call admin cleanup via raw curl"
}

test_evidence_json_is_redacted() {
    if python3 - "$EVID_DIR" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
violations = []
for path in sorted(root.glob("*.json")):
    text = path.read_text(encoding="utf-8")
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        violations.append(f"{path.name}:invalid_json")
        continue

    def walk(node, breadcrumbs):
        if isinstance(node, dict):
            for key, value in node.items():
                walk(value, breadcrumbs + [str(key)])
        elif isinstance(node, list):
            for idx, value in enumerate(node):
                walk(value, breadcrumbs + [str(idx)])
        else:
            key = breadcrumbs[-1].lower() if breadcrumbs else ""
            breadcrumb_path = ".".join(breadcrumbs)
            if key == "password" and isinstance(node, str) and node != "[REDACTED]":
                violations.append(f"{path.name}:{breadcrumb_path}")
            if key == "token" and isinstance(node, str) and node != "[REDACTED]":
                violations.append(f"{path.name}:{breadcrumb_path}")
            if isinstance(node, str) and re.match(r"^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$", node):
                violations.append(f"{path.name}:{breadcrumb_path}")

    walk(payload, [])

if violations:
    print("\n".join(violations))
    raise SystemExit(1)
PY
    then
        pass "Stage 5 JSON evidence is redacted (no plaintext password/token/JWT values)"
    else
        fail "Stage 5 JSON evidence must redact plaintext password/token/JWT values"
    fi
}

main() {
    echo "=== stage5_auth_lockout_proof_hygiene_test.sh ==="
    echo ""

    test_run2_probe_uses_mandated_helper_seams
    test_evidence_json_is_redacted

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
