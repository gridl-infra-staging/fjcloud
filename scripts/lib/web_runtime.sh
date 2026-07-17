#!/usr/bin/env bash
# Shared local web runtime prerequisite checks.

WEB_VITE_RUNTIME_RELATIVE_PATH="web/node_modules/.bin/vite"
WEB_VITE_RUNTIME_INSTALL_HINT="cd web && npm ci"
WEB_PLAYWRIGHT_TEST_RUNTIME_RELATIVE_PATH="web/node_modules/@playwright/test/package.json"

web_vite_runtime_missing_message() {
    printf '%s is missing or not executable; install web dependencies first with: %s' \
        "$WEB_VITE_RUNTIME_RELATIVE_PATH" \
        "$WEB_VITE_RUNTIME_INSTALL_HINT"
}

has_web_vite_runtime() {
    local repo_root="$1"
    [ -x "$repo_root/$WEB_VITE_RUNTIME_RELATIVE_PATH" ]
}

web_runtime_service_is_ready() {
    local url="$1"
    curl -sf "$url" > /dev/null 2>&1
}

web_playwright_test_runtime_missing_message() {
    printf '%s is missing; install web dependencies first with: %s' \
        "$WEB_PLAYWRIGHT_TEST_RUNTIME_RELATIVE_PATH" \
        "$WEB_VITE_RUNTIME_INSTALL_HINT"
}

has_web_playwright_test_runtime() {
    local repo_root="$1"
    [ -f "$repo_root/$WEB_PLAYWRIGHT_TEST_RUNTIME_RELATIVE_PATH" ]
}
