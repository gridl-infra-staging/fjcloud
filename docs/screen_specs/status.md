# Status Screen Spec

## Scope

- Primary route: `/status`
- Related routes: `/`, `/beta`, `/signup`
- Audience: unauthenticated prospects and authenticated customers checking platform health
- Priority: P0

## User Goal

Understand current Flapjack Cloud service health and where to find beta support expectations.

## Target Behavior

The status page renders the Flapjack Cloud brand, public auth links, the `Service Status` heading, the current status label, a last-updated timestamp, incident-communications ownership copy, and links to beta scope and email support.

## Required States

- Loading: server-rendered page should display a complete status card after the load function resolves; no client-only spinner is required.
- Empty: missing environment status falls back to `All Systems Operational` with a generated timestamp.
- Error: unknown status values fall back to operational styling instead of exposing infrastructure details.
- Success: `operational`, `degraded`, and `outage` values render distinct labels and warning colors.

## Controls And Navigation

- Header brand link navigates to `/`.
- Header `Log In` link navigates to `/login`.
- Header `Sign Up` link navigates to `/signup`.
- `View beta scope` navigates to `/beta`.
- `Email support` uses the shared support mailbox.

## Acceptance Criteria

- [ ] The page body renders `Service Status` and the current status label.
- [ ] Missing `SERVICE_STATUS` returns `All Systems Operational`.
- [ ] `SERVICE_STATUS=degraded` returns `Degraded Performance`.
- [ ] The page names Flapjack Cloud operations as incident-communications owner.
- [ ] The support link uses the shared support mailbox.
- [ ] The page does not expose raw infrastructure names or link to an unimplemented incident-history route.

## Edge Cases

- If `SERVICE_STATUS_UPDATED` is absent, the server generates a timestamp for `Last updated`.
- If incidents occur before a dedicated history page exists, users are sent to `/beta` for support expectations rather than to API documentation.

## Current Implementation Gaps

None known for the mapped launch-critical behavior.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/public-pages.spec.ts`
- Component tests: `web/src/routes/status/status.test.ts`
- Server/contract tests: `web/src/routes/status/status.test.ts`
