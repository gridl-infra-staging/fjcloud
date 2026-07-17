# Status Screen Spec

## Scope

- Primary route: `/status`
- Related routes: `/`, `/beta`
- Audience: unauthenticated prospects and authenticated customers checking platform health
- Priority: P0

## User Goal

Understand current Flapjack Cloud service health and where to find beta support expectations.

## Target Behavior

The status page renders the Flapjack Cloud brand, a public login link, the `Service Status` heading, the current status label, a conditional last-updated timestamp, an optional public incident message (when `SERVICE_STATUS_MESSAGE` is set), incident-communications ownership copy, and links to beta scope and email support. The page does not render a signup discovery link per `decisions/2026-05-23_beta_signup_gate.md`, while direct `/signup` remains reachable. It is server-rendered by `web/src/routes/status/+page.server.ts` using the `StatusRouteData` shape from `web/src/routes/status/status_contract.ts`. Configured `operational`, `degraded`, and `outage` values retain their existing labels; missing or unrecognized `SERVICE_STATUS` renders the fourth state `unknown` with the label `Status Unavailable` and does not imply a verified outage or healthy service. `Last updated` renders only when `SERVICE_STATUS_UPDATED` is present.

## Required States

- Loading: server-rendered page should display a complete status card after the load function resolves; no client-only spinner is required.
- Empty: missing `SERVICE_STATUS` renders `Status Unavailable` with state `unknown`. Missing `SERVICE_STATUS_UPDATED` omits the `Last updated` line. Missing or empty `SERVICE_STATUS_MESSAGE` omits the message from the page.
- Error: unknown status values render `Status Unavailable` with state `unknown` instead of exposing infrastructure details or implying operational health.
- Success: `operational`, `degraded`, and `outage` values render distinct labels and warning colors. When `SERVICE_STATUS_UPDATED` is present, the page renders `Last updated` with that value. When `SERVICE_STATUS_MESSAGE` is set, the message is included in the `StatusRouteData.message` field and rendered on the page.

## Controls And Navigation

- Header brand link navigates to `/`.
- Header `Log In` link navigates to `/login`.
- Header signup discovery link is absent.
- `View beta scope` navigates to `/beta`.
- `Email support` uses the shared support mailbox.

## Acceptance Criteria

- [ ] The page body renders `Service Status` and the current status label.
- [ ] Missing `SERVICE_STATUS` returns `Status Unavailable`.
- [ ] Invalid `SERVICE_STATUS` returns `Status Unavailable`.
- [ ] `SERVICE_STATUS=degraded` returns `Degraded Performance`.
- [ ] Missing `SERVICE_STATUS_UPDATED` omits the `Last updated` line.
- [ ] When `SERVICE_STATUS_MESSAGE` is set, the message appears on the page.
- [ ] When `SERVICE_STATUS_MESSAGE` is unset or empty, no message section appears.
- [ ] The page names Flapjack Cloud operations as incident-communications owner.
- [ ] The support link uses the shared support mailbox.
- [ ] The page does not expose raw infrastructure names or link to an unimplemented incident-history route.

## Edge Cases

- If `SERVICE_STATUS_UPDATED` is absent, the `Last updated` line is absent and no request-time timestamp is generated.
- If `SERVICE_STATUS_MESSAGE` is unset or empty, the `message` field is omitted from `StatusRouteData` and no message renders on the page.
- If incidents occur before a dedicated history page exists, users are sent to `/beta` for support expectations rather than to API documentation.

## Current Implementation Gaps

- None known for fail-closed status rendering.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/public-pages.spec.ts`
- Component tests: `web/src/routes/status/status.test.ts`
- Server/contract tests: `web/src/routes/status/status.test.ts`
