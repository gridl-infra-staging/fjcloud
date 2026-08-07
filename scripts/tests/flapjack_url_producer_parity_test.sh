#!/usr/bin/env bash
# Contract test for the shared-VM engine identity emitted by every shipped
# FLAPJACK_URL source producer. This reads source only; it does not execute the
# bootstrap or provisioning scripts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

SPECIMEN_NODE_ID="vm-shared-parity.example.test"
BOOTSTRAP_SOURCE="$REPO_ROOT/ops/user-data/bootstrap.sh"
SSM_ENV_SOURCE="$REPO_ROOT/ops/scripts/lib/generate_ssm_env.sh"
CLOUD_INIT_SOURCE="$REPO_ROOT/infra/api/src/provisioner/cloud_init.rs"

source_url_host() {
    local url="$1"
    python3 - "$url" <<'PY'
import sys
from urllib.parse import urlsplit

parsed = urlsplit(sys.argv[1])
if parsed.scheme not in {"http", "https"} or parsed.hostname is None:
    raise SystemExit(1)
print(parsed.hostname)
PY
}

substitute_node_id() {
    local template="$1"
    template="${template//\$\{NODE_ID\}/$SPECIMEN_NODE_ID}"
    printf '%s\n' "${template//\$NODE_ID/$SPECIMEN_NODE_ID}"
}

assert_source_url_host() {
    local producer_name="$1" url_template="$2"
    local rendered_url host
    rendered_url="$(substitute_node_id "$url_template")"
    host="$(source_url_host "$rendered_url" 2>/dev/null)" || host=""

    assert_ne "$host" "" "$producer_name emits a parseable URL"
    assert_eq "$host" "$SPECIMEN_NODE_ID" \
        "$producer_name keeps FLAPJACK_URL host equal to NODE_ID"
}

test_source_producer_identity_parity() {
    local -a producer_names=(
        "ops/user-data/bootstrap.sh"
        "ops/scripts/lib/generate_ssm_env.sh"
        "infra/api/src/provisioner/cloud_init.rs"
    )
    assert_eq "${#producer_names[@]}" "3" \
        "source producer denominator is exactly three"
    echo "SOURCE PRODUCERS (3): ${producer_names[*]}"

    local bootstrap_hit ssm_env_hit cloud_init_hit
    bootstrap_hit="$(grep -n '^FLAPJACK_URL=' "$BOOTSTRAP_SOURCE" || true)"
    ssm_env_hit="$(grep -n 'append_envfile_line .*"FLAPJACK_URL"' "$SSM_ENV_SOURCE" || true)"
    cloud_init_hit="$(grep -n '^FLAPJACK_URL=' "$CLOUD_INIT_SOURCE" || true)"

    echo "PRODUCER HIT: ops/user-data/bootstrap.sh:$bootstrap_hit"
    echo "PRODUCER HIT: ops/scripts/lib/generate_ssm_env.sh:$ssm_env_hit"
    echo "PRODUCER HIT: infra/api/src/provisioner/cloud_init.rs:$cloud_init_hit"

    assert_eq "$(grep -c '^FLAPJACK_URL=' "$BOOTSTRAP_SOURCE" || true)" "1" \
        "bootstrap extractor resolves exactly one assignment"
    assert_eq "$(grep -c 'append_envfile_line .*"FLAPJACK_URL"' "$SSM_ENV_SOURCE" || true)" "1" \
        "SSM env extractor resolves exactly one append call"
    assert_eq "$(grep -c '^FLAPJACK_URL=' "$CLOUD_INIT_SOURCE" || true)" "1" \
        "cloud-init extractor resolves exactly one assignment"

    local bootstrap_line="${bootstrap_hit#*:}"
    local ssm_env_line="${ssm_env_hit#*:}"
    local cloud_init_line="${cloud_init_hit#*:}"
    local ssm_env_template=""

    assert_eq "$bootstrap_line" 'FLAPJACK_URL=http://$NODE_ID:7700' \
        "bootstrap extractor selects the assignment rather than comment prose"
    assert_eq "$cloud_init_line" 'FLAPJACK_URL=http://$NODE_ID:7700' \
        "cloud-init extractor selects the assignment rather than comment prose"

    if [[ "$ssm_env_line" =~ ^[[:space:]]*append_envfile_line[[:space:]]+\"\$METERING_TMPFILE\"[[:space:]]+\"FLAPJACK_URL\"[[:space:]]+\"([^\"]+)\"[[:space:]]*$ ]]; then
        ssm_env_template="${BASH_REMATCH[1]}"
        pass "SSM env extractor selects the FLAPJACK_URL append call rather than comment prose"
    else
        fail "SSM env extractor did not resolve the expected assignment call: $ssm_env_line"
    fi

    assert_source_url_host "ops/user-data/bootstrap.sh" "${bootstrap_line#FLAPJACK_URL=}"
    assert_source_url_host "ops/scripts/lib/generate_ssm_env.sh" "$ssm_env_template"
    assert_source_url_host "infra/api/src/provisioner/cloud_init.rs" "${cloud_init_line#FLAPJACK_URL=}"
}

test_source_producer_identity_parity
run_test_summary
