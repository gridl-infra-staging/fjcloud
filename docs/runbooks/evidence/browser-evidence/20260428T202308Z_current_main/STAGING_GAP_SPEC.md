# Staging Gap Spec

## Local-only blocker
`web/playwright.config.contract.ts:320-326` enforces loopback-only URLs through `requireLoopbackHttpUrl()` for `BASE_URL` and `API_BASE_URL` inside `resolvePlaywrightRuntime()`. This prevents staging-host execution even when staging endpoints are otherwise reachable.

## Config owners for follow-up
- web/playwright.config.contract.ts
- web/playwright.config.ts

## Smallest staging-unblock seam
Introduce a narrowly-scoped runtime flag handled by the config owners that permits non-loopback `BASE_URL` and `API_BASE_URL` only for an explicit staging profile while preserving loopback enforcement as the default path.
