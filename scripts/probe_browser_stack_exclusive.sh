#!/usr/bin/env bash
# Report whether the browser / local-dev-stack exclusive resource is held.
#
# WHY THIS EXISTS. Several orchestrations declare the browser and the local dev
# stack a single host-wide exclusive resource — at most one browser lane may run
# at a time across every batch and both repos — and gated dispatch on this
# inline probe:
#
#     ps -axo args= | grep -cE 'local-dev-up|playwright'   # must return 0
#
# That probe cannot return 0 on this host and therefore blocks every browser
# lane forever. `ps -axo args=` prints full command lines, and a matt/batman
# worker's command line embeds its entire stage prompt. Any lane whose prompt
# mentions Playwright — which is most browser lanes, plus the orchestration
# prompts that describe this very rule — matches. The probing shell's own
# `grep -cE 'local-dev-up|playwright'` argv matches too. Measured 2026-07-31:
# the inline form returned 4 while zero browsers and zero dev stacks were
# running (no LISTEN on the stack ports, no Chromium process).
#
# A dispatch gate that is permanently red is not a gate — lanes either stall
# behind it or learn to ignore it. This script is the single canonical owner of
# the question so the fix lands in one place rather than in nine copied
# one-liners.
#
# WHAT COUNTS AS A HOLDER. Three independent signals, anchored so prompt text
# cannot register:
#   1. A shell whose *first argument* is a `scripts/local-dev-up.sh` path. Prompt
#      text mentioning the script never appears in argv[1] position.
#   2. A node process executing Playwright's CLI entry point, matched on the
#      module path rather than the bare word.
#   3. Anything LISTENing on the engine port the stack binds — a resource check
#      that catches a stack started by a path this script does not model.
#
# Signal 3 makes the probe fail closed against an unmodelled starter: a stack is
# detected by the port it holds even when nothing matches (1) or (2).
#
# Exit codes:
#   0 — resource free, a browser lane may be dispatched
#   1 — resource held; stdout names each holder
#
# Env vars:
#   FJCLOUD_ENGINE_PORT  engine port to check for LISTEN (default 7700)

set -euo pipefail

ENGINE_PORT="${FJCLOUD_ENGINE_PORT:-7700}"

# argv[1]-anchored: `bash /any/path/scripts/local-dev-up.sh [args]`. The leading
# `^` plus the interpreter token is what keeps stage-prompt text out.
#
# All four starters named by CLAUDE.md "Local Stack Ownership" are modelled, not
# just local-dev-up.sh. Orchestration stage-close checks ask for "0 owned stack
# processes" across local-dev-up|web-dev|api-dev; a probe covering only the
# first would report free while a lane's web or api server was still up, which
# is the same under-reporting failure in a smaller costume.
DEV_STACK_PATTERN='^([^ ]*/)?(ba|z)?sh [^ ]*scripts/(local-dev-up|web-dev|api-dev|local_demo)\.sh( |$)'
# Playwright's real entry points, not the word. Covers `playwright/cli.js`,
# `playwright-core/lib/cli/...` and the `@playwright/test` runner.
PLAYWRIGHT_PATTERN='^([^ ]*/)?node .*(playwright(-core)?/(cli|lib/cli)|@playwright/test)'

holders=0

dev_stack_hits="$(ps -axo args= | grep -E "$DEV_STACK_PATTERN" || true)"
if [ -n "$dev_stack_hits" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "HOLDER local-stack: $line"
        holders=$((holders + 1))
    done <<< "$dev_stack_hits"
fi

playwright_hits="$(ps -axo args= | grep -E "$PLAYWRIGHT_PATTERN" || true)"
if [ -n "$playwright_hits" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "HOLDER playwright: $line"
        holders=$((holders + 1))
    done <<< "$playwright_hits"
fi

# `lsof` is absent or permission-limited on some hosts. Treat an lsof failure as
# "no port evidence" rather than as "free": signals 1 and 2 still apply, and a
# hard failure here would make the probe unusable rather than conservative.
port_hits="$(lsof -nP -iTCP:"$ENGINE_PORT" -sTCP:LISTEN 2>/dev/null | grep LISTEN || true)"
if [ -n "$port_hits" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        echo "HOLDER engine-port-$ENGINE_PORT: $line"
        holders=$((holders + 1))
    done <<< "$port_hits"
fi

echo "holders=$holders"

if [ "$holders" -eq 0 ]; then
    echo "PASS: browser/local-stack exclusive resource is free"
    exit 0
fi

echo "FAIL: browser/local-stack exclusive resource is held; do not dispatch a browser lane" >&2
exit 1
