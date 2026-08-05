#!/usr/bin/env bash
# Workspace-derived port oracles shared by the shell test suites.
#
# Two runtimes derive the same workspace ports: web/playwright.config.contract.ts
# (canonical) and its single Bash mirror scripts/lib/playwright_port_plan.sh. Any
# test that asserts a derived port must compare against one of these owners
# instead of re-deriving the arithmetic in the test file, so a changed derivation
# fails the suite rather than silently agreeing with a stale copy.
#
# Callers define REPO_ROOT before sourcing this file.

# Bash-mirror plan for a workspace path, as `<NAME>=<port>` lines.
manual_port_plan_for_workspace() {
    local workspace_path="$1"
    local port_plan_helper="$REPO_ROOT/scripts/lib/playwright_port_plan.sh"

    [ -f "$port_plan_helper" ] || return 1
    (
        # shellcheck disable=SC1090
        source "$port_plan_helper"
        playwright_derive_manual_stack_port_defaults "$REPO_ROOT" "$workspace_path"
    )
}

manual_port_plan_value() {
    local plan="$1" variable_name="$2"
    printf '%s\n' "$plan" | sed -n "s/^${variable_name}=//p"
}

# TypeScript-owner plan for a workspace path, as `WEB_PORT=`/`API_PORT=`/
# `FLAPJACK_PORT=` lines read straight from the contract's exported resolvers.
typescript_port_plan_for_workspace() {
    local workspace_path="$1" tmp_dir="$2"
    local contract_path="$REPO_ROOT/web/playwright.config.contract.ts"
    local runner_path="$tmp_dir/playwright_port_oracle.ts"

    if [ -x "$REPO_ROOT/web/node_modules/.bin/vite-node" ]; then
        printf '%s\n' \
            "import { pathToFileURL } from 'node:url';" \
            "const contract = await import(pathToFileURL(process.argv[2]).href);" \
            "console.log('WEB_PORT=' + contract.resolveDefaultPlaywrightWebPort(process.argv[3]));" \
            "console.log('API_PORT=' + contract.resolveDefaultPlaywrightApiPort(process.argv[3]));" \
            "console.log('FLAPJACK_PORT=' + contract.resolveDefaultPlaywrightFlapjackPort(process.argv[3]));" \
            > "$runner_path"
        "$REPO_ROOT/web/node_modules/.bin/vite-node" \
            "$runner_path" "$contract_path" "$workspace_path"
        return
    fi

    local contract_copy="$tmp_dir/playwright.config.contract.ts"
    local guard_url
    guard_url="$(node -e \
        'console.log(require("node:url").pathToFileURL(process.argv[1]).href)' \
        "$REPO_ROOT/web/tests/fixtures/contract-guards.ts")"
    sed "s|from './tests/fixtures/contract-guards'|from '${guard_url}'|" \
        "$contract_path" > "$contract_copy"
    node --experimental-strip-types --input-type=module \
        - "$contract_copy" "$workspace_path" <<'NODE'
import { pathToFileURL } from 'node:url';

const contract = await import(pathToFileURL(process.argv[2]).href);
console.log('WEB_PORT=' + contract.resolveDefaultPlaywrightWebPort(process.argv[3]));
console.log('API_PORT=' + contract.resolveDefaultPlaywrightApiPort(process.argv[3]));
console.log('FLAPJACK_PORT=' + contract.resolveDefaultPlaywrightFlapjackPort(process.argv[3]));
NODE
}
