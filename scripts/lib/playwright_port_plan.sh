#!/usr/bin/env bash
# Workspace-derived manual-stack port planning.
#
# web/playwright.config.contract.ts remains canonical for the hash constants,
# bands, and blocked web ports. This is the only Bash mirror of that arithmetic;
# it reads the TypeScript owner on every call so the two runtimes cannot silently
# acquire independent constants.

playwright_derive_manual_stack_port_defaults() {
    local contract_root="$1" workspace_path="$2" variable_prefix="${3:-}"

    python3 - "$contract_root" "$workspace_path" "$variable_prefix" <<'PY'
import re
import sys
from pathlib import Path

contract_root = Path(sys.argv[1])
workspace_path = sys.argv[2].strip()
variable_prefix = sys.argv[3]
contract_path = contract_root / "web/playwright.config.contract.ts"
source = contract_path.read_text(encoding="utf-8")

def const_int(name):
    match = re.search(rf"const {name} = (0x[0-9A-Fa-f_]+|[0-9_]+);", source)
    if not match:
        raise SystemExit(f"missing {name} in {contract_path}")
    raw = match.group(1).replace("_", "")
    return int(raw, 16 if raw.startswith("0x") else 10)

def const_int_set(name):
    match = re.search(rf"const {name} = new Set\(\[(.*?)\]\);", source, re.DOTALL)
    if not match:
        raise SystemExit(f"missing {name} in {contract_path}")
    return {int(value.replace("_", "")) for value in re.findall(r"[0-9_]+", match.group(1))}

def resolver_empty_path_fallback(name):
    pattern = (
        rf"export function {name}\(.*?\): number \{{"
        r".*?normalizedWorkspacePath\.length === 0\) \{"
        r".*?return ([0-9_]+);"
    )
    match = re.search(pattern, source, re.DOTALL)
    if not match:
        raise SystemExit(f"missing empty-path fallback for {name} in {contract_path}")
    return int(match.group(1).replace("_", ""))

def fnv1a_utf16(value):
    result = const_int("FNV1A_32_OFFSET_BASIS")
    prime = const_int("FNV1A_32_PRIME")
    encoded = value.encode("utf-16-le", "surrogatepass")
    for index in range(0, len(encoded), 2):
        result ^= int.from_bytes(encoded[index:index + 2], "little")
        result = (result * prime) & 0xFFFFFFFF
    return result

span = const_int("PLAYWRIGHT_DEFAULT_PORT_HASH_SPAN")
if workspace_path:
    offset = fnv1a_utf16(workspace_path) % span
    meilisearch = const_int("PLAYWRIGHT_DEFAULT_PORT_HASH_MIN") + offset
    blocked_web_ports = const_int_set("CHROMIUM_BLOCKED_PLAYWRIGHT_WEB_PORTS")
    while meilisearch in blocked_web_ports:
        meilisearch += 1
    api = const_int("PLAYWRIGHT_DEFAULT_API_PORT_HASH_MIN") + offset
    flapjack = const_int("PLAYWRIGHT_DEFAULT_FLAPJACK_PORT_HASH_MIN") + offset
else:
    meilisearch = resolver_empty_path_fallback("resolveDefaultPlaywrightWebPort")
    api = resolver_empty_path_fallback("resolveDefaultPlaywrightApiPort")
    flapjack = resolver_empty_path_fallback("resolveDefaultPlaywrightFlapjackPort")
ports = {
    "FLAPJACK_PORT": flapjack,
    "LOCAL_MEILISEARCH_PORT": meilisearch,
    "LOCAL_TYPESENSE_PORT": api,
    "LOCAL_MAILPIT_UI_PORT": flapjack + (2 * span),
    "LOCAL_SMTP_PORT": flapjack + span,
    "LOCAL_S3_PORT": flapjack + (3 * span),
    "LOCAL_DB_PORT": flapjack + (4 * span),
}
if any(port < 1024 or port > 65535 for port in ports.values()):
    raise SystemExit("manual-stack port plan contains an out-of-range TCP port")
if len(set(ports.values())) != len(ports):
    raise SystemExit("manual-stack port plan contains duplicate TCP ports")
for name, port in ports.items():
    print(f"{variable_prefix}{name}={port}")
PY
}

# The Playwright web port for a workspace, resolved through the same owner as
# the rest of the plan.
#
# The plan publishes this arithmetic under LOCAL_MEILISEARCH_PORT, but the two
# are not the same fact and callers must not reach for the service-named value:
# web/playwright.config.ts derives the web port from its own working directory
# (<repo>/web), while local-dev-up.sh binds the Meilisearch container from the
# repo-root hash (docker-compose.yml). Pass the path the config hashes.
playwright_derive_web_port() {
    local contract_root="$1" web_workspace_path="$2" derived_plan

    derived_plan="$(playwright_derive_manual_stack_port_defaults \
        "$contract_root" "$web_workspace_path")" || return $?
    printf '%s\n' "$derived_plan" | sed -n 's/^LOCAL_MEILISEARCH_PORT=//p'
}

playwright_apply_manual_stack_port_defaults() {
    local contract_root="$1" workspace_path="$2" derived_plan
    local configured_local_db_port="${LOCAL_DB_PORT:-}" database_url_port=""

    derived_plan="$(playwright_derive_manual_stack_port_defaults \
        "$contract_root" "$workspace_path" PLAYWRIGHT_DERIVED_)" || return $?
    eval "$derived_plan"

    FLAPJACK_PORT="${FLAPJACK_PORT:-$PLAYWRIGHT_DERIVED_FLAPJACK_PORT}"
    LOCAL_MEILISEARCH_PORT="${LOCAL_MEILISEARCH_PORT:-$PLAYWRIGHT_DERIVED_LOCAL_MEILISEARCH_PORT}"
    LOCAL_TYPESENSE_PORT="${LOCAL_TYPESENSE_PORT:-$PLAYWRIGHT_DERIVED_LOCAL_TYPESENSE_PORT}"
    LOCAL_MAILPIT_UI_PORT="${LOCAL_MAILPIT_UI_PORT:-$PLAYWRIGHT_DERIVED_LOCAL_MAILPIT_UI_PORT}"
    LOCAL_SMTP_PORT="${LOCAL_SMTP_PORT:-$PLAYWRIGHT_DERIVED_LOCAL_SMTP_PORT}"
    LOCAL_S3_PORT="${LOCAL_S3_PORT:-$PLAYWRIGHT_DERIVED_LOCAL_S3_PORT}"
    LOCAL_DB_PORT="${LOCAL_DB_PORT:-$PLAYWRIGHT_DERIVED_LOCAL_DB_PORT}"
    export FLAPJACK_PORT LOCAL_MEILISEARCH_PORT LOCAL_TYPESENSE_PORT
    export LOCAL_MAILPIT_UI_PORT LOCAL_SMTP_PORT LOCAL_S3_PORT LOCAL_DB_PORT

    [ -n "${DATABASE_URL:-}" ] || return 0
    database_url_port="$(db_url_port "$DATABASE_URL")" || return 1
    if [ -n "$configured_local_db_port" ]; then
        DATABASE_URL="$(db_url_with_port "$DATABASE_URL" "$configured_local_db_port")" || return 1
    elif [ "$database_url_port" != "5432" ]; then
        LOCAL_DB_PORT="$database_url_port"
    else
        DATABASE_URL="$(db_url_with_port "$DATABASE_URL" "$LOCAL_DB_PORT")" || return 1
    fi
    export DATABASE_URL LOCAL_DB_PORT
}
